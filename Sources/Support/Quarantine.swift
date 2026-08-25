// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// com.apple.quarantine: macOS's Mark-of-the-Web. docs/SECURITY.md 6, DIVERGENCES D-08.
//
// A file downloaded by a browser carries this extended attribute. Gatekeeper reads it,
// LaunchServices shows the "downloaded from the internet, are you sure" sheet from it, and
// the notarisation check that keeps unsigned malware from launching is driven by it. The
// attribute lives on the *archive*; the files inside it are just bytes until an archiver
// writes them out, at which point the archiver decides whether the payload of an untrusted
// download stays untrusted.
//
// So an extractor is a Gatekeeper bypass unless it propagates. This is not hypothetical -
// it is the mechanism behind a long line of real macOS malware deliveries, and it is why
// the archive utilities that got it wrong shipped CVEs for it. NanaZip's Windows analogue
// is Mark-of-the-Web propagation; this is the same idea on the same threat.
//
// There is deliberately no function here that removes the attribute, and there must never
// be one. "Remove quarantine" is a one-line convenience that silently disables Gatekeeper
// for everything inside an archive, it is the single most-copied bad instruction in Mac
// software distribution (`xattr -dr com.apple.quarantine`), and a checkbox for it would be
// this application's largest security regression. The user who genuinely needs it has the
// command line and the Finder's own "Open anyway", both of which put the decision in front
// of them per item.

import Foundation

/// Why a quarantine read or write failed.
public enum QuarantineError: Error, LocalizedError, Hashable, Sendable {
    case readFailed(path: String, code: Int32, reason: String)
    case writeFailed(path: String, code: Int32, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .readFailed(path, _, reason):
            "Could not read the quarantine attribute of '\(path)': \(reason)"
        case let .writeFailed(path, _, reason):
            "Could not set the quarantine attribute of '\(path)': \(reason)"
        }
    }
}

/// A parsed `com.apple.quarantine` value.
///
/// The on-disk value is four semicolon-separated fields - flags, timestamp, the name of
/// the application that downloaded the file, and an event UUID that ties the file back to
/// a row in the LaunchServices quarantine database. That layout is observed behaviour and
/// not public API: the fields have been stable for many macOS releases, but nothing
/// obliges them to stay that way.
///
/// Which is exactly why ``rawValue`` is kept, and why propagation copies the bytes rather
/// than re-serialising these fields. Parsing is for showing the user where a file came
/// from; the security-relevant path never depends on it being right.
public struct QuarantineInfo: Hashable, Sendable {
    /// The value exactly as stored.
    public let rawValue: String

    /// Field 1, a hexadecimal bitfield. Not interpreted here: the individual bits are
    /// private to LaunchServices, they have changed meaning between releases, and nothing
    /// ArcSeven does needs to know which is set. It is surfaced so a diagnostic can print
    /// it, and propagated so the system keeps seeing what it wrote.
    public let flags: UInt32?

    /// Field 2, seconds since 1970 in hexadecimal: when the file was quarantined.
    public let timestamp: Date?

    /// Field 3: the application that brought the file onto the machine, e.g. `Safari`.
    public let agentName: String?

    /// Field 4: the LaunchServices quarantine event this file belongs to.
    public let eventIdentifier: UUID?

    public init(rawValue: String) {
        self.rawValue = rawValue

        let fields = rawValue.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        func field(_ index: Int) -> String? {
            guard fields.indices.contains(index), !fields[index].isEmpty else { return nil }
            return fields[index]
        }

        flags = field(0).flatMap { UInt32($0, radix: 16) }
        timestamp = field(1)
            .flatMap { UInt32($0, radix: 16) }
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        agentName = field(2)
        eventIdentifier = field(3).flatMap { UUID(uuidString: $0) }
    }
}

/// Reads and propagates `com.apple.quarantine`. Never removes it.
public enum Quarantine {
    /// The attribute name. Spelled once.
    public static let attributeName = "com.apple.quarantine"

    // MARK: - Reading

