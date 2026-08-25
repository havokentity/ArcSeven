// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The archive-as-folder abstraction.
//
// This is the single idea that makes a 7-Zip-style file manager work: a panel does
// not know whether it is showing a directory on disk, the inside of a `.7z`, the
// inside of a `.tar` that is itself inside that `.7z`, or the list of mounted
// volumes. It shows a `FolderProvider`. Navigation is `child(at:)` and `parent()`,
// and the panel is identical in every case.
//
// It is upstream 7-Zip's `IFolderFolder` (CPP/7zip/UI/FileManager/IFolder.h) rebuilt
// as a Swift protocol: same responsibility, clean-room implementation.
//
// Nested archives fall out of this for free. Opening `outer.7z/inner.tar` means an
// `ArchiveFolderProvider` whose backing store is a member of another
// `ArchiveFolderProvider`, materialised through a temp file. That is exactly how
// 7zFM does it, and why it can browse arbitrarily deep nesting without special cases.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// One navigable level: a real directory, an archive's interior, or a virtual root.
///
/// Conformers are `Sendable` and safe to hand between the panel actor and background
/// loading tasks.
public protocol FolderProvider: Sendable {
    /// What this level is, which drives the path bar and the column defaults.
    var kind: FolderKind { get }

    /// Display path shown in the panel's path bar.
    ///
    /// For a disk directory this is the filesystem path. For an archive interior it
    /// is `/path/to/archive.7z/sub/dir`, matching 7zFM's convention of treating the
    /// archive as a directory in the path.
    var displayPath: String { get }

    /// The columns worth showing at this level.
    ///
    /// Differs per level: a disk directory has no Packed Size or CRC; a `.7z`
    /// interior has both; a volume list has Free Space and Cluster Size. 7zFM varies
    /// the column set the same way, per folder type.
    var availableColumns: [PropID] { get }

    /// Load this level's immediate children.
    ///
    /// Async because it may spawn `7zz`, read a directory, or materialise a nested
    /// archive to a temp file.
    func loadChildren() async throws -> [FolderItem]

    /// Descend into a child, or `nil` when it is not navigable.
    ///
    /// A `.7z` file returns an archive provider; a directory returns a directory
    /// provider; a plain file returns `nil`.
    func child(at item: FolderItem) async throws -> (any FolderProvider)?

    /// Ascend one level, or `nil` at the root.
    func parent() async throws -> (any FolderProvider)?
}

/// What kind of level a provider represents.
public enum FolderKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// A directory on the filesystem.
    case fileSystem
    /// The interior of an archive.
    case archive
    /// The list of mounted volumes — 7zFM's "Computer".
    case volumes
    /// The virtual root above everything.
    case root
}

/// One row in a panel.
///
/// Deliberately unified across levels: the table binds to this, not to `ArchiveEntry`
/// or to a `URL`, which is what keeps the panel code free of level-specific branches.
public struct FolderItem: Sendable, Hashable, Identifiable {
    /// Stable within a single folder listing.
    public var id: String { path }

    /// Path relative to the containing folder, or an absolute path at the root.
    public var path: String

    /// The leaf name shown in the Name column.
    public var name: String

    /// `true` for anything the panel can descend into, archives included.
    public var isNavigable: Bool

    /// `true` for directories and archive folder entries.
    public var isDirectory: Bool

    /// Every property this level knows about this row, keyed by column.
    ///
    /// The column model reads straight from here, so an unrecognised property from a
    /// format we have never seen still renders in a user-added column.
    public var properties: [PropID: String]

    /// The archive entry this row came from, when the level is an archive.
    public var entry: ArchiveEntry?

    /// The filesystem URL this row came from, when the level is on disk.
    public var url: URL?

    public init(
        path: String,
        name: String,
        isNavigable: Bool,
        isDirectory: Bool,
        properties: [PropID: String] = [:],
        entry: ArchiveEntry? = nil,
        url: URL? = nil
    ) {
        self.path = path
        self.name = name
        self.isNavigable = isNavigable
        self.isDirectory = isDirectory
        self.properties = properties
        self.entry = entry
        self.url = url
    }
}

extension FolderItem {
    /// Build a row from an archive entry.
    public init(entry: ArchiveEntry) {
        self.init(
            path: entry.path,
            name: entry.name,
            isNavigable: entry.isDirectory,
            isDirectory: entry.isDirectory,
            properties: entry.properties,
            entry: entry
        )
    }
}
