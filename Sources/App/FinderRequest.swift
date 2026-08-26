// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The one-way inbox between the Finder Sync extension and the app.
//
// An appex has no business spawning a long-running `7zz`: it is sandboxed, it is killed
// on a whim, and it holds none of the user's dynamically acquired file grants. So the
// extension does the only thing it is good at — knowing what is selected — writes that
// down, and wakes the app. The app does the work.
//
// **The extension WRITES and the app READS-THEN-REMOVES, so a request is consumed
// exactly once.** Nothing here is a queue that two readers share and nothing here is
// updated in place: a request file is created once, read once, and deleted. That is what
// makes a double-click on a Finder menu item produce one extraction rather than two.
// ``FinderRequestStore/consume(id:)`` is the read-then-remove pair done as a single
// atomic rename, for when a request can be reached by more than one route — a wake-up
// ping naming the id AND a start-up sweep of the directory, which is the normal case.
//
// This file is compiled into BOTH targets, which is why it imports Foundation and
// nothing else. No AppKit: the extension does not link it. No FinderSync: the app does
// not link it, and a shared type that drags a framework behind it stops being shareable.
// Adding a Finder Sync target to project.yml therefore means listing this one file under
// its `sources:` as well.
//
// On the container being absent: `containerURL(forSecurityApplicationGroupIdentifier:)`
// returns nil until the app group entitlement is present in the code signature, which on
// a machine without the provisioning profile is *normal*, not exceptional. Every entry
// point here answers that with a nil or a named error. An archiver that crashes on
// launch because an entitlement has not been granted yet is a far worse failure than one
// whose Finder menu is temporarily inert.

import Foundation

// MARK: - The request

/// What the user asked for in Finder.
///
/// Deliberately three verbs and no destination. The Finder surfaces have no idea where
/// the output should go, what format to use, or whether a password is needed; those are
/// the app's job, and encoding them here would mean two places that have to agree about
/// defaults.
public enum FinderRequestAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Add the selection to a new archive.
    case compress
    /// Unpack the selected archive(s), choosing a destination by inspecting the archive:
    /// loose when it holds a single root item, wrapped in a folder when it would otherwise
    /// scatter its contents over the enclosing directory.
    case extract
    /// Unpack into a folder named after the archive, always.
    case extractToSubfolder
    /// Browse the selected archive in the file manager window.
    case open
}

/// One thing the user asked for, addressed to the app.
///
/// `paths` rather than `URL`s because this is what crosses a process boundary as JSON:
/// a URL encodes to a string with a scheme and percent-escapes, and round-tripping a
/// file system path through that is a lossy game nobody needs to play. ``urls`` converts
/// on the reading side.
public struct FinderRequest: Codable, Sendable, Hashable {
    /// Identifies the request, names its file on disk, and is what a wake-up ping
    /// carries so the app can go straight to it instead of scanning.
    public var id: UUID

    /// The verb.
    public var action: FinderRequestAction

    /// The selection, as file system paths, in the order Finder presented them.
    public var paths: [String]

    /// When the extension wrote it. Used to drop requests the app never got to —
    /// see ``FinderRequestStore/pruneStale(olderThan:)``.
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        action: FinderRequestAction,
        paths: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.action = action
        self.paths = paths
        self.createdAt = createdAt
    }

    /// Convenience for the writing side, which is holding URLs already.
    public init(id: UUID = UUID(), action: FinderRequestAction, urls: [URL], createdAt: Date = Date()) {
        self.init(id: id, action: action, paths: urls.map(\.path), createdAt: createdAt)
    }

    /// The selection as file URLs.
    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
}

// MARK: - Failures

/// Why a request could not be written, found, or read back.
///
/// Every case names the thing that went wrong precisely enough to act on: the app group
/// case in particular must never be reported as "extraction failed", because the fix is
/// a provisioning one and the user's archive is fine.
public enum FinderRequestError: Error, LocalizedError, Hashable, Sendable {
    /// No app group container. The entitlement is missing from the running binary's
    /// signature, or the container has not been provisioned for this user yet.
    case appGroupUnavailable(identifier: String)

