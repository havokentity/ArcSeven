// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The interior of an archive, presented as a navigable folder tree.
//
// ## Why the listing is loaded once and shared
//
// `7zz l -slt` returns the WHOLE archive in one pass — every member, at every depth,
// as a flat list of paths like `docs/manual.pdf`. There is no "list one directory"
// operation, and spawning a process per directory the user clicks into would be both
// slow and wasteful.
//
// So the archive is listed once into an immutable `ArchiveListing`, and navigation is
// pure computation over that snapshot: a provider is just the listing plus a path
// prefix. Descending into `docs` costs nothing.
//
// ## Directories that do not exist
//
// Many archives store only files, with no explicit directory entries — `zip` written
// by `zip -D`, most `tar` streams, anything produced by a naive library. A member at
// `a/b/c.txt` therefore implies directories `a` and `a/b` that have no entry of their
// own. Those are synthesised, or the user would open the archive and see nothing.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// Presents one directory level inside an archive.
public struct ArchiveFolderProvider: FolderProvider {

    /// The archive on disk.
    public let archiveURL: URL

    /// The snapshot every level of this archive shares.
    public let listing: ArchiveListing

    /// Directory prefix within the archive. Empty at the archive's root.
    ///
    /// Never has a leading or trailing separator: `""`, `"docs"`, `"docs/img"`.
    public let subPath: String

    private let engine: any ArchiveEngine

    // MARK: Opening

    /// List an archive and return a provider for its root.
    ///
    /// - Throws: `ArchiveError.wrongPassword` when the archive has encrypted headers
    ///   and no usable password was supplied; the caller is expected to prompt and
    ///   retry rather than treating it as a hard failure.
    public static func open(
        archiveURL: URL,
        engine: any ArchiveEngine,
        password: String? = nil
    ) async throws -> ArchiveFolderProvider {
        let listing = try await engine.list(
            ListRequest(archiveURL: archiveURL, password: password)
        )
        return ArchiveFolderProvider(
            archiveURL: archiveURL,
            listing: listing,
            subPath: "",
            engine: engine
        )
    }

    init(archiveURL: URL, listing: ArchiveListing, subPath: String, engine: any ArchiveEngine) {
        self.archiveURL = archiveURL
        self.listing = listing
        self.subPath = subPath
        self.engine = engine
    }

    // MARK: FolderProvider

    public var kind: FolderKind { .archive }

    /// `/path/to/archive.7z/docs/img` — 7zFM's convention of treating the archive
    /// itself as a directory component in the path.
    public var displayPath: String {
        subPath.isEmpty ? archiveURL.path : archiveURL.path + "/" + subPath
    }

    /// Columns the archive actually populates, in 7zFM's canonical order.
    ///
    /// Driven by the listing rather than hardcoded: a `tar` has no Packed Size or
    /// CRC, and showing permanently empty columns is worse than showing fewer.
    public var availableColumns: [PropID] {
        let canonical: [PropID] = [
            .name, .size, .packedSize, .modified, .created, .accessed,
            .attributes, .crc, .method, .block, .encrypted,
        ]
        var present = Set<PropID>()
        for entry in listing.entries {
            present.formUnion(entry.properties.keys)
            if entry.size != nil { present.insert(.size) }
            if entry.packedSize != nil { present.insert(.packedSize) }
            if entry.modified != nil { present.insert(.modified) }
            if entry.crc != nil { present.insert(.crc) }
        }
        // Name is always shown, even for an archive whose entries carry nothing else.
        return [.name] + canonical.dropFirst().filter { present.contains($0) }
    }

    public func loadChildren() async throws -> [FolderItem] {
        Self.children(of: subPath, in: listing)
    }

