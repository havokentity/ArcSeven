// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Bounded, bounds-checked byte reading for the Quick Look preview.
//
// Everything in this extension parses untrusted input. A Quick Look appex is spawned by
// quicklookd for any file the user hovers over, including one that just arrived over the
// network, and it is sandboxed and memory-capped: a crash is a visible failure and a hang
// blocks the Finder's preview panel. So the two primitives here are deliberately
// paranoid rather than convenient:
//
//   * every accessor returns an Optional instead of trapping, so a truncated or lying
//     length field produces `nil` and a caller-side `guard`, never an index-out-of-range;
//   * the file reader carries a byte budget, so no length field found inside the file can
//     ever make us allocate more than a fixed ceiling regardless of what it claims.
//
// There is no `Data` anywhere below the I/O boundary. That is not taste. A `Data` obtained
// by slicing another `Data` keeps the PARENT's indices, so `slice[0]` traps on a slice that
// does not start at zero - the single most common way a binary parser written against Data
// reads the wrong bytes or dies on a file that is merely unusual. `[UInt8]` copied out of
// the read always starts at 0.

import Foundation

/// Hard ceilings. Every one of these exists to bound work on a hostile file, not to bound
/// work on a plausible one; the numbers are far above anything a real archive needs.
enum PreviewLimits {
    /// Rows handed to the table view. A preview is a glance, not a file manager, and
    /// building 200k cell views inside an appex is how you get killed for memory.
    static let maxRenderedEntries = 4000

    /// Central-directory records we will walk at all, counted but not necessarily shown.
    /// Bounds the loop itself so a self-referential or absurdly long directory terminates.
    static let maxWalkedEntries = 200_000

    /// Ceiling on the central directory slurp, and the number that actually governs peak
    /// memory: the directory is read in one piece, and reading it costs that many bytes
    /// twice for a moment while the `Data` is copied into its array.
    ///
    /// 16 MB is chosen so the *walk* cap above is the binding constraint rather than this
    /// one: a central directory record is at least 46 bytes, so 200k of them cannot exceed
    /// ~9 MB, and anything past 16 MB is directory we would refuse to walk anyway.
    static let maxCentralDirectoryBytes = 16 << 20

    /// Total bytes this process will read from the archive, across all reads. Roughly the
    /// directory ceiling plus room for the tail scan and the format sniff.
    static let maxTotalBytesRead = 20 << 20

    /// How far back from EOF we look for the End of Central Directory record. The record
    /// is 22 bytes plus a comment of up to 65535, so 65557 is the true worst case; the
    /// window is rounded up so a prefixed or slightly padded file still resolves.
    static let endOfCentralDirectoryWindow = 66_560

    /// Longest member path we will render. A ZIP name field is 16-bit, so a legal name can
    /// be 64 KB of text; that is a layout attack, not a filename.
    static let maxRenderedPathLength = 512
}

/// Why a preview could not be produced. Carries a human sentence, because every one of
/// these ends up on screen rather than in a log.
enum ArchiveReadError: Error {
    /// The file could not be opened or read at all.
    case unreadable(String)

    /// The bytes are structurally wrong for the format they claim to be.
    case malformed(String)

    /// The format was recognised, but this extension does not parse it.
    case unsupported(String)

    var message: String {
        switch self {
        case .unreadable(let text), .malformed(let text), .unsupported(let text):
            return text
        }
    }
}

/// A read-only window over a byte range, little-endian, with every accessor range-checked.
///
/// All integer accessors return `nil` rather than trapping when the requested field does
/// not fit. That turns "the file lied about a length" from a crash into a `guard`.
struct ByteBuffer {
    /// The bytes, always zero-based. See the file comment for why this is not `Data`.
    let bytes: [UInt8]

    /// Offset within the source file of `bytes[0]`, so a caller can translate an index in
    /// this window back into an absolute file offset.
    let fileOffset: UInt64

    var count: Int { bytes.count }

    init(bytes: [UInt8], fileOffset: UInt64) {
        self.bytes = bytes
        self.fileOffset = fileOffset
    }

    func u8(at index: Int) -> UInt8? {
        guard index >= 0, index < bytes.count else { return nil }
        return bytes[index]
    }

    func u16(at index: Int) -> UInt16? {
        guard let low = u8(at: index), let high = u8(at: index + 1) else { return nil }
        return UInt16(low) | (UInt16(high) << 8)
    }

