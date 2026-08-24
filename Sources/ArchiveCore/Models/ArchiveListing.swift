// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation

/// A complete, flat description of one archive: its members plus the archive-level
/// properties the handler reported.
///
/// This is the value the file-manager panes browse. It is intentionally *flat* —
/// members carry full paths and the tree is built on top in FMKit — because that is
/// what both engines naturally produce and because flat view is a first-class mode
/// in the 7-Zip File Manager, not an afterthought.
public struct ArchiveListing: Sendable, Hashable, Codable {
    /// The archive that was listed. For a multi-volume set this is the volume that
    /// was opened, which must be the first (`.001`) for split archives.
    public var url: URL

    /// The handler that claimed the archive, e.g. ``ArchiveFormat/sevenZip``.
    ///
    /// `nil` when the engine could not determine one — which for a successful
    /// listing effectively cannot happen, but is representable rather than
    /// force-unwrapped.
    public var format: ArchiveFormat?

    /// Members, in the order the handler enumerated them.
    ///
    /// Handler order is meaningful: for `.7z` it is storage order, which groups
    /// members by solid block. The panes re-sort for display and must not assume
    /// this order is alphabetical.
    public var entries: [ArchiveEntry]

    /// `true` when the archive uses solid compression (`Solid = +`).
    ///
    /// Solidity is what makes single-member extraction expensive, so the UI uses
    /// this to decide whether to warn before a partial extract of a large archive.
    public var isSolid: Bool

    /// Multi-volume / split-archive facts.
    public var volumes: VolumeInfo

    /// `true` when the archive's *header* is encrypted (`7zz a -mhe=on`).
    ///
    /// A header-encrypted archive cannot be listed at all without the password, so
    /// this is never discovered from a successful listing — the engine sets it after
    /// a password-less listing attempt fails with a password prompt, and keeps it
    /// set for the listing it later obtains with the password.
    public var isHeaderEncrypted: Bool

    /// Size of the archive file(s) on disk, as the handler reports it.
    public var physicalSize: UInt64?

    /// Bytes of the archive occupied by metadata rather than member data.
    public var headersSize: UInt64?

    /// Number of solid blocks (`.7z`).
    public var blockCount: Int?

    /// Archive-level comment (zip stores one).
    public var comment: String?

    /// All archive-level properties exactly as the engine reported them, for the
    /// Properties inspector and for handler-specific columns.
    public var properties: [PropID: String]

    /// Non-fatal problems noticed while building this listing.
    ///
    /// A listing with warnings is still a usable listing — this mirrors the
    /// engine-wide rule that `7zz` exit code 1 is success, not failure.
    public var warnings: [ArchiveWarning]

    public init(
        url: URL,
        format: ArchiveFormat? = nil,
        entries: [ArchiveEntry] = [],
        isSolid: Bool = false,
        volumes: VolumeInfo = VolumeInfo(),
        isHeaderEncrypted: Bool = false,
        physicalSize: UInt64? = nil,
        headersSize: UInt64? = nil,
        blockCount: Int? = nil,
        comment: String? = nil,
        properties: [PropID: String] = [:],
        warnings: [ArchiveWarning] = []
    ) {
        self.url = url
        self.format = format
        self.entries = entries
        self.isSolid = isSolid
        self.volumes = volumes
        self.isHeaderEncrypted = isHeaderEncrypted
        self.physicalSize = physicalSize
        self.headersSize = headersSize
        self.blockCount = blockCount
        self.comment = comment
        self.properties = properties
        self.warnings = warnings
    }
}

// MARK: - Multi-volume

extension ArchiveListing {
    /// Facts about a split or multi-volume archive.
    public struct VolumeInfo: Sendable, Hashable, Codable {
        /// `true` when the archive spans more than one file.
        public var isMultiVolume: Bool
        /// Total number of volumes, when the handler reports it (`Volumes`).
        public var count: Int?
        /// Index of the opened volume within the set, when reported (`Volume Index`).
        public var index: Int?
        /// The volume files that make up the set, in order, when the engine
        /// resolved them from the filesystem.
        public var urls: [URL]

        public init(
            isMultiVolume: Bool = false,
            count: Int? = nil,
            index: Int? = nil,
            urls: [URL] = []
        ) {
            self.isMultiVolume = isMultiVolume
            self.count = count
            self.index = index
            self.urls = urls
        }
    }
}

// MARK: - Computed totals

