// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Sniff the container, pick a reader, and hand back something drawable.
//
// This is the only entry point the view controller calls, and it never throws: every
// failure that can happen below is turned into an `ArchiveDirectory` whose body is a
// sentence. See ArchiveDirectory.swift for why that is the right shape.
//
// The format is decided by MAGIC BYTES, not by the path extension. Quick Look picks this
// extension by UTI, and a UTI on macOS is very often inferred from an extension the user
// or the sender chose; trusting it would mean running the ZIP parser over whatever a
// file named `.zip` happens to contain. Sniffing costs one 262-byte read.

import Foundation

enum ArchiveDirectoryReader {

    /// Parse an archive's directory.
    ///
    /// `async` and free of any actor: a `nonisolated` async function does NOT inherit its
    /// caller's executor (SE-0338), so calling this from the main-actor-isolated
    /// `preparePreviewOfFile(at:)` genuinely moves the parse onto the concurrent pool and
    /// leaves the main thread free to keep the preview responsive. That is load-bearing,
    /// not incidental - marking this `@MainActor`, or making it synchronous, would block
    /// the Finder's preview panel for the duration of the read.
    static func read(fileAt url: URL) async -> ArchiveDirectory {
        let displayName = ArchiveText.sanitizedForDisplay(url.lastPathComponent)

        let reader: BoundedFileReader
        do {
            reader = try BoundedFileReader(url: url)
        } catch {
            return .failed(
                displayName: displayName,
                archiveByteSize: 0,
                format: .other(name: "Archive"),
                message: (error as? ArchiveReadError)?.message
                    ?? "This file could not be opened for reading."
            )
        }
        // Closed before we return, so the preview is never drawn while a descriptor is
        // still open on the file - QLPreviewingController's documentation asks for exactly
        // this, and an appex holding a descriptor open blocks the volume from ejecting.
        defer { reader.close() }

        do {
            switch try sniff(reader) {
            case .sevenZip:
                return try SevenZipSignatureReader.read(reader, displayName: displayName)

            case .zip:
                return try ZIPDirectoryReader.read(reader, displayName: displayName)

            case .known(let name):
                throw ArchiveReadError.unsupported(
                    "\(name) archives are not previewed here. Open this file in ArcSeven to browse its contents."
                )

            case .candidateForPrefixedZIP:
                // A self-extracting archive begins with an executable stub, and an
                // unrecognised header may still be a ZIP with junk in front of it. The
                // backwards EOCD scan is the authoritative test either way, so run it and
                // only give up if it finds nothing.
                return try ZIPDirectoryReader.read(reader, displayName: displayName)
            }
        } catch {
            let message = (error as? ArchiveReadError)?.message
                ?? "This archive could not be read."
            return .failed(
                displayName: displayName,
                archiveByteSize: reader.byteSize,
                format: .other(name: "Archive"),
                message: message
            )
        }
    }

    // MARK: - Sniffing

    private enum Sniffed {
        case zip
        case sevenZip
        /// Recognised, but deliberately not parsed by this extension.
        case known(name: String)
        /// An executable stub or something unrecognised - still worth the ZIP end-scan.
        case candidateForPrefixedZIP
    }

    /// The tar magic lives at offset 257, which is why the sniff window is 262 bytes and
    /// not the 8 the other formats need.
    private static let sniffLength = 262

    private static func sniff(_ reader: BoundedFileReader) throws -> Sniffed {
        let length = Int(min(UInt64(sniffLength), reader.byteSize))
        let head = try reader.read(at: 0, length: length)

        func matches(_ signature: [UInt8], at index: Int = 0) -> Bool {
            guard let slice = head.slice(at: index, length: signature.count) else { return false }
            return Array(slice) == signature
        }

        if matches(SevenZipSignatureReader.magic) { return .sevenZip }

        // Local file header, EOCD, or spanning marker: all three legitimately start a ZIP.
        if matches([0x50, 0x4B, 0x03, 0x04])
            || matches([0x50, 0x4B, 0x05, 0x06])
            || matches([0x50, 0x4B, 0x07, 0x08]) {
            return .zip
        }

        if matches([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .known(name: "RAR") }
        if matches([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .known(name: "XZ") }
        if matches([0x1F, 0x8B]) { return .known(name: "Gzip") }
        if matches([0x42, 0x5A, 0x68]) { return .known(name: "Bzip2") }
        if matches([0x28, 0xB5, 0x2F, 0xFD]) { return .known(name: "Zstandard") }
        if matches([0x4D, 0x53, 0x43, 0x46]) { return .known(name: "Cabinet") }
        // "ustar" at 257 - the POSIX tar magic. GNU tar writes "ustar  \0", POSIX writes
        // "ustar\0" followed by a version, so only the five letters are compared.
        if matches([0x75, 0x73, 0x74, 0x61, 0x72], at: 257) { return .known(name: "Tar") }

        return .candidateForPrefixedZIP
    }
}
