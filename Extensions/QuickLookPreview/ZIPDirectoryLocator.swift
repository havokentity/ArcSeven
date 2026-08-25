// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Finding a ZIP's central directory, which is the entire difficulty of reading one.
//
// The table of contents lives at the END of the file, and the record that points at it is
// not at a fixed offset:
//
//   [ optional prefix: a self-extracting stub, or junk ]
//   [ local file header + data ] x N
//   [ central directory file header ] x N          <- what the caller actually wants
//   [ ZIP64 end of central directory record ]      <- only when a 32-bit field overflowed
//   [ ZIP64 end of central directory locator ]
//   [ end of central directory record + comment ]  <- variable length, so it is searched for
//
// Three things make this delicate, and each is handled explicitly below:
//
//   1. The end record carries a 16-bit comment length, so it must be found by scanning
//      backwards - and that comment is attacker-controlled and may itself contain the end
//      record's signature, so "the last match" is not by itself the right answer.
//   2. A prefixed archive - any self-extracting .exe - shifts the whole ZIP forward, while
//      the offsets stored inside it were written as if the prefix were not there.
//   3. ZIP64 replaces any field that would overflow 32 bits with an all-ones sentinel and
//      moves the real value into a second, wider record.

import Foundation

/// Where the central directory is, and how big.
struct ZIPDirectoryLocation {
    var offset: UInt64
    var size: UInt64

    /// The number of members the archive claims to hold. Only used to notice that we read
    /// none when it says there are some.
    var declaredEntryCount: UInt64

    /// File offset of whatever record immediately follows the directory. This is what makes
    /// the prefix shift recoverable: the directory must end where that record begins.
    var offsetOfFollowingRecord: UInt64
}

enum ZIPDirectoryLocator {
    // Signatures, spelled as the little-endian words they are read back as.
    static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50       // PK\5\6
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50        // PK\6\7
    private static let zip64EndSignature: UInt32 = 0x0606_4b50            // PK\6\6

    static let endOfCentralDirectoryLength = 22
    private static let zip64LocatorLength = 20
    private static let zip64EndLength = 56

    private static let sentinel16: UInt16 = 0xFFFF
    private static let sentinel32: UInt32 = 0xFFFF_FFFF

    private static let multiPartMessage = """
        This is one segment of a multi-part ZIP archive. Open it in ArcSeven to see its \
        contents.
        """

    // MARK: - Entry point

    static func locate(in reader: BoundedFileReader) throws -> ZIPDirectoryLocation {
        let tail = try reader.readTail(maxLength: PreviewLimits.endOfCentralDirectoryWindow)

        guard let eocdIndex = findEndOfCentralDirectory(in: tail) else {
            throw ArchiveReadError.malformed("""
                No ZIP directory was found at the end of this file. It may be corrupt, or \
                it may be one segment of a multi-part archive.
                """)
        }
        let eocdFileOffset = tail.fileOffset + UInt64(eocdIndex)

        guard let thisDisk = tail.u16(at: eocdIndex + 4),
              let directoryStartDisk = tail.u16(at: eocdIndex + 6),
              let entriesOnThisDisk = tail.u16(at: eocdIndex + 8),
              let totalEntries = tail.u16(at: eocdIndex + 10),
              let directorySize32 = tail.u32(at: eocdIndex + 12),
              let directoryOffset32 = tail.u32(at: eocdIndex + 16)
        else {
            throw ArchiveReadError.malformed("The ZIP directory record is truncated.")
        }

        // The directory lives in another segment we were never handed. That is a real
        // limitation of previewing one file, not a parse failure, so it is said plainly.
        if thisDisk != directoryStartDisk || (thisDisk != 0 && thisDisk != sentinel16) {
            throw ArchiveReadError.unsupported(multiPartMessage)
        }
        if entriesOnThisDisk != totalEntries && totalEntries != sentinel16 {
            throw ArchiveReadError.unsupported(multiPartMessage)
        }

        let classic = ZIPDirectoryLocation(
            offset: UInt64(directoryOffset32),
            size: UInt64(directorySize32),
            declaredEntryCount: UInt64(totalEntries),
            offsetOfFollowingRecord: eocdFileOffset
        )
        let hasSentinel = totalEntries == sentinel16
            || directorySize32 == sentinel32
            || directoryOffset32 == sentinel32

        var location = hasSentinel
            ? try locateViaZIP64(reader, tail: tail, eocdIndex: eocdIndex, fallingBackTo: classic)
            : classic

        try correctForPrefix(&location, fileSize: reader.byteSize)
        return location
    }

    // MARK: - The end of central directory record

    /// Find the real end of central directory record.
    ///
    /// "The last signature in the file" is not good enough. The record's trailing comment is
    /// attacker-controlled, and a decoy signature planted inside that comment sits AFTER the
    /// genuine record - so a naive backwards scan finds the decoy and reads an empty archive
    /// out of a full one. The disambiguator, and the one both Info-ZIP and 7-Zip use, is
    /// self-consistency: the real record's declared comment length exactly accounts for
    /// every byte between the end of the record and EOF. A decoy embedded in a comment
    /// cannot satisfy that, because the comment continues past it.
    ///
    /// Candidates are examined from the end backwards and the first consistent one wins. If
    /// none is consistent - a valid archive with junk appended after it, which does happen -
    /// the last candidate is used, which is the lenient reading and matches what `unzip`
    /// makes of such a file.
    ///
    /// Cost is one pass over the search window no matter how many decoys it contains,
    /// because each search resumes below the previous hit rather than restarting at EOF.
    private static func findEndOfCentralDirectory(in tail: ByteBuffer) -> Int? {
        var bound = tail.count - endOfCentralDirectoryLength
        var lenientFallback: Int?

        while let candidate = tail.lastIndex(
            ofSignature: endOfCentralDirectorySignature,
            notAfter: bound
        ) {
            if lenientFallback == nil { lenientFallback = candidate }

            if let commentLength = tail.u16(at: candidate + 20),
               Int(commentLength) == tail.count - (candidate + endOfCentralDirectoryLength) {
                return candidate
            }
            bound = candidate - 1
            if bound < 0 { break }
        }
        return lenientFallback
    }

