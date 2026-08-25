// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Testing
@testable import ArchiveCore

@Suite("ProgressParser")
struct ProgressParserTests {
    @Test("A full progress row decodes every field")
    func fullRow() {
        let row = ProgressParser.parseProgressRow(" 16% 9 + docs/manual.pdf")
        #expect(row?.percent == 16)
        #expect(row?.fileCount == 9)
        #expect(row?.marker == "+")
        #expect(row?.path == "docs/manual.pdf")
    }

    /// Early ticks are frequently bare. Requiring every field would drop them.
    @Test("Degenerate rows still decode")
    func degenerateRows() {
        #expect(ProgressParser.parseProgressRow("  0%")?.percent == 0)
        #expect(ProgressParser.parseProgressRow(" 78%")?.percent == 78)
        let counted = ProgressParser.parseProgressRow(" 99% 12")
        #expect(counted?.percent == 99)
        #expect(counted?.fileCount == 12)
        #expect(counted?.path == nil)
    }

    @Test("A row without a percentage is not progress")
    func notProgress() {
        #expect(ProgressParser.parseProgressRow("Everything is Ok") == nil)
        #expect(ProgressParser.parseProgressRow("") == nil)
    }

    /// The parser keeps the last known value for any field a later tick omits, so
    /// the UI never flickers back to zero mid-operation.
    @Test("Missing fields fall back to the last known value")
    func stickyFields() {
        var parser = ProgressParser(operation: .extract)
        _ = parser.consume(.transient(" 10% 3 - a.txt"))
        guard case .progress(let second) = parser.consume(.transient(" 20%")) else {
            Issue.record("expected progress"); return
        }
        #expect(second.fractionCompleted == 0.2)
        #expect(second.processedItemCount == 3)     // carried forward
        #expect(second.currentItemPath == "a.txt")  // carried forward
    }

    @Test("Member lines become item events with the right action")
    func memberLines() {
        #expect(ProgressParser.parseMemberLine("- docs/manual.pdf")?.0 == .extracted)
        #expect(ProgressParser.parseMemberLine("+ photos/a.heic")?.0 == .added)
        #expect(ProgressParser.parseMemberLine("U notes.txt")?.0 == .updated)
        #expect(ProgressParser.parseMemberLine(". skipped.txt")?.0 == .skipped)
        #expect(ProgressParser.parseMemberLine("T verified.bin")?.0 == .tested)
        #expect(ProgressParser.parseMemberLine("- docs/manual.pdf")?.1 == "docs/manual.pdf")
    }

    /// Separator rows begin with a marker character and must not be mistaken for
    /// members, or every horizontal rule in the output becomes a phantom file.
    @Test("Separator rows are not members")
    func separatorsAreNotMembers() {
        #expect(ProgressParser.parseMemberLine("----------") == nil)
        #expect(ProgressParser.parseMemberLine("--") == nil)
        #expect(ProgressParser.parseMemberLine("-") == nil)
        #expect(ProgressParser.parseMemberLine("-  leading space") == nil)
        #expect(ProgressParser.parseMemberLine("Scanning the drive") == nil)
    }

    @Test("Diagnostic lines become warnings")
    func warnings() {
        var parser = ProgressParser(operation: .compress)
        guard case .warning(let opened) = parser.consume(.line("WARNING: Cannot open file: locked.db")) else {
            Issue.record("expected a warning"); return
        }
        #expect(opened.message.contains("locked.db"))

        var scanner = ProgressParser(operation: .compress)
        guard case .warning(let scanned) = scanner.consume(.line("Cannot open file 'missing.txt'")) else {
            Issue.record("expected a scan warning"); return
        }
        #expect(scanned.kind == .scan)
    }

    @Test("Ordinary output is passed through as log")
    func logPassthrough() {
        var parser = ProgressParser(operation: .test)
        guard case .log(let line) = parser.consume(.line("Everything is Ok")) else {
            Issue.record("expected a log line"); return
        }
        #expect(line == "Everything is Ok")
    }
}