    public func child(at item: FolderItem) async throws -> (any FolderProvider)? {
        guard item.isNavigable else { return nil }

        if item.isDirectory {
            return ArchiveFolderProvider(
                archiveURL: archiveURL,
                listing: listing,
                subPath: item.path,          // already the full in-archive path
                engine: engine
            )
        }

        // A nested archive: materialise the member to a temp file and open that.
        // This is how 7zFM browses `outer.7z/inner.tar` to arbitrary depth.
        let temporary = try await extractToTemporary(entryPath: item.path)
        return try await ArchiveFolderProvider.open(archiveURL: temporary, engine: engine)
    }

    public func parent() async throws -> (any FolderProvider)? {
        guard !subPath.isEmpty else {
            // At the archive root, ".." leaves the archive for its containing folder.
            return FileSystemFolderProvider(
                directoryURL: archiveURL.deletingLastPathComponent(),
                engine: engine
            )
        }
        let parentPath = (subPath as NSString).deletingLastPathComponent
        return ArchiveFolderProvider(
            archiveURL: archiveURL,
            listing: listing,
            subPath: parentPath,
            engine: engine
        )
    }

    // MARK: Tree computation

    /// The immediate children of `prefix` within a listing.
    ///
    /// Synthesises directories that have no entry of their own. Pure and static so it
    /// can be tested without an engine or a real archive.
    public static func children(of prefix: String, in listing: ArchiveListing) -> [FolderItem] {
        let normalisedPrefix = prefix.isEmpty ? "" : prefix + "/"
        var items: [FolderItem] = []
        var syntheticDirectories = Set<String>()
        var realEntryPaths = Set<String>()

        for entry in listing.entries {
            let path = Self.normalise(entry.path)
            guard path != prefix else { continue }                    // the level itself
            guard normalisedPrefix.isEmpty || path.hasPrefix(normalisedPrefix) else { continue }

            let remainder = String(path.dropFirst(normalisedPrefix.count))
            guard !remainder.isEmpty else { continue }

            if let separator = remainder.firstIndex(of: "/") {
                // Deeper than one level: the first component is a directory that may
                // or may not have an entry of its own.
                let component = String(remainder[remainder.startIndex..<separator])
                guard !component.isEmpty else { continue }
                syntheticDirectories.insert(normalisedPrefix + component)
            } else {
                realEntryPaths.insert(path)
                items.append(FolderItem(archiveEntry: entry, fullPath: path))
            }
        }

        // Add only the synthesised directories that no real entry already covers.
        for path in syntheticDirectories where !realEntryPaths.contains(path) {
            items.append(
                FolderItem(
                    path: path,
                    name: (path as NSString).lastPathComponent,
                    isNavigable: true,
                    isDirectory: true
                )
            )
        }
        return items
    }

    /// Strip a trailing separator and normalise Windows separators.
    ///
    /// 7-Zip stores `\` for archives created on Windows, and some writers append a
    /// trailing `/` to directory entries.
    static func normalise(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    // MARK: Nested archives

    /// Extract one member to a private temporary directory and return its URL.
    private func extractToTemporary(entryPath: String) async throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ArcSeven-nested-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var request = ExtractRequest(archiveURL: archiveURL, destinationURL: directory)
        request.selectedEntries = [entryPath]
        request.overwriteMode = .overwrite
        for try await _ in engine.extract(request) {}

        let extracted = directory.appendingPathComponent(entryPath)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw ArchiveError.io("Could not open \(entryPath) from \(archiveURL.lastPathComponent).")
        }
        return extracted
    }
}

// MARK: - Row construction

extension FolderItem {
    /// Build a row from an archive entry, using its full in-archive path.
    init(archiveEntry entry: ArchiveEntry, fullPath: String) {
        let isDirectory = entry.isDirectory
        self.init(
            path: fullPath,
            name: (fullPath as NSString).lastPathComponent,
            isNavigable: isDirectory || FileSystemFolderProvider.isArchive(URL(fileURLWithPath: fullPath)),
            isDirectory: isDirectory,
            properties: entry.properties,
            entry: entry
        )
    }
}