    // MARK: - ZIP64

    /// The ZIP64 path: a 20-byte locator sits immediately before the end record and points
    /// at a second, wider end-of-directory record.
    private static func locateViaZIP64(
        _ reader: BoundedFileReader,
        tail: ByteBuffer,
        eocdIndex: Int,
        fallingBackTo classic: ZIPDirectoryLocation
    ) throws -> ZIPDirectoryLocation {
        do {
            let recordOffset = try zip64EndRecordOffset(reader, tail: tail, eocdIndex: eocdIndex)
            let record = try reader.read(at: recordOffset, length: zip64EndLength)

            guard let totalEntries = record.u64(at: 32),
                  let directorySize = record.u64(at: 40),
                  let directoryOffset = record.u64(at: 48)
            else {
                throw ArchiveReadError.malformed("The ZIP64 directory record is truncated.")
            }
            return ZIPDirectoryLocation(
                offset: directoryOffset,
                size: directorySize,
                declaredEntryCount: totalEntries,
                offsetOfFollowingRecord: recordOffset
            )
        } catch {
            // An archive holding exactly 65535 members saturates the 16-bit count without
            // being ZIP64 at all, and there is then no ZIP64 record to find. The two offsets
            // are what actually matter, so if THEY hold real values rather than sentinels,
            // the classic record was complete and only the count was lost.
            guard classic.size != UInt64(sentinel32), classic.offset != UInt64(sentinel32) else {
                throw error
            }
            return classic
        }
    }

    /// Where the ZIP64 end record actually starts.
    ///
    /// The locator says where it was written, which is wrong by the length of the prefix in
    /// a self-extracting archive. When the signature is not at the stated offset, the record
    /// is instead found by working back from the locator: the record ends exactly where the
    /// locator begins, and its minimum length is 56 bytes. (An archive carrying a ZIP64
    /// extensible data sector would sit further back still. Those are close to nonexistent
    /// in the wild, and getting it wrong here costs a clean error message rather than a
    /// wrong listing.)
    private static func zip64EndRecordOffset(
        _ reader: BoundedFileReader,
        tail: ByteBuffer,
        eocdIndex: Int
    ) throws -> UInt64 {
        let locatorIndex = eocdIndex - zip64LocatorLength
        guard locatorIndex >= 0,
              tail.u32(at: locatorIndex) == zip64LocatorSignature,
              let statedOffset = tail.u64(at: locatorIndex + 8)
        else {
            throw ArchiveReadError.malformed("""
                This archive uses ZIP64 fields but its ZIP64 locator is missing or damaged.
                """)
        }

        if try hasZIP64EndRecord(reader, at: statedOffset) { return statedOffset }

        let locatorFileOffset = tail.fileOffset + UInt64(locatorIndex)
        guard locatorFileOffset >= UInt64(zip64EndLength) else {
            throw ArchiveReadError.malformed("The ZIP64 directory record is missing.")
        }
        let recovered = locatorFileOffset - UInt64(zip64EndLength)
        guard try hasZIP64EndRecord(reader, at: recovered) else {
            throw ArchiveReadError.malformed("The ZIP64 directory record is missing or damaged.")
        }
        return recovered
    }

    private static func hasZIP64EndRecord(_ reader: BoundedFileReader, at offset: UInt64) throws -> Bool {
        guard offset <= reader.byteSize, reader.byteSize - offset >= 4 else { return false }
        return try reader.read(at: offset, length: 4).u32(at: 0) == zip64EndSignature
    }

    // MARK: - Prefixed archives

    /// Recover the prefix shift of a self-extracting or otherwise-prefixed archive.
    ///
    /// The directory must end where the record after it begins. When it does not, the
    /// difference is the size of the prefix that was prepended after the offsets were
    /// written, and adding it back makes every stored offset correct again.
    ///
    /// Only a positive, in-bounds correction is accepted. A negative one means corruption,
    /// and following it would read from somewhere we were never meant to.
    private static func correctForPrefix(
        _ location: inout ZIPDirectoryLocation,
        fileSize: UInt64
    ) throws {
        let (declaredEnd, overflowed) = location.offset.addingReportingOverflow(location.size)
        guard !overflowed else {
            throw ArchiveReadError.malformed("The ZIP directory declares an impossible size.")
        }

        if declaredEnd < location.offsetOfFollowingRecord {
            let delta = location.offsetOfFollowingRecord - declaredEnd
            let (shifted, shiftOverflowed) = location.offset.addingReportingOverflow(delta)
            if !shiftOverflowed, shifted <= fileSize, fileSize - shifted >= location.size {
                location.offset = shifted
            }
        }

        let (end, endOverflowed) = location.offset.addingReportingOverflow(location.size)
        guard !endOverflowed, end <= fileSize else {
            throw ArchiveReadError.malformed("""
                The ZIP directory points past the end of the file. The archive is truncated \
                or corrupt.
                """)
        }
    }
}
