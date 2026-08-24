// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

@Suite("Archive tree")
struct ArchiveTreeTests {

    /// A listing whose members are files only — no directory entries at all. This is
    /// what `zip -D`, most tars, and naive writers produce, and it is the case that
    /// breaks implementations which assume directories are always present.
    private func listing(_ paths: [String], directories: Set<String> = []) -> ArchiveListing {
        var entries: [ArchiveEntry] = []
        for path in paths {
            var entry = ArchiveEntry(path: path, isDirectory: directories.contains(path))
            entry.size = directories.contains(path) ? nil : 100
            entries.append(entry)
        }
        return ArchiveListing(url: URL(fileURLWithPath: "/tmp/a.7z"), entries: entries)
    }

    @Test("Root level lists top-level files")
    func rootFiles() {
        let items = ArchiveFolderProvider.children(of: "", in: listing(["a.txt", "b.txt"]))
        #expect(Set(items.map(\.name)) == ["a.txt", "b.txt"])
        let noneAreDirectories = items.filter(\.isDirectory).isEmpty
        #expect(noneAreDirectories)
    }

    /// The important one: `docs` has no entry of its own, but must still appear.
    @Test("Directories with no entry of their own are synthesised")
    func synthesisesMissingDirectories() {
        let items = ArchiveFolderProvider.children(
            of: "",
            in: listing(["docs/manual.pdf", "docs/img/logo.png", "readme.md"])
        )
        #expect(Set(items.map(\.name)) == ["docs", "readme.md"])
        let docs = items.first { $0.name == "docs" }
        #expect(docs?.isDirectory == true)
        #expect(docs?.isNavigable == true)
        #expect(docs?.path == "docs")
    }

    @Test("Descending shows only that level's children")
    func descend() {
        let l = listing(["docs/manual.pdf", "docs/img/logo.png", "readme.md"])
        let docs = ArchiveFolderProvider.children(of: "docs", in: l)
        #expect(Set(docs.map(\.name)) == ["manual.pdf", "img"])
        let img = ArchiveFolderProvider.children(of: "docs/img", in: l)
        #expect(img.map(\.name) == ["logo.png"])
        #expect(img.first?.path == "docs/img/logo.png")
    }

    /// A real directory entry and a synthesised one must not both appear.
    @Test("A real directory entry is not duplicated by a synthesised one")
    func noDuplicateDirectories() {
        let l = listing(["docs", "docs/manual.pdf"], directories: ["docs"])
        let items = ArchiveFolderProvider.children(of: "", in: l)
        #expect(items.filter { $0.name == "docs" }.count == 1)
        #expect(items.first { $0.name == "docs" }?.isDirectory == true)
    }

    /// Archives written on Windows store backslashes; a trailing slash marks a
    /// directory in several formats. Both must normalise or the tree fragments.
    @Test("Windows separators and trailing slashes normalise")
    func normalisation() {
        #expect(ArchiveFolderProvider.normalise("docs\\img\\logo.png") == "docs/img/logo.png")
        #expect(ArchiveFolderProvider.normalise("docs/") == "docs")
        #expect(ArchiveFolderProvider.normalise("docs///") == "docs")
        let items = ArchiveFolderProvider.children(
            of: "",
            in: listing(["docs\\manual.pdf"])
        )
        #expect(items.map(\.name) == ["docs"])
    }

    @Test("A prefix that matches no member yields nothing rather than everything")
    func unknownPrefix() {
        let items = ArchiveFolderProvider.children(of: "nope", in: listing(["a.txt"]))
        #expect(items.isEmpty)
    }

    /// `doc` must not match `docs/...`. Prefix comparison has to be separator-aware.
    @Test("A prefix does not match a longer sibling name")
    func prefixIsNotSubstring() {
        let l = listing(["docs/a.txt", "doc/b.txt"])
        let doc = ArchiveFolderProvider.children(of: "doc", in: l)
        #expect(doc.map(\.name) == ["b.txt"])
        let docs = ArchiveFolderProvider.children(of: "docs", in: l)
        #expect(docs.map(\.name) == ["a.txt"])
    }

    @Test("A nested archive member is navigable")
    func nestedArchiveIsNavigable() {
        let items = ArchiveFolderProvider.children(of: "", in: listing(["inner.tar", "plain.txt"]))
        #expect(items.first { $0.name == "inner.tar" }?.isNavigable == true)
        #expect(items.first { $0.name == "plain.txt" }?.isNavigable == false)
    }

    @Test("Deeply nested paths resolve at every level")
    func deepNesting() {
        let l = listing(["a/b/c/d/e.txt"])
        #expect(ArchiveFolderProvider.children(of: "", in: l).map(\.name) == ["a"])
        #expect(ArchiveFolderProvider.children(of: "a", in: l).map(\.name) == ["b"])
        #expect(ArchiveFolderProvider.children(of: "a/b/c", in: l).map(\.name) == ["d"])
        #expect(ArchiveFolderProvider.children(of: "a/b/c/d", in: l).map(\.name) == ["e.txt"])
    }
}
