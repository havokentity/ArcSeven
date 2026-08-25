// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Testing
@testable import ArchiveCore

@Suite("Test-operation member lines")
struct TestMarkerTests {
    /// `7zz t -bb3` emits one `T <path>` line per member, INCLUDING directory entries
    /// whose paths end in "/". Every one of them must be counted, or the "N items
    /// verified" figure the user sees is wrong.
    @Test("Every T line becomes an item event")
    func countsAllTestedMembers() {
        let lines = [
            "T code/", "T docs/", "T docs/img/",
            "T code/big.dat", "T code/file1.swift", "T code/file10.swift",
            "T code/file2.swift", "T code/file20.swift", "T code/file3.swift",
            "T docs/img/logo.png", "T docs/manual.txt", "T readme.md",
        ]
        var tokenizer = StreamTokenizer()
        var tokens = tokenizer.consume(Array((lines.joined(separator: "\n") + "\n").utf8))
        tokens += tokenizer.finish()

        var parser = ProgressParser(operation: .test)
        let outputs = parser.consume(tokens)
        let items = outputs.compactMap { output -> ArchiveItemEvent? in
            if case .item(let event) = output { return event }
            return nil
        }
        #expect(items.count == 12, "expected all 12 members, got \(items.count)")
        #expect(items.allSatisfy { $0.action == .tested })
        #expect(items.contains { $0.path == "code/" })
        #expect(items.contains { $0.path == "readme.md" })
    }
}
