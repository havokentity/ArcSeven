// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// One central directory file header, reduced to the five facts a preview shows.
//
// Layout, 46 fixed bytes followed by three variable-length runs:
//
//    0  u32  signature 0x02014b50
//    4  u16  version made by            (high byte is the host system - see isDirectory)
//    6  u16  version needed
//    8  u16  general purpose flags      (bit 0 encrypted, bit 11 UTF-8 name)
//   10  u16  compression method
//   12  u16  last modified time
//   14  u16  last modified date
//   16  u32  CRC-32
//   20  u32  compressed size
//   24  u32  uncompressed size
//   28  u16  file name length
//   30  u16  extra field length
//   32  u16  file comment length
//   34  u16  disk number start
//   36  u16  internal attributes
//   38  u32  external attributes
//   42  u32  relative offset of local header
//   46  ...  name, then extra fields, then comment

import Foundation

struct ZIPCentralDirectoryRecord {

    /// What one attempt to read a record at a given offset produced.
    ///
    /// `endOfDirectory` and `malformed` have to be distinguishable: the first is the
    /// ordinary way the walk stops, the second means the listing the user is looking at is
    /// incomplete and the header line has to say so.
    enum Outcome {
        case record(ZIPCentralDirectoryRecord)
        case endOfDirectory
        case malformed
    }

    /// Total bytes this record occupies, so the caller can step to the next one.
    let recordLength: Int

    /// The member's in-archive path, already sanitised for display.
    let path: String

    /// The archive's own claim about the size before compression, widened from the ZIP64
    /// extra field when the 32-bit field was a sentinel.
    let uncompressedSize: UInt64

    let isDirectory: Bool
    let isEncrypted: Bool

    private static let signature: UInt32 = 0x0201_4b50
    private static let fixedLength = 46
    private static let sentinel32: UInt32 = 0xFFFF_FFFF
    private static let encryptedFlag: UInt16 = 0x0001
    private static let utf8NameFlag: UInt16 = 0x0800
    private static let zip64ExtraFieldID: UInt16 = 0x0001

    /// Host systems whose external attributes carry the MS-DOS attribute byte in their low
    /// eight bits: FAT, OS/2 HPFS, NTFS and VFAT.
    private static let dosAttributeHosts: Set<UInt16> = [0, 6, 11, 14]

    /// Host systems whose external attributes carry a Unix `st_mode` in their high sixteen.
    private static let unixModeHosts: Set<UInt16> = [3, 19]

    /// Read the record at `offset`, or say why not.
    ///
    /// Every field goes through a bounds-checked accessor, so a length that runs past the
    /// end of the buffer yields `.malformed` rather than an out-of-range index. Nothing is
    /// trusted here: not the name length, not the extra length, not the sizes.
    static func parse(in buffer: ByteBuffer, at offset: Int) -> Outcome {
        guard buffer.u32(at: offset) == signature else { return .endOfDirectory }

        guard let versionMadeBy = buffer.u16(at: offset + 4),
              let flags = buffer.u16(at: offset + 8),
              let uncompressedSize32 = buffer.u32(at: offset + 24),
              let nameLength = buffer.u16(at: offset + 28),
              let extraLength = buffer.u16(at: offset + 30),
              let commentLength = buffer.u16(at: offset + 32),
              let externalAttributes = buffer.u32(at: offset + 38),
              let nameBytes = buffer.slice(at: offset + fixedLength, length: Int(nameLength))
        else {
            return .malformed
        }

        var size = UInt64(uncompressedSize32)
        if uncompressedSize32 == sentinel32 {
            let extraOffset = offset + fixedLength + Int(nameLength)
            size = zip64UncompressedSize(in: buffer, at: extraOffset, length: Int(extraLength))
                ?? size
        }

        let name = ArchiveText.decodeZIPName(nameBytes, declaresUTF8: flags & utf8NameFlag != 0)

        // Every addend is a 16-bit field or a 46-byte constant, so this cannot overflow Int.
        let length = fixedLength + Int(nameLength) + Int(extraLength) + Int(commentLength)

        return .record(
            Self(
                recordLength: length,
                path: ArchiveText.sanitizedForDisplay(name),
                uncompressedSize: size,
                isDirectory: isDirectoryEntry(
                    name: name,
                    versionMadeBy: versionMadeBy,
                    externalAttributes: externalAttributes
                ),
                // Bit 0 is the classic password flag. Bit 6, strong encryption, implies it,
                // so testing bit 0 alone is enough.
                isEncrypted: flags & encryptedFlag != 0
            )
        )
    }

    /// Pull the widened uncompressed size out of the ZIP64 extended information extra field.
    ///
    /// The field is positional, not tagged: it holds only the values that were sentinels in
    /// the fixed record, in the fixed order uncompressed size, compressed size, local
    /// header offset, disk number. Uncompressed size is first when it is present at all,
    /// which is why the caller only asks for this when that field was the sentinel - asking
    /// otherwise would read a compressed size and report it as the real one.
    private static func zip64UncompressedSize(
        in buffer: ByteBuffer,
        at offset: Int,
        length: Int
    ) -> UInt64? {
        guard length >= 0, buffer.slice(at: offset, length: length) != nil else { return nil }

        // Extra fields are a sequence of (u16 id, u16 size, size bytes). Walk them rather
        // than assuming ZIP64 comes first, because it frequently does not.
        var cursor = offset
        let end = offset + length
        while cursor + 4 <= end {
            guard let headerID = buffer.u16(at: cursor),
                  let dataSize = buffer.u16(at: cursor + 2)
            else {
                return nil
            }
            let dataStart = cursor + 4
            let dataEnd = dataStart + Int(dataSize)
            guard dataEnd <= end else { return nil }

            if headerID == zip64ExtraFieldID {
                guard dataSize >= 8 else { return nil }
                return buffer.u64(at: dataStart)
            }
            cursor = dataEnd
        }
        return nil
    }

    /// Three independent ways a ZIP marks a directory, because three different families of
    /// tool write them and no single test catches all three.
    private static func isDirectoryEntry(
        name: String,
        versionMadeBy: UInt16,
        externalAttributes: UInt32
    ) -> Bool {
        if name.hasSuffix("/") || name.hasSuffix("\\") { return true }

        let hostSystem = versionMadeBy >> 8
        // 0x10 is FILE_ATTRIBUTE_DIRECTORY in the DOS attribute byte.
        if dosAttributeHosts.contains(hostSystem), externalAttributes & 0x10 != 0 {
            return true
        }
        // S_IFDIR is 0o040000 in the top half of a Unix st_mode.
        if unixModeHosts.contains(hostSystem), (externalAttributes >> 16) & 0xF000 == 0x4000 {
            return true
        }
        return false
    }
}
