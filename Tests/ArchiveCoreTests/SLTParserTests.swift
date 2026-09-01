// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore

@Suite("SLTParser")
struct SLTParserTests {
    private let url = URL(fileURLWithPath: "/tmp/sample.7z")
    private var parser: SLTParser { SLTParser(archiveURL: url, timeZone: .gmt) }

    // The engine's own banner line, verbatim from `7zz l -slt`. This is captured
    // stdout that the parser must skip, not upstream source code pasted into the
    // repo, so the rule guarding against the latter does not apply here.
    // swiftlint:disable:next no_upstream_archiver_source
    private static let banner = "7-Zip (z) 26.02 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-06-25"

    /// A realistic transcript: banner, scan summary, `--` archive bag,
    /// `----------` entries separator, then blank-line-delimited entry bags.
    private let transcript = """
    \(Self.banner)

    Scanning the drive for archives:
    1 file, 4096 bytes (4 KiB)

    Listing archive: /tmp/sample.7z

    --
    Path = /tmp/sample.7z
    Type = 7z
    Physical Size = 4096
    Headers Size = 210
    Solid = +
    Blocks = 1

    ----------
    Path = notes.txt
    Size = 1024
    Packed Size = 512
    Modified = 2026-08-24 17:00:00
    Attributes = A_ -rw-r--r--
    CRC = 1A2B3C4D
    Encrypted = +
    Method = LZMA2:12 7zAES
    Block = 0

    Path = docs
    Size = 0
    Folder = +
    Attributes = D_ drwxr-xr-x

    """

    @Test("The archive bag and the entry bags are kept separate")
    func separatesArchiveFromEntries() {
        let listing = parser.parse(transcript)
        // The `--` bag describes the archive; it must not become an entry.
        #expect(listing.entries.count == 2)
        #expect(listing.physicalSize == 4096)
        #expect(listing.headersSize == 210)
        #expect(listing.isSolid)
        #expect(listing.blockCount == 1)
        #expect(listing.format == ArchiveFormat(rawValue: "7z"))
    }

    @Test("Entry properties are decoded")
    func decodesEntries() {
        let listing = parser.parse(transcript)
        guard let notes = listing.entry(atPath: "notes.txt") else {
            Issue.record("notes.txt missing"); return
        }
        #expect(notes.size == 1024)
        #expect(notes.packedSize == 512)
        #expect(notes.crc == 0x1A2B_3C4D)
        #expect(notes.isEncrypted)
        #expect(notes.isDirectory == false)

        guard let docs = listing.entry(atPath: "docs") else {
            Issue.record("docs missing"); return
        }
        #expect(docs.isDirectory)
    }

    /// Splitting on the first `" = "` rather than on `"="` or the last occurrence.
    /// Real paths contain both, and getting this wrong silently corrupts filenames.
    @Test("A value containing ' = ' survives intact")
    func valueContainingAssignment() throws {
        let (key, value) = try #require(SLTParser.splitAssignment("Path = weird = name.txt"))
        #expect(key == PropID.path)
        #expect(value == "weird = name.txt")
    }

    @Test("An empty value is preserved rather than dropped")
    func emptyValue() throws {
        let (key, value) = try #require(SLTParser.splitAssignment("Comment = "))
        #expect(key == PropID.comment)
        #expect(value.isEmpty)
    }

    @Test("A line that is not an assignment is rejected")
    func notAnAssignment() {
        #expect(SLTParser.splitAssignment("----------") == nil)
        #expect(SLTParser.splitAssignment("") == nil)
        #expect(SLTParser.splitAssignment(" = orphan") == nil)
    }

    @Test("A property block with no Path becomes a warning, not a crash")
    func pathlessBlockWarns() {
        let text = """
        ----------
        Size = 10

        Path = real.txt
        Size = 20

        """
        let listing = parser.parse(text)
        #expect(listing.entries.count == 1)
        #expect(listing.warnings.contains { $0.kind == .malformedOutput })
    }

    @Test("An unrecognised property still round-trips into the column model")
    func unknownPropertySurvives() {
        let text = """
        ----------
        Path = thing.bin
        Some Exotic Property = 42

        """
        let listing = parser.parse(text)
        #expect(listing.entries.first?.properties[PropID(rawValue: "Some Exotic Property")] == "42")
    }

    @Test("Trailing carriage returns are stripped")
    func stripsCarriageReturns() {
        let text = "----------\r\nPath = crlf.txt\r\nSize = 5\r\n\r\n"
        let listing = parser.parse(text)
        #expect(listing.entries.first?.path == "crlf.txt")
        #expect(listing.entries.first?.size == 5)
    }
}