    /// Nothing on disk under that id. Ordinary rather than alarming: it is what a second
    /// consumer sees after the first one took the request, and what a stale wake-up ping
    /// sees after ``FinderRequestStore/pruneStale(olderThan:)`` has run.
    case notFound(id: UUID)

    /// The file exists but could not be read.
    case unreadable(id: UUID, reason: String)

    /// The file was read but is not a request. Truncated by a crash mid-write, or
    /// written by an older build.
    case malformed(id: UUID, reason: String)

    /// The request could not be handed over.
    case writeFailed(id: UUID, reason: String)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable(let identifier):
            "The shared container '\(identifier)' is not available to this build of ArcSeven."
        case .notFound(let id):
            "The Finder request \(id.uuidString) is no longer available."
        case let .unreadable(id, reason):
            "The Finder request \(id.uuidString) could not be read: \(reason)"
        case let .malformed(id, reason):
            "The Finder request \(id.uuidString) is not readable by this version: \(reason)"
        case let .writeFailed(id, reason):
            "The Finder request \(id.uuidString) could not be handed to ArcSeven: \(reason)"
        }
    }
}

// MARK: - The store

/// Reads and writes request files in the shared container.
///
/// Layout, and it is deliberately boring:
///
/// ```text
/// ~/Library/Group Containers/<team>.group.com.havokentity.ArcSeven/
///     Requests/
///         3A1F….json          a request waiting to be consumed
///         3A1F….claimed       a request some reader has taken, mid-decode
/// ```
///
/// One file per request means the filesystem does the locking. `rename(2)` is atomic, so
/// the reader that wins the move owns the request and every other reader gets
/// ``FinderRequestError/notFound(id:)`` — which is precisely the exactly-once guarantee
/// this transport needs, without a lock file, a database, or a daemon.
public enum FinderRequestStore {
    // MARK: Identity

    /// The app group, unprefixed. This is the name as it appears in the developer
    /// portal and in conversation.
    public static let appGroupIdentifier = "group.com.havokentity.ArcSeven"

    /// The Team ID that macOS requires in front of it.
    public static let teamIdentifierPrefix = "HAMH7N3PJR"

    /// What is actually passed to `FileManager`, and what appears in the entitlements of
    /// all three bundles.
    ///
    /// macOS app groups are team-prefixed; iOS ones are not. Getting this wrong returns
    /// a silent nil rather than an error, which is why the lookup below tries the
    /// prefixed form first and the bare form second instead of assuming either.
    public static let containerIdentifier = "\(teamIdentifierPrefix).\(appGroupIdentifier)"

    /// Subdirectory of the container holding requests.
    public static let requestsDirectoryName = "Requests"

    /// Extension of a request waiting to be consumed.
    public static let requestFileExtension = "json"

    /// Extension of a request a reader has taken but not yet decoded. Left behind only
    /// by a crash between the rename and the delete, and swept by ``pruneStale(olderThan:)``.
    public static let claimedFileExtension = "claimed"

    // MARK: Locations

    /// The `Requests` directory, or nil when there is no shared container.
    ///
    /// Resolves a location; it does not create anything and does not care whether the
    /// directory exists. ``write(_:)`` creates it, and every reader treats "absent" and
    /// "empty" as the same answer.
    public static func requestsDirectory() -> URL? {
        containerURL()?.appendingPathComponent(requestsDirectoryName, isDirectory: true)
    }

