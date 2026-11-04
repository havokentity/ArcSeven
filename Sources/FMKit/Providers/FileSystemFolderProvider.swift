// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// A directory on disk, presented as a navigable folder.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(Support)   // module-guard
import Support
#endif

/// Presents a filesystem directory to a panel.
public struct FileSystemFolderProvider: FolderProvider {
    /// The directory this provider represents.
    public let directoryURL: URL

    /// The engine used when descending into an archive. Injected so the panel does
    /// not have to know how archives are opened.
    private let engine: any ArchiveEngine

    /// An explicit answer to "list hidden items?", or `nil` to follow the user's
    /// Whether this provider follows the user's setting or pins an answer.
    ///
    /// An enum rather than `Bool?`: three states spelled out beats a nil that the reader has
    /// to be told means "ask the defaults".
    public enum HiddenFilePolicy: Sendable {
        /// Read the user's preference on every load.
        case followSetting
        case show
        case hide
    }

    /// setting. See ``showsHiddenFiles``.
    private let hiddenFilePolicy: HiddenFilePolicy

    /// The `UserDefaults` key the UI writes to turn hidden items on and off.
    ///
    /// A macOS-only setting: 7zFM has no equivalent, because on Windows the file
    /// manager inherits the shell's own "show hidden files" state. Named in the same
    /// `FM.` family as the keys `SettingsUI` owns so it reads alongside them in a
    /// `defaults read` dump.
    ///
    /// - Important: This is **not** `FM.ShowDots`. That key is 7zFM's `Show ".." item`
    ///   (FIDELITY OPT-18) — the synthetic parent row — and has nothing to do with
    ///   dot-files despite the name.
    /// Re-exported so callers need not import Support just to name the key.
    public static var showHiddenFilesKey: String { Defaults.showHiddenFilesKey }

    /// Whether items the filesystem marks hidden are listed.
    ///
    /// Read from the standard defaults domain rather than through `SettingsUI`, which
    /// depends on this module and so cannot be depended upon from here; the key's raw
    /// value is the API between the two. Absent means `false`, so a fresh install hides
    /// dot-files the way Finder does.
    ///
    /// Deliberately computed rather than captured at init: a provider that answered
    /// from a snapshot would need the panel to rebuild it whenever the setting changed,
    /// and `panel.reload()` alone would show the stale answer.
    public var showsHiddenFiles: Bool {
        switch hiddenFilePolicy {
        case .followSetting: Defaults.showsHiddenFiles()
        case .show: true
        case .hide: false
        }
    }

    /// - Parameter hiddenFiles: `.followSetting` — the default — reads the user's
    ///   preference on every load. Only tests and callers that must pin the behaviour pass
    ///   `.show` or `.hide`.
    public init(
        directoryURL: URL,
        engine: any ArchiveEngine,
        hiddenFiles: HiddenFilePolicy = .followSetting
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.engine = engine
        self.hiddenFilePolicy = hiddenFiles
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
                // NOT `.skipsHiddenFiles`: the filter belongs below, against
                // `showsHiddenFiles`, so flipping the setting needs nothing more than
                // `panel.reload()` — no new provider, no navigation, no reload path of
                // its own. Through 0.1.5 this comment described a filter that did not
                // exist: `values?.isHidden` was requested and then never read, so
                // `.DS_Store`, `.git` and `.localized` appeared in every panel.
                options: []
            )
        } catch {
            throw ArchiveError.io("Cannot read \(directoryURL.path): \(error.localizedDescription)")
        }

        // Resolved once per load, so a setting changed mid-enumeration cannot produce a
        // listing that is half filtered.
        let showsHidden = showsHiddenFiles
        // Built once, not once per row: a directory of fifty thousand files is fifty
        // thousand hashed sets otherwise.
        let keySet = Set(keys)

        return contents.compactMap { url -> FolderItem? in
            let values = try? url.resourceValues(forKeys: keySet)
            // `isHidden` is the whole Finder rule, not just a leading dot: it also
            // covers the `UF_HIDDEN` flag that `~/Library` and `/Volumes/.timemachine`
            // carry, which a name test would miss.
            guard showsHidden || !(values?.isHidden ?? false) else { return nil }
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
            // The override travels with the navigation: a caller that pinned the
            // behaviour meant it for the whole walk, not just the level it opened.
            return Self(
                directoryURL: url, engine: engine, hiddenFiles: hiddenFilePolicy
            )
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
        return Self(
            directoryURL: parent, engine: engine, hiddenFiles: hiddenFilePolicy
        )
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
