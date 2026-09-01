// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
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

@Suite("Compress input paths")
struct CompressInputPathTests {
    /// With no base directory, inputs keep their absolute paths — which is what stores a
    /// member at its full path, and is the historical behaviour.
    @Test("Absolute paths are used when there is no base directory")
    func noBaseDirectory() {
        let request = CompressRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z"),
            inputs: [URL(fileURLWithPath: "/tmp/src/readme.md")],
            format: .sevenZip
        )
        #expect(SevenZipCLIEngine.inputArguments(for: request) == ["/tmp/src/readme.md"])
    }

    /// A base directory is how a member gets placed at `docs/img/logo.png` rather than
    /// at its absolute path. Both halves are required: the working directory AND the
    /// relative argument.
    @Test("Inputs are relativised against the base directory")
    func relativised() {
        var request = CompressRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z"),
            inputs: [
                URL(fileURLWithPath: "/tmp/stage/docs/img/logo.png"),
                URL(fileURLWithPath: "/tmp/stage/readme.md"),
            ],
            format: .sevenZip
        )
        request.baseDirectory = URL(fileURLWithPath: "/tmp/stage")
        #expect(SevenZipCLIEngine.inputArguments(for: request)
                == ["docs/img/logo.png", "readme.md"])
    }

    /// An input outside the base directory cannot be expressed relatively. It keeps its
    /// absolute path rather than becoming a `../..` chain that would store a nonsense
    /// member name.
    @Test("An input outside the base directory keeps its absolute path")
    func outsideBase() {
        var request = CompressRequest(
            archiveURL: URL(fileURLWithPath: "/tmp/a.7z"),
            inputs: [URL(fileURLWithPath: "/elsewhere/other.txt")],
            format: .sevenZip
        )
        request.baseDirectory = URL(fileURLWithPath: "/tmp/stage")
        #expect(SevenZipCLIEngine.inputArguments(for: request) == ["/elsewhere/other.txt"])
    }
}