    func u32(at index: Int) -> UInt32? {
        guard let low = u16(at: index), let high = u16(at: index + 2) else { return nil }
        return UInt32(low) | (UInt32(high) << 16)
    }

    func u64(at index: Int) -> UInt64? {
        guard let low = u32(at: index), let high = u32(at: index + 4) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    /// `length` bytes starting at `index`, or `nil` if that range is not wholly inside the
    /// window. Written as `index <= count - length` rather than `index + length <= count`
    /// so a hostile `length` near `Int.max` cannot overflow the comparison itself.
    func slice(at index: Int, length: Int) -> ArraySlice<UInt8>? {
        guard length >= 0, index >= 0, length <= bytes.count, index <= bytes.count - length else {
            return nil
        }
        return bytes[index ..< index + length]
    }

    /// Index of the last occurrence of a 32-bit little-endian signature at or before
    /// `upperBound`, scanning backwards.
    ///
    /// Backwards is required, not an optimisation: the ZIP End of Central Directory record
    /// carries a variable-length comment, and that comment is attacker-controlled, so it may
    /// itself contain the EOCD signature. The *last* match is the real record.
    func lastIndex(ofSignature signature: UInt32, notAfter upperBound: Int) -> Int? {
        let byte0 = UInt8(truncatingIfNeeded: signature)
        let byte1 = UInt8(truncatingIfNeeded: signature >> 8)
        let byte2 = UInt8(truncatingIfNeeded: signature >> 16)
        let byte3 = UInt8(truncatingIfNeeded: signature >> 24)

        var index = min(upperBound, bytes.count - 4)
        while index >= 0 {
            if bytes[index] == byte0,
               bytes[index + 1] == byte1,
               bytes[index + 2] == byte2,
               bytes[index + 3] == byte3 {
                return index
            }
            index -= 1
        }
        return nil
    }
}

/// A file opened for reading, with a total-bytes budget.
///
/// Not `Sendable` and not meant to be: one instance is created, used and closed inside a
/// single call to `ArchiveDirectoryReader.read(fileAt:)`, which runs off the main actor.
/// The handle is closed before the preview is rendered, as `QLPreviewingController`'s
/// documentation asks - an appex must not sit on a descriptor for the life of the preview.
final class BoundedFileReader {
    /// The file's size in bytes, established once by seeking to the end. Every subsequent
    /// read is validated against this, so no offset taken from the file's own headers can
    /// send us past EOF.
    let byteSize: UInt64

    private let handle: FileHandle
    private var remainingBudget: Int

    init(url: URL) throws {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            self.handle = handle
            self.byteSize = try handle.seekToEnd()
            self.remainingBudget = PreviewLimits.maxTotalBytesRead
        } catch let error as ArchiveReadError {
            throw error
        } catch {
            throw ArchiveReadError.unreadable("The file could not be opened for reading.")
        }
    }

    func close() {
        try? handle.close()
    }

    /// Exactly `length` bytes at `offset`, or an error. Never a short read presented as a
    /// whole one - a short read means the file was truncated under us, which is a parse
    /// failure and not something to paper over.
    func read(at offset: UInt64, length: Int) throws -> ByteBuffer {
        guard length >= 0 else {
            throw ArchiveReadError.malformed("Negative read length.")
        }
        guard length <= remainingBudget else {
            throw ArchiveReadError.malformed("The archive's directory is larger than this preview will read.")
        }
        // Both halves matter: the offset must be inside the file, and the length must fit
        // in what remains after it. Subtracting rather than adding keeps UInt64 from
        // wrapping on a length field of 0xFFFF_FFFF_FFFF_FFFF.
        guard offset <= byteSize, UInt64(length) <= byteSize - offset else {
            throw ArchiveReadError.malformed("A length in the archive points past the end of the file.")
        }
        guard length > 0 else {
            return ByteBuffer(bytes: [], fileOffset: offset)
        }

        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), data.count == length else {
                throw ArchiveReadError.malformed("The archive ends earlier than its headers claim.")
            }
            remainingBudget -= length
            return ByteBuffer(bytes: [UInt8](data), fileOffset: offset)
        } catch let error as ArchiveReadError {
            throw error
        } catch {
            throw ArchiveReadError.unreadable("The file could not be read.")
        }
    }

    /// The last `maxLength` bytes of the file, or the whole file if it is shorter.
    func readTail(maxLength: Int) throws -> ByteBuffer {
        let length = Int(min(UInt64(max(maxLength, 0)), byteSize))
        return try read(at: byteSize - UInt64(length), length: length)
    }
}