    /// The raw attribute value, or `nil` when the item is not quarantined.
    ///
    /// Does not follow symbolic links: on an extraction tree the links are attacker-
    /// supplied, and a read that followed them would report the state of a file outside
    /// the destination.
    public static func rawValue(of url: URL) throws -> Data? {
        let path = url.path
        return try path.withCString { cPath -> Data? in
            try attributeName.withCString { cName -> Data? in
                let length = getxattr(cPath, cName, nil, 0, 0, XATTR_NOFOLLOW)
                if length < 0 {
                    // ENOATTR is "there is no such attribute", which is the common case
                    // for a file that was never downloaded, not an error.
                    if errno == ENOATTR || errno == ENOENT { return nil }
                    throw QuarantineError.readFailed(
                        path: path, code: errno, reason: String(cString: strerror(errno))
                    )
                }
                guard length > 0 else { return Data() }

                var buffer = [UInt8](repeating: 0, count: length)
                let read = getxattr(cPath, cName, &buffer, length, 0, XATTR_NOFOLLOW)
                if read < 0 {
                    if errno == ENOATTR { return nil }
                    throw QuarantineError.readFailed(
                        path: path, code: errno, reason: String(cString: strerror(errno))
                    )
                }
                // The attribute can shrink between the size query and the read.
                return Data(buffer.prefix(read))
            }
        }
    }

    /// The parsed attribute, or `nil` when the item is not quarantined.
    public static func info(of url: URL) throws -> QuarantineInfo? {
        guard let data = try rawValue(of: url), !data.isEmpty else { return nil }
        // The value is ASCII in practice; decoding leniently keeps a malformed value
        // readable rather than throwing on something we are only going to display.
        //
        // The failable String(bytes:encoding:) the rule asks for would turn a
        // non-UTF-8 attribute into `nil`, i.e. report a quarantined file as not
        // quarantined. Lossy decoding keeps the answer "yes, and here is what we could
        // read of it", which is the only safe direction to be wrong in here.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return QuarantineInfo(rawValue: text)
    }

    /// Whether the item carries the attribute. Swallows read errors: a caller asking this
    /// question wants a yes or no for a menu item, and "cannot tell" is a no.
    public static func isQuarantined(_ url: URL) -> Bool {
        ((try? rawValue(of: url))) != nil
    }

    // MARK: - Writing

    /// Write a quarantine value onto an item.
    ///
    /// - Parameter overwritingExisting: When `false` - the default - an item that already
    ///   has a quarantine value keeps it. The value already there was written by the
    ///   system or by whichever application actually downloaded the file, and replacing it
    ///   with the archive's can only ever make the file look *less* suspicious than the
    ///   system already decided it was.
    public static func apply(_ rawValue: Data, to url: URL, overwritingExisting: Bool = false) throws {
        if !overwritingExisting, isQuarantined(url) { return }

        let path = url.path
        try path.withCString { cPath in
            try attributeName.withCString { cName in
                let result = rawValue.withUnsafeBytes { bytes in
                    setxattr(cPath, cName, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
                if result < 0 {
                    throw QuarantineError.writeFailed(
                        path: path, code: errno, reason: String(cString: strerror(errno))
                    )
                }
            }
        }
    }

    /// Copy the source's quarantine onto one extracted item.
    ///
    /// - Returns: `true` when the source was quarantined and the value was written.
    @discardableResult
    public static func propagate(from source: URL, to destination: URL) throws -> Bool {
        guard let value = try rawValue(of: source), !value.isEmpty else { return false }
        try apply(value, to: destination)
        return true
    }

    /// Copy the source's quarantine onto every item of an extracted tree.
    ///
    /// The enumerator does not descend through symbolic links, so a link member pointing
    /// at `/Applications` cannot turn this into a walk over the user's applications.
    /// Per-item write failures do not abort the walk - a file that could not be marked is
    /// worth reporting, but stopping would leave the rest of the tree unmarked, which is
    /// the worse outcome.
    ///
    /// - Returns: The number of items marked.
    @discardableResult
    public static func propagate(from source: URL, toTreeAt root: URL) throws -> Int {
        guard let value = try rawValue(of: source), !value.isEmpty else { return 0 }

        var marked = 0
        try? apply(value, to: root)
        marked += 1

        let manager = FileManager()
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return marked
        }

        for case let item as URL in enumerator {
            do {
                try apply(value, to: item)
                marked += 1
            } catch {
                continue
            }
        }
        return marked
    }
}
