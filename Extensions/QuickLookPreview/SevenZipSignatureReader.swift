// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The 7z signature header - and an explicit statement of where this stops.
//
// SCOPE, deliberately: this reads and validates the 32-byte signature header and nothing
// else. It does not list the members of a .7z, and it is not going to.
//
// The reason is structural rather than a matter of effort. A ZIP stores its table of
// contents as plain records at a findable offset, which is why the ZIP reader next door can
// produce a real listing from two bounded reads. 7z does not: the member list lives in the
// "next header", which in every archive produced by a default 7-Zip invocation is a
// kEncodedHeader - a fully formed compressed stream, normally LZMA, that must be decoded
// before a single filename exists. Doing that here would mean carrying an LZMA decoder
// inside a Quick Look appex and running it over attacker-controlled input in a
// memory-capped, short-lived process. That is a decompressor in the most hostile place in
// the product, for a glance at a file list.
//
// The alternative - shelling out to `7zz` - is not available either, and not merely
// inadvisable: the helper lives in the container app's bundle, and a sandboxed app
// extension has no right to execute it.
//
// So a .7z gets an honest preview: the format, the version, the fact that it validates, and
// a sentence saying where to get the listing. That is strictly more than macOS shows today,
// and it is true. Guessing at member names from an undecoded header would not be.

import Foundation

enum SevenZipSignatureReader {
    /// `7z\xBC\xAF\x27\x1C`. The six bytes that begin every 7z archive.
    static let magic: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]

    /// Signature header layout:
    ///
    ///      0   6   magic
    ///      6   1   format version, major
    ///      7   1   format version, minor
    ///      8   4   CRC-32 of the 20 bytes that follow
    ///     12   8   next header offset, relative to the end of this header
    ///     20   8   next header size
    ///     28   4   CRC-32 of the next header
    private static let signatureHeaderLength = 32
    private static let startHeaderOffset = 12
    private static let startHeaderLength = 20

    /// The two facts the rest of this file needs out of a validated header.
    private struct SignatureHeader {
        let version: String
        /// Zero means the archive holds no members at all.
        let nextHeaderSize: UInt64
    }

    static func read(_ reader: BoundedFileReader, displayName: String) throws -> ArchiveDirectory {
        let header = try signatureHeader(reader)

        // A 7z with no members has a zero-size next header and is exactly 32 bytes long.
        // This is the one case where the signature header tells the whole story.
        if header.nextHeaderSize == 0 {
            return ArchiveDirectory(
                displayName: displayName,
                archiveByteSize: reader.byteSize,
                format: .sevenZip(version: header.version),
                entries: [],
                fileCount: 0,
                directoryCount: 0,
                encryptedCount: 0,
                totalUncompressedSize: 0,
                isTruncated: false,
                note: "This archive is empty."
            )
        }

        return ArchiveDirectory(
            displayName: displayName,
            archiveByteSize: reader.byteSize,
            format: .sevenZip(version: header.version),
            entries: [],
            fileCount: 0,
            directoryCount: 0,
            encryptedCount: 0,
            totalUncompressedSize: 0,
            isTruncated: false,
            // The member list is behind a compressed header this extension does not decode,
            // so the counts are not zero - they are unknown. Reporting "0 files" about a
            // perfectly good archive would be a lie.
            countsAreKnown: false,
            note: """
                Valid 7z archive, format version \(header.version). The list of files is \
                stored in a compressed metadata header, which this preview does not \
                decompress. Open the archive in ArcSeven to browse its contents.
                """
        )
    }

    /// Read the 32-byte signature header and prove it is internally consistent.
    private static func signatureHeader(_ reader: BoundedFileReader) throws -> SignatureHeader {
        guard reader.byteSize >= UInt64(signatureHeaderLength) else {
            throw ArchiveReadError.malformed("This file is too short to be a 7z archive.")
        }
        let header = try reader.read(at: 0, length: signatureHeaderLength)

        guard let magicBytes = header.slice(at: 0, length: magic.count),
              Array(magicBytes) == magic
        else {
            throw ArchiveReadError.malformed("This file does not begin with a 7z signature.")
        }

        guard let major = header.u8(at: 6),
              let minor = header.u8(at: 7),
              let declaredCRC = header.u32(at: 8),
              let nextHeaderOffset = header.u64(at: 12),
              let nextHeaderSize = header.u64(at: 20),
              let startHeader = header.slice(at: startHeaderOffset, length: startHeaderLength)
        else {
            throw ArchiveReadError.malformed("The 7z signature header is truncated.")
        }

        // The CRC is the only cheap way to know that the offset and size below are the
        // archive's real values rather than garbage from a truncated download. Checking it
        // before trusting them is the difference between a clean message and a nonsense one.
        guard CRC32.checksum(startHeader) == declaredCRC else {
            throw ArchiveReadError.malformed("""
                The 7z header failed its checksum. The archive is damaged or incomplete.
                """)
        }

        try validateHeaderExtent(
            offset: nextHeaderOffset,
            size: nextHeaderSize,
            fileSize: reader.byteSize
        )
        return SignatureHeader(version: "\(major).\(minor)", nextHeaderSize: nextHeaderSize)
    }

    /// The metadata header has to lie inside the file. Two overflow-reporting additions,
    /// because both operands come straight from the file and either may be UInt64.max.
    private static func validateHeaderExtent(
        offset: UInt64,
        size: UInt64,
        fileSize: UInt64
    ) throws {
        let (start, offsetOverflowed) = UInt64(signatureHeaderLength).addingReportingOverflow(offset)
        let (end, sizeOverflowed) = start.addingReportingOverflow(size)
        guard !offsetOverflowed, !sizeOverflowed, end <= fileSize else {
            throw ArchiveReadError.malformed("""
                The 7z header points past the end of the file. The archive is truncated.
                """)
        }
    }
}

/// CRC-32, the ordinary reflected polynomial 0xEDB88320 that ZIP, 7z and zlib all use.
///
/// Bitwise rather than table-driven on purpose: the only thing checksummed in this extension
/// is a 20-byte header, so 160 shifts beat allocating a 1 KB table - and a table would have
/// to be a `static let`, which under Swift 6 strict concurrency is one more shared global to
/// justify for no gain.
enum CRC32 {
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
