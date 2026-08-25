// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore

@Suite("Selection list file")
struct SelectionListFileTests {
    @Test("No selection means no arguments and no temp file")
    func emptySelection() throws {
        for entries in [nil, []] as [[String]?] {
            let prepared = try SelectionListFile.prepare(entries)
            #expect(prepared.arguments.isEmpty)
            #expect(prepared.switches.isEmpty)
            #expect(prepared.temporaryFiles.isEmpty)
        }
    }

    /// The common case must not pay for the rare one.
    @Test("A small selection stays on argv")
    func smallSelectionUsesArgv() throws {
        let entries = ["a.txt", "dir/b.txt", "dir/sub/c.txt"]
        let prepared = try SelectionListFile.prepare(entries)
        #expect(prepared.arguments == entries)
        #expect(prepared.switches.isEmpty)
        #expect(prepared.temporaryFiles.isEmpty, "no temp file for a handful of names")
    }

    @Test("A large selection moves to a list file")
    func largeSelectionUsesListFile() throws {
        let entries = (0..<8000).map { "some/reasonably/deep/directory/member-\($0).txt" }
        #expect(entries.reduce(0) { $0 + $1.utf8.count + 1 } > SelectionListFile.threshold)

        let prepared = try SelectionListFile.prepare(entries)
        defer { prepared.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(prepared.switches.count == 1)
        // `-i@`, not a bare `@`: the plain form is not expanded after `--`.
        #expect(prepared.switches[0].hasPrefix("-i@"))
        #expect(prepared.arguments.isEmpty)
        #expect(prepared.temporaryFiles.count == 1)

        let path = String(prepared.switches[0].dropFirst(3))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        let lines = written.split(separator: "\n").map(String.init)
        #expect(lines.count == entries.count, "every member must reach the file")
        #expect(lines.first == entries.first)
        #expect(lines.last == entries.last)
    }

    /// A list file is line-delimited, so a member containing a newline cannot be written
    /// into one without changing which file it names.
    @Test("A member containing a newline stays on argv")
    func newlineMemberStaysOnArgv() throws {
        var entries = (0..<8000).map { "padding/directory/member-\($0).txt" }
        entries.append("weird\nname.txt")

        let prepared = try SelectionListFile.prepare(entries)
        defer { prepared.temporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(prepared.arguments.contains("weird\nname.txt"),
                "it must be passed literally, not folded into the list file")
        let path = String(prepared.switches[0].dropFirst(3))
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(!written.contains("weird"), "and must not appear in the list file at all")
    }
}