extension ArchiveListing {
    /// Number of members that are not directories.
    public var fileCount: Int {
        entries.reduce(into: 0) { $0 += $1.isDirectory ? 0 : 1 }
    }

    /// Number of members that are directories.
    public var directoryCount: Int {
        entries.reduce(into: 0) { $0 += $1.isDirectory ? 1 : 0 }
    }

    /// Sum of every member's uncompressed size. Members with an unknown size
    /// contribute nothing.
    public var totalSize: UInt64 {
        entries.reduce(into: UInt64(0)) { $0 &+= ($1.size ?? 0) }
    }

    /// Sum of every member's compressed size.
    ///
    /// For a solid archive this **under-reports**: only the first member of each
    /// solid block carries a packed size and the rest report nothing (res_3 §4a.4).
    /// Use ``physicalSize`` when you want the honest on-disk figure, and
    /// ``packedSizeIsPerBlock`` to decide which to show.
    public var totalPackedSize: UInt64 {
        entries.reduce(into: UInt64(0)) { $0 &+= ($1.packedSize ?? 0) }
    }

    /// `true` when packed sizes are attributed per solid block rather than per
    /// member, meaning ``totalPackedSize`` is not a per-member breakdown.
    public var packedSizeIsPerBlock: Bool {
        isSolid && entries.contains { !$0.isDirectory && $0.packedSize == nil }
    }

    /// Overall compression ratio in `0...1`, preferring the on-disk physical size
    /// over the summed packed sizes because the latter is unreliable for solid
    /// archives. `nil` when there is nothing to divide by.
    public var compressionRatio: Double? {
        let uncompressed = totalSize
        guard uncompressed > 0 else { return nil }
        let compressed = physicalSize ?? totalPackedSize
        guard compressed > 0 else { return nil }
        return Double(compressed) / Double(uncompressed)
    }

    /// `true` when at least one member's data is encrypted.
    public var hasEncryptedEntries: Bool {
        entries.contains(where: \.isEncrypted)
    }

    /// Number of encrypted members.
    public var encryptedEntryCount: Int {
        entries.reduce(into: 0) { $0 += $1.isEncrypted ? 1 : 0 }
    }

    /// `true` when the archive is encrypted in any way — header or body.
    public var isEncrypted: Bool { isHeaderEncrypted || hasEncryptedEntries }

    /// The union of every property key any member emitted, in `PropID.wellKnown`
    /// order with unknown keys appended alphabetically.
    ///
    /// This is what the column-picker offers for a given archive: 7-Zip advertises
    /// only the properties actually present in the opened archive, and so do we.
    public var availableEntryProperties: [PropID] {
        var seen = Set<PropID>()
        for entry in entries { seen.formUnion(entry.properties.keys) }
        var ordered = PropID.wellKnown.filter { seen.contains($0) }
        let extras = seen.subtracting(ordered).map(\.rawValue).sorted().map(PropID.init(rawValue:))
        ordered.append(contentsOf: extras)
        return ordered
    }

    /// Look up the entry at an exact path.
    public func entry(atPath path: String) -> ArchiveEntry? {
        entries.first { $0.path == path }
    }

    /// Every member whose parent directory is `path` (`""` for the archive root).
    public func children(of path: String) -> [ArchiveEntry] {
        entries.filter { $0.parentPath == path }
    }
}

// MARK: - Warnings

/// A non-fatal problem reported by an engine.
///
/// Warnings never fail an operation. They exist because `7zz` exit code 1 means
/// "finished, with complaints" — the archive was still written, the files were
/// still extracted — and reporting that as an error would make the app cry wolf on
/// every large selection containing one unreadable file (res_3 §4a.8).
public struct ArchiveWarning: Sendable, Hashable, Codable {
    /// The class of problem, for grouping and for choosing an icon.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        /// A path in the input selection could not be scanned (missing, no permission).
        case scan
        /// A member could not be read or written, but the operation continued.
        case item
        /// The engine's output did not match the grammar we expect.
        case malformedOutput
        /// The engine reported something we could not classify.
        case unclassified
    }

    public var kind: Kind
    /// The archive member or filesystem path the warning is about, when known.
    public var path: String?
    /// The engine's own words, preserved verbatim so the Diagnostic Messages
    /// window can show exactly what `7zz` said.
    public var message: String

    public init(kind: Kind, path: String? = nil, message: String) {
        self.kind = kind
        self.path = path
        self.message = message
    }
}
