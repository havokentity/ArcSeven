// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

@Suite("SortEngine")
struct SortEngineTests {

    private func file(_ name: String, size: UInt64? = nil, modified: Date? = nil) -> FolderItem {
        var entry = ArchiveEntry(path: name, isDirectory: false)
        entry.size = size
        entry.modified = modified
        var properties: [PropID: String] = [:]
        if let size { properties[.size] = String(size) }
        return FolderItem(
            path: name, name: name, isNavigable: false, isDirectory: false,
            properties: properties, entry: entry
        )
    }

    private func folder(_ name: String) -> FolderItem {
        FolderItem(
            path: name, name: name, isNavigable: true, isDirectory: true,
            entry: ArchiveEntry(path: name, isDirectory: true)
        )
    }

    private var parentRow: FolderItem {
        FolderItem(path: "..", name: "..", isNavigable: true, isDirectory: true)
    }

    @Test("Names sort naturally, so file2 precedes file10")
    func naturalOrder() {
        let items = [file("file10.txt"), file("file2.txt"), file("file1.txt")]
        let sorted = SortEngine.sort(items, by: SortDescriptor(column: .name))
        #expect(sorted.map(\.name) == ["file1.txt", "file2.txt", "file10.txt"])
    }

    @Test("Name sorting ignores case")
    func caseInsensitive() {
        let items = [file("Zebra.txt"), file("apple.txt"), file("Mango.txt")]
        let sorted = SortEngine.sort(items, by: SortDescriptor(column: .name))
        #expect(sorted.map(\.name) == ["apple.txt", "Mango.txt", "Zebra.txt"])
    }

    /// The rule most reimplementations get wrong: reversing the sort reverses the
    /// order *within* each group, it does not put files above folders.
    @Test("Folders stay above files in BOTH directions")
    func foldersAlwaysFirst() {
        let items = [file("a.txt"), folder("zzz"), file("b.txt"), folder("aaa")]

        let ascending = SortEngine.sort(items, by: SortDescriptor(column: .name, direction: .ascending))
        #expect(ascending.map(\.name) == ["aaa", "zzz", "a.txt", "b.txt"])

        let descending = SortEngine.sort(items, by: SortDescriptor(column: .name, direction: .descending))
        #expect(descending.map(\.name) == ["zzz", "aaa", "b.txt", "a.txt"])
        let topTwoAreFolders = descending.prefix(2).filter(\.isDirectory).count == 2
        #expect(topTwoAreFolders, "folders must remain first when reversed")
    }

    @Test("The .. row is always first, in both directions")
    func parentRowPinned() {
        let items = [file("a.txt"), folder("dir")]
        for direction in [SortDirection.ascending, .descending] {
            let sorted = SortEngine.sort(
                items,
                by: SortDescriptor(column: .name, direction: direction),
                parentItem: parentRow
            )
            #expect(sorted.first?.name == "..", "direction \(direction)")
        }
    }

    @Test("Sizes sort numerically, not as text")
    func numericSize() {
        let items = [file("a", size: 9), file("b", size: 100), file("c", size: 20)]
        let sorted = SortEngine.sort(items, by: SortDescriptor(column: .size))
        #expect(sorted.map(\.name) == ["a", "c", "b"])
    }

    /// A directory has no size. Treating that as zero would clump every folder at one
    /// end of a size sort and read as a bug.
    @Test("Missing values sort last ascending, not as zero")
    func missingValuesSortLast() {
        let items = [file("has", size: 5), file("none")]
        let ascending = SortEngine.sort(items, by: SortDescriptor(column: .size))
        #expect(ascending.map(\.name) == ["has", "none"])
    }

    @Test("Dates sort chronologically")
    func dateOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            file("new", modified: now),
            file("old", modified: now.addingTimeInterval(-86_400)),
            file("mid", modified: now.addingTimeInterval(-3_600)),
        ]
        let sorted = SortEngine.sort(items, by: SortDescriptor(column: .modified))
        #expect(sorted.map(\.name) == ["old", "mid", "new"])
    }

    /// Equal keys must not shuffle, or re-sorting a column reorders rows that
    /// look identical to the user.
    @Test("Ties break deterministically on name")
    func stableTiebreak() {
        let items = [file("c", size: 10), file("a", size: 10), file("b", size: 10)]
        let first = SortEngine.sort(items, by: SortDescriptor(column: .size))
        let second = SortEngine.sort(items.reversed(), by: SortDescriptor(column: .size))
        #expect(first.map(\.name) == ["a", "b", "c"])
        #expect(first.map(\.name) == second.map(\.name), "sort must not depend on input order")
    }

    @Test("An empty listing sorts without crashing")
    func empty() {
        #expect(SortEngine.sort([], by: SortDescriptor()).isEmpty)
        #expect(SortEngine.sort([], by: SortDescriptor(), parentItem: parentRow).map(\.name) == [".."])
    }
}
