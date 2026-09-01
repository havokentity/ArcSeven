// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// What the preview knows about an archive: the model the parsers fill in and the view
// renders. Value types only, and `Sendable`, because this is what crosses back from the
// off-main-actor parse into the view controller.
//
// Note the absence of a throwing surface. A malformed archive is not an exceptional
// condition here - it is a thing to *display*. `ArchiveDirectory.failed(...)` is a
// perfectly ordinary preview whose body happens to be a sentence explaining why there is
// no listing. Throwing out of `preparePreviewOfFile(at:)` instead would replace all of
// that with Quick Look's generic "no preview available" slab, which tells the user less
// than we already know.

import Foundation

/// The formats this extension can say something about.
///
/// Deliberately not a catalogue of everything the app supports. The container app has
/// `7zz`; an appex does not, and must not - the helper lives in the *app's* bundle and a
/// sandboxed extension has no right to execute it. So this enum lists what a bounded,
/// read-only header parse can establish and nothing else.
enum ArchiveFormat: Sendable, Equatable {
    /// A ZIP container, including the many things that are one underneath: `.zipx`,
    /// `.jar`, `.war`, `.docx`, and a self-extracting `.exe` with a ZIP glued to the end.
    case zip

    /// A 7z container. The version comes from the signature header's two version bytes.
    case sevenZip(version: String)

    /// Recognised by magic, but not parsed here. The payload is the name to show.
    case other(name: String)

    /// Short label for the header line.
    var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7z"
        case .other(let name): return name
        }
    }
}

/// One member of an archive, reduced to what a preview shows.
struct ArchiveDirectoryEntry: Sendable, Identifiable {
    /// Stable identity for the table view. The in-archive path is not usable as an id -
    /// nothing stops a hostile archive from listing the same path twice - so this is the
    /// walk order instead.
    let id: Int

    /// Full path inside the archive, already sanitised for display by the parser: control
    /// characters and bidirectional overrides replaced, separators normalised, length
    /// capped. Never feed this to the filesystem; it is a label.
    let path: String

    /// The archive's own claim about the member's size before compression. Not verified
    /// against anything - verifying would mean decompressing, which this extension never
    /// does - so it is a claim, and is presented as one.
    let uncompressedSize: UInt64

    let isDirectory: Bool

    /// Set when the member's contents are encrypted. The *names* are still readable here;
    /// a ZIP with an encrypted central directory is a different feature (strong encryption)
    /// and shows up as an unreadable directory instead.
    let isEncrypted: Bool

    /// Last path component, for when the full path is not what is wanted.
    var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let tail = path[path.index(after: slash)...]
        return tail.isEmpty ? path : String(tail)
    }
}

/// Everything the preview needs to draw one archive.
struct ArchiveDirectory: Sendable {
    /// The archive file's own name, for the title line.
    let displayName: String

    /// Size on disk of the archive itself. Measured, not claimed.
    let archiveByteSize: UInt64

    let format: ArchiveFormat

    /// The members, already capped at `PreviewLimits.maxRenderedEntries`.
    let entries: [ArchiveDirectoryEntry]

    /// Counted across the whole walk, which may have gone further than `entries`.
    let fileCount: Int
    let directoryCount: Int
    let encryptedCount: Int

    /// Sum of the members' declared uncompressed sizes across the whole walk.
    let totalUncompressedSize: UInt64

    /// True when the walk stopped at a limit rather than at the end of the directory, so
    /// the counts above are floors rather than totals. The header line says so.
    let isTruncated: Bool

    /// Whether the counts above mean anything.
    ///
    /// Zero files and "we could not find out how many files" are different facts, and a
    /// header line that says "0 files" about a perfectly good 7z is simply wrong. A reader
    /// that cannot enumerate members clears this and the header omits the counts rather
    /// than reporting zeroes it does not believe.
    let countsAreKnown: Bool

    /// A sentence shown under the header when there is something the user should know but
    /// that is not an error: the 7z "the member list is inside a compressed metadata
    /// header" case, most of the time.
    let note: String?

    /// Set when there is no listing at all and this sentence is the whole preview.
    let failure: String?

    /// Convenience for the view: is there a table to draw?
    var hasListing: Bool { !entries.isEmpty }

    /// Spelled out rather than left to the memberwise initialiser so that `countsAreKnown`
    /// and the two optional sentences can default, and adding a field later does not
    /// rewrite every call site.
    init(
        displayName: String,
        archiveByteSize: UInt64,
        format: ArchiveFormat,
        entries: [ArchiveDirectoryEntry],
        fileCount: Int,
        directoryCount: Int,
        encryptedCount: Int,
        totalUncompressedSize: UInt64,
        isTruncated: Bool,
        countsAreKnown: Bool = true,
        note: String? = nil,
        failure: String? = nil
    ) {
        self.displayName = displayName
        self.archiveByteSize = archiveByteSize
        self.format = format
        self.entries = entries
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.encryptedCount = encryptedCount
        self.totalUncompressedSize = totalUncompressedSize
        self.isTruncated = isTruncated
        self.countsAreKnown = countsAreKnown
        self.note = note
        self.failure = failure
    }

    /// A preview that is nothing but an explanation.
    static func failed(
        displayName: String,
        archiveByteSize: UInt64,
        format: ArchiveFormat,
        message: String
    ) -> Self {
        Self(
            displayName: displayName,
            archiveByteSize: archiveByteSize,
            format: format,
            entries: [],
            fileCount: 0,
            directoryCount: 0,
            encryptedCount: 0,
            totalUncompressedSize: 0,
            isTruncated: false,
            countsAreKnown: false,
            note: nil,
            failure: message
        )
    }
}
