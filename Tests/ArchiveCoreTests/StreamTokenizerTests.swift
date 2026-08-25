// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The tokenizer is the highest-risk component in the CLI engine: `7zz` paints
// progress by erasing in place with BACKSPACES rather than by emitting carriage
// returns, so a naive line reader either sees nothing at all or accumulates one
// enormous line. These tests pin that behaviour down.

import Foundation
import Testing
@testable import ArchiveCore

@Suite("StreamTokenizer")
struct StreamTokenizerTests {
    private func tokens(_ string: String) -> [StreamTokenizer.Token] {
        var tokenizer = StreamTokenizer()
        var out = tokenizer.consume(Array(string.utf8))
        out.append(contentsOf: tokenizer.finish())
        return out
    }

    @Test("Newline-terminated rows become permanent lines")
    func plainLines() {
        let result = tokens("first\nsecond\n")
        #expect(result == [.line("first"), .line("second")])
    }

    /// Leading and trailing spaces are significant: a filename may legitimately
    /// begin or end with one, and trimming here would corrupt it.
    @Test("Line content is preserved verbatim")
    func preservesSpacing() {
        let result = tokens("  spaced name  \n")
        #expect(result == [.line("  spaced name  ")])
    }

    /// The core case. `7zz` writes a progress row, then backspaces over it and
    /// writes the next one. The row must be captured at the moment it is erased.
    @Test("A backspace-erased row is captured as transient")
    func backspaceErasure() {
        // " 10%" then four backspaces then " 20%" then a newline.
        let raw = " 10%" + String(repeating: "\u{08}", count: 4) + " 20%\n"
        let result = tokens(raw)
        #expect(result.contains(.transient(" 10%")))
        #expect(result.contains(.line(" 20%")))
    }

    @Test("Successive erased rows each produce a transient")
    func repeatedErasure() {
        var raw = ""
        for percent in ["  0%", " 25%", " 50%", " 75%"] {
            raw += percent + String(repeating: "\u{08}", count: percent.count)
        }
        raw += "100%\n"
        let result = tokens(raw)
        let transients = result.filter { !$0.isLine }.map(\.text)
        #expect(transients.contains("  0%"))
        #expect(transients.contains(" 25%"))
        #expect(transients.contains(" 50%"))
        #expect(transients.contains(" 75%"))
        #expect(result.last == .line("100%"))
    }

    /// The reader gets arbitrary 64 KiB chunks from a pipe; a row can be cut
    /// anywhere, including through a multi-byte UTF-8 scalar.
    @Test("A row split across reads is reassembled")
    func splitAcrossReads() {
        var tokenizer = StreamTokenizer()
        var result = tokenizer.consume(Array("par".utf8))
        result += tokenizer.consume(Array("tial\n".utf8))
        result += tokenizer.finish()
        #expect(result == [.line("partial")])
    }

    @Test("A multi-byte scalar split across reads survives")
    func splitScalar() {
        let bytes = Array("café ✓\n".utf8)
        // Cut inside the é (2 bytes) and again inside the ✓ (3 bytes).
        for cut in 1..<bytes.count {
            var tokenizer = StreamTokenizer()
            var result = tokenizer.consume(bytes[..<cut])
            result += tokenizer.consume(bytes[cut...])
            result += tokenizer.finish()
            #expect(result == [.line("café ✓")], "cut at \(cut)")
        }
    }

    @Test("Unterminated trailing content is flushed by finish()")
    func flushesTail() {
        var tokenizer = StreamTokenizer()
        var result = tokenizer.consume(Array("no newline".utf8))
        #expect(result.isEmpty)
        result += tokenizer.finish()
        #expect(result.map(\.text) == ["no newline"])
    }

    @Test("Carriage returns also delimit a row")
    func carriageReturn() {
        let result = tokens("alpha\rbeta\n")
        #expect(result.map(\.text).contains("alpha"))
        #expect(result.contains(.line("beta")))
    }

    /// The erase pattern blanks a row with spaces before rewriting it. Emitting a
    /// transient for each of those would be one useless event per progress tick.
    @Test("Blank transients are suppressed by default")
    func suppressesBlankTransients() {
        let raw = "    " + String(repeating: "\u{08}", count: 4) + "done\n"
        let result = tokens(raw)
        #expect(!result.contains { !$0.isLine && $0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(result.contains(.line("done")))
    }

    @Test("Empty input produces nothing")
    func empty() {
        #expect(tokens("").isEmpty)
    }
}