    private static func containerURL() -> URL? {
        let manager = FileManager.default
        for identifier in [containerIdentifier, appGroupIdentifier] {
            if let url = manager.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return url
            }
        }
        return nil
    }

    private static func fileURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(requestFileExtension)")
    }

    private static func claimURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(claimedFileExtension)")
    }

    // MARK: Writing — the extension's half

    /// Hand a request to the app. Returns where it landed.
    ///
    /// Written with `.atomic`, so a reader woken by a directory watcher can never see a
    /// half-written file: the data goes to a sibling temp file and is renamed into place.
    @discardableResult
    public static func write(_ request: FinderRequest) throws -> URL {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let url = fileURL(for: request.id, in: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try makeEncoder().encode(request).write(to: url, options: [.atomic])
        } catch {
            throw FinderRequestError.writeFailed(id: request.id, reason: error.localizedDescription)
        }
        return url
    }

    // MARK: Reading — the app's half

    /// Read a request without consuming it.
    ///
    /// Pair it with ``remove(id:)`` once the work has actually been started, or use
    /// ``consume(id:)`` when more than one route can reach the same request.
    public static func read(id: UUID) throws -> FinderRequest {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let url = fileURL(for: id, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FinderRequestError.notFound(id: id)
        }
        return try decodeRequest(at: url, id: id)
    }

    /// Take a request: exactly one caller can succeed, and the file is gone afterwards.
    ///
    /// The rename is the claim. A second caller — the start-up sweep racing the wake-up
    /// ping that named the same id — finds nothing to move and gets
    /// ``FinderRequestError/notFound(id:)``, which is the correct answer rather than an
    /// error worth showing anyone.
    ///
    /// A request that cannot be decoded is deleted rather than left behind. It cannot be
    /// acted on by this build or any later one, and leaving it would mean re-reading it
    /// on every launch forever.
    public static func consume(id: UUID) throws -> FinderRequest {
        guard let directory = requestsDirectory() else {
            throw FinderRequestError.appGroupUnavailable(identifier: containerIdentifier)
        }
        let manager = FileManager.default
        let claim = claimURL(for: id, in: directory)
        try? manager.removeItem(at: claim)
        do {
            try manager.moveItem(at: fileURL(for: id, in: directory), to: claim)
        } catch {
            // Never existed, or someone else won the rename. Same outcome either way.
            throw FinderRequestError.notFound(id: id)
        }
        defer { try? manager.removeItem(at: claim) }
        return try decodeRequest(at: claim, id: id)
    }

    /// Forget a request, consumed or not. Best effort by design: the app must not fail an
    /// extraction because the note that asked for it could not be torn up.
    public static func remove(id: UUID) {
        guard let directory = requestsDirectory() else { return }
        let manager = FileManager.default
        try? manager.removeItem(at: fileURL(for: id, in: directory))
        try? manager.removeItem(at: claimURL(for: id, in: directory))
    }

    /// Ids of the requests waiting to be consumed, oldest first.
    ///
    /// This is how the app picks up work handed over while it was not running, and the
    /// ordering matters: a user who fired three verbs at Finder in a row expects them in
    /// the order they fired them.
    public static func pendingRequestIDs() -> [UUID] {
        guard let directory = requestsDirectory() else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { $0.pathExtension == requestFileExtension }
            .compactMap { url -> (id: UUID, date: Date)? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    return nil
                }
                return (id, modificationDate(of: url) ?? .distantPast)
            }
            .sorted { $0.date < $1.date }
            .map(\.id)
    }

    /// Delete anything in the directory older than `seconds`.
    ///
    /// Requests are not durable work items. One written while the app was quit, whose
    /// wake-up never arrived, describes a selection the user has long since moved on
    /// from — acting on it an hour later would be a surprise, not a service.
    ///
    /// Sweeps by file modification date rather than by the encoded `createdAt`, and does
    /// NOT skip hidden files, so that abandoned `.claimed` files and the temp files an
    /// interrupted atomic write leaves behind are collected too. A request too corrupt to
    /// decode still has an mtime.
    public static func pruneStale(olderThan seconds: TimeInterval = 3600) {
        guard let directory = requestsDirectory() else { return }
        let manager = FileManager.default
        let cutoff = Date(timeIntervalSinceNow: -seconds)
        let contents = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        for url in contents where (modificationDate(of: url) ?? .distantPast) < cutoff {
            try? manager.removeItem(at: url)
        }
    }

    // MARK: Plumbing

    private static func decodeRequest(at url: URL, id: UUID) throws -> FinderRequest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FinderRequestError.unreadable(id: id, reason: error.localizedDescription)
        }
        do {
            return try makeDecoder().decode(FinderRequest.self, from: data)
        } catch {
            throw FinderRequestError.malformed(id: id, reason: error.localizedDescription)
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Fresh each call. `JSONEncoder` is not `Sendable`, and a shared one reachable from
    /// both an appex and the app is exactly the kind of static this project does not keep.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Readable on purpose: `cat`-ing one of these while debugging a Finder menu that
        // "does nothing" is the whole diagnostic, and the files are a few hundred bytes.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
