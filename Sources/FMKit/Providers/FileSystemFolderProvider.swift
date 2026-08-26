// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// A directory on disk, presented as a navigable folder.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// Presents a filesystem directory to a panel.
public struct FileSystemFolderProvider: FolderProvider {
    /// The directory this provider represents.
    public let directoryURL: URL

    /// The engine used when descending into an archive. Injected so the panel does
    /// not have to know how archives are opened.
    private let engine: any ArchiveEngine

    public init(directoryURL: URL, engine: any ArchiveEngine) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.engine = engine
    }

    public var kind: FolderKind { .fileSystem }

    public var displayPath: String { directoryURL.path }

    /// Columns that mean something for files on disk.
    ///
    /// Deliberately *not* the archive set: a file on disk has no Packed Size, CRC,
    /// Method or Block. 7zFM varies the column set per folder type the same way.
    public var availableColumns: [PropID] {
        [.name, .size, .modified, .created, .attributes]
    }

    // MARK: Loading

    public func loadChildren() async throws -> [FolderItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .creationDateKey, .isHiddenKey, .isPackageKey,
        ]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: []      // hidden files are filtered below, not here, so the
                                 // "show hidden" toggle does not need a reload path
            )
        } catch {
            throw ArchiveError.io("Cannot read \(directoryURL.path): \(error.localizedDescription)")
        }

        return contents.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            let name = url.lastPathComponent

            var properties: [PropID: String] = [:]
            if let size = values?.fileSize, !isDirectory {
                properties[.size] = String(size)
            }
            if let modified = values?.contentModificationDate {
                properties[.modified] = Self.timestampFormatter.string(from: modified)
            }
            if let created = values?.creationDate {
                properties[.created] = Self.timestampFormatter.string(from: created)
            }

            var entry = ArchiveEntry(path: name, isDirectory: isDirectory)
            entry.size = (values?.fileSize).map(UInt64.init)
            entry.modified = values?.contentModificationDate
            entry.created = values?.creationDate
            entry.properties = properties

            // A `.app`, `.rtfd` or `.photoslibrary` is a directory on disk that Finder
            // presents as one opaque item: double-clicking LAUNCHES it, it does not
            // descend into it, and "Show Package Contents" is a separate command. So a
            // package is neither a directory nor navigable here — it is a leaf that the
            // panel hands to Launch Services, exactly as it does any other file.
            //
            // Until 0.1.5 the two flags disagreed: `isNavigable` said `true` (because
            // `isDirectory` was read straight off the resource values) while
            // `isDirectory` said `false` (because packages were excluded). `child(at:)`
            // matched neither of its branches and returned `nil`, and
            // `PanelViewController.open(rowAt:)` — seeing `isNavigable` — skipped its
            // `NSWorkspace.open` fallback. Double-clicking any package did nothing at
            // all. The comment that stood here claimed packages were being treated "as
            // navigable directories, matching Finder"; Finder does neither.
            return FolderItem(
                path: url.path,
                name: name,
                isNavigable: (isDirectory && !isPackage) || Self.isArchive(url),
                isDirectory: isDirectory && !isPackage,
                properties: properties,
                entry: entry,
                url: url
            )
        }
    }

    // MARK: Navigation

    public func child(at item: FolderItem) async throws -> (any FolderProvider)? {
        guard let url = item.url else { return nil }
        if item.isDirectory {
            return Self(directoryURL: url, engine: engine)
        }
        if Self.isArchive(url) {
            return try await ArchiveFolderProvider.open(archiveURL: url, engine: engine)
        }
        return nil
    }

    public func parent() async throws -> (any FolderProvider)? {
        // `/` is the top; standardized comparison avoids a "/" vs "/." mismatch.
        let parent = directoryURL.deletingLastPathComponent().standardizedFileURL
        guard parent.path != directoryURL.path else { return nil }
        return Self(directoryURL: parent, engine: engine)
    }

    // MARK: Helpers

    /// `true` when the extension names a format `7zz` can read.
    ///
    /// Extension-based only. `7zz` sniffs content and its answer wins, but the panel
    /// needs an answer before spawning anything.
    public static func isArchive(_ url: URL) -> Bool {
        guard let format = FormatCatalog.format(forPathExtension: url.pathExtension) else {
            return false
        }
        return FormatCatalog.canExtract(format)
    }

    /// Matches the timestamp shape `7zz -slt` prints, so a disk row and an archive
    /// row line up in the same column.
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
