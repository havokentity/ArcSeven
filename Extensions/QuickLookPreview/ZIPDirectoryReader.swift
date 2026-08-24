// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The ZIP listing: walk the central directory and tally what is in it.
//
// A ZIP is worth previewing without a decompressor precisely because its table of contents
// is stored verbatim - member names, sizes and flags are plain fields, and reaching them
// costs one backwards scan plus one bounded read. Nothing in this file, or anywhere else in
// this extension, decompresses a single byte.
//
// `ZIPDirectoryLocator` answers "where is the directory"; `ZIPCentralDirectoryRecord`
// answers "what does one entry say"; this answers "what is in the whole thing".

import Foundation

enum ZIPDirectoryReader {

    static func read(_ reader: BoundedFileReader, displayName: String) throws -> ArchiveDirectory {
        let location = try ZIPDirectoryLocator.locate(in: reader)

        // An empty ZIP is legal - an end record and nothing else - and is not an error.
        if location.size == 0 && location.declaredEntryCount == 0 {
            return empty(displayName: displayName, archiveByteSize: reader.byteSize)
        }

        let ceiling = PreviewLimits.maxCentralDirectoryBytes
        let readLength = Int(min(location.size, UInt64(ceiling)))
        let directory = try reader.read(at: location.offset, length: readLength)

        return walk(
            directory,
            declaredEntryCount: location.declaredEntryCount,
            hitReadCeiling: location.size > UInt64(ceiling),
            displayName: displayName,
            archiveByteSize: reader.byteSize
        )
    }

    // MARK: - Walking

    private static func walk(
        _ directory: ByteBuffer,
        declaredEntryCount: UInt64,
        hitReadCeiling: Bool,
        displayName: String,
        archiveByteSize: UInt64
    ) -> ArchiveDirectory {
        var tally = Tally(expectedCount: declaredEntryCount)
        var offset = 0

        walkLoop: while tally.walked < PreviewLimits.maxWalkedEntries {
            switch ZIPCentralDirectoryRecord.parse(in: directory, at: offset) {
            case .record(let record):
                offset += record.recordLength
                tally.add(record)

            case .endOfDirectory:
                // Either the clean end of the directory, or the point at which the read
                // ceiling cut it off. `hitReadCeiling` is what tells the two apart.
                break walkLoop

            case .malformed:
                tally.stoppedEarly = true
                break walkLoop
            }
        }
        if tally.walked >= PreviewLimits.maxWalkedEntries { tally.stoppedEarly = true }

        // Nothing parsed at all, but the archive says it holds members: the directory is
        // either encrypted - ZIP strong encryption masks it - or damaged. Either way there
        // is no listing, and saying which is more use than an empty table.
        guard tally.walked > 0 || declaredEntryCount == 0 else {
            return unreadable(
                displayName: displayName,
                archiveByteSize: archiveByteSize,
                declaredEntryCount: declaredEntryCount
            )
        }

        return tally.directory(
            displayName: displayName,
            archiveByteSize: archiveByteSize,
            hitReadCeiling: hitReadCeiling
        )
    }

    // MARK: - Terminal states

    private static func empty(displayName: String, archiveByteSize: UInt64) -> ArchiveDirectory {
        ArchiveDirectory(
            displayName: displayName,
            archiveByteSize: archiveByteSize,
            format: .zip,
            entries: [],
            fileCount: 0,
            directoryCount: 0,
            encryptedCount: 0,
            totalUncompressedSize: 0,
            isTruncated: false,
            note: "This archive is empty."
        )
    }

    private static func unreadable(
        displayName: String,
        archiveByteSize: UInt64,
        declaredEntryCount: UInt64
    ) -> ArchiveDirectory {
        let count = declaredEntryCount.formatted(.number)
        let noun = declaredEntryCount == 1 ? "item" : "items"
        return .failed(
            displayName: displayName,
            archiveByteSize: archiveByteSize,
            format: .zip,
            message: """
                This archive lists \(count) \(noun), but its directory could not be read. \
                It may be encrypted or damaged.
                """
        )
    }
}

/// Running totals across the directory walk.
///
/// A separate type rather than a fistful of `var`s in the loop, because the accumulation
/// has one genuinely subtle rule in it - the overflow guard below - and that rule deserves
/// somewhere to live where it can be read.
private struct Tally {

    var entries: [ArchiveDirectoryEntry] = []
    var walked = 0
    var fileCount = 0
    var directoryCount = 0
    var encryptedCount = 0
    var totalUncompressedSize: UInt64 = 0
    var stoppedEarly = false
    var sizesOverflowed = false

    init(expectedCount: UInt64) {
        entries.reserveCapacity(
            min(Int(clamping: expectedCount), PreviewLimits.maxRenderedEntries)
        )
    }

    mutating func add(_ record: ZIPCentralDirectoryRecord) {
        if record.isDirectory {
            directoryCount += 1
        } else {
            fileCount += 1
            let (sum, overflowed) = totalUncompressedSize
                .addingReportingOverflow(record.uncompressedSize)
            // A hostile archive can declare member sizes that sum past 2^64. Stop
            // accumulating rather than wrapping round to a smaller, wrong number.
            if overflowed { sizesOverflowed = true } else { totalUncompressedSize = sum }
        }
        if record.isEncrypted { encryptedCount += 1 }

        if entries.count < PreviewLimits.maxRenderedEntries {
            entries.append(
                ArchiveDirectoryEntry(
                    id: walked,
                    path: record.path,
                    uncompressedSize: record.uncompressedSize,
                    isDirectory: record.isDirectory,
                    isEncrypted: record.isEncrypted
                )
            )
        }
        walked += 1
    }

    func directory(
        displayName: String,
        archiveByteSize: UInt64,
        hitReadCeiling: Bool
    ) -> ArchiveDirectory {
        ArchiveDirectory(
            displayName: displayName,
            archiveByteSize: archiveByteSize,
            format: .zip,
            entries: entries,
            fileCount: fileCount,
            directoryCount: directoryCount,
            encryptedCount: encryptedCount,
            totalUncompressedSize: totalUncompressedSize,
            isTruncated: stoppedEarly || hitReadCeiling || entries.count < walked,
            note: sizesOverflowed
                ? "The archive declares member sizes that do not add up. The total is a lower bound."
                : nil
        )
    }
}
