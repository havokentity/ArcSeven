// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// End-to-end navigation against a REAL archive built by the vendored 7zz.
//
// The unit tests in ArchiveTreeTests drive `children(of:in:)` with synthetic listings.
// These build an actual .7z on disk, list it through the real engine, and walk the
// provider tree the way the panel does — which is the only way to catch a mismatch
// between what `7zz -slt` emits and what the tree builder expects.
//
// Skips itself when vendor/bin/7zz has not been built, so a bare checkout still passes.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

func vendored7zzForNavigation() -> URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    return dir.appendingPathComponent("vendor/bin/7zz")
}

/// Whether that binary has actually been built. The suite skips itself when it has not,
/// so `vendored7zzForNavigation()` is only ever run against a real executable.
func vendored7zzForNavigationIsBuilt() -> Bool {
    FileManager.default.isExecutableFile(atPath: vendored7zzForNavigation().path)
}

@Suite("Live archive navigation", .enabled(if: vendored7zzForNavigationIsBuilt()))
struct LiveNavigationTests {
    private var engine: SevenZipCLIEngine {
        SevenZipCLIEngine(executableURL: vendored7zzForNavigation(), timeZone: .gmt)
    }

    /// Build a nested archive and hand back its URL plus a cleanup closure.
    private func withDemoArchive<T>(_ body: (URL) async throws -> T) async throws -> T {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-nav-" + UUID().uuidString)
        let source = root.appendingPathComponent("src")
        let manager = FileManager.default
        try manager.createDirectory(at: source.appendingPathComponent("docs/img"), withIntermediateDirectories: true)
        try manager.createDirectory(at: source.appendingPathComponent("code"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        try "readme".write(to: source.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
        try "manual".write(to: source.appendingPathComponent("docs/manual.txt"), atomically: true, encoding: .utf8)
        try "logo".write(to: source.appendingPathComponent("docs/img/logo.png"), atomically: true, encoding: .utf8)
        // Deliberately unsorted and numeric, to exercise natural ordering.
        for name in ["file1", "file10", "file2", "file20", "file3"] {
            try "x".write(to: source.appendingPathComponent("code/\(name).swift"), atomically: true, encoding: .utf8)
        }

        let archive = root.appendingPathComponent("demo.7z")
        var request = CompressRequest(
            archiveURL: archive,
            inputs: try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil),
            format: .sevenZip
        )
        request.pathMode = .relative
        for try await _ in engine.compress(request) {}
        return try await body(archive)
    }

    @Test("The panel's provider tree matches the real archive at every level")
    func walkTheTree() async throws {
        try await withDemoArchive { archive in
            let root = try await ArchiveFolderProvider.open(archiveURL: archive, engine: engine)

            // Level 0
            let top = try await root.loadChildren()
            #expect(Set(top.map(\.name)) == ["code", "docs", "readme.md"])
            #expect(top.first { $0.name == "code" }?.isDirectory == true)
            #expect(top.first { $0.name == "readme.md" }?.isDirectory == false)

            // Descend into code/ exactly as PanelViewController.open(rowAt:) does.
            let codeItem = try #require(top.first { $0.name == "code" })
            let code = try #require(try await root.child(at: codeItem))
            let codeChildren = try await code.loadChildren()
            #expect(codeChildren.count == 5)

            // Natural ordering: file2 before file10, file10 before file20.
            let sorted = SortEngine.sort(codeChildren, by: SortDescriptor(column: .name))
            #expect(sorted.map(\.name) == [
                "file1.swift", "file2.swift", "file3.swift", "file10.swift", "file20.swift",
            ])

            // Two levels deep.
            let docsItem = try #require(top.first { $0.name == "docs" })
            let docs = try #require(try await root.child(at: docsItem))
            let docsChildren = try await docs.loadChildren()
            #expect(Set(docsChildren.map(\.name)) == ["manual.txt", "img"])

            let imgItem = try #require(docsChildren.first { $0.name == "img" })
            let img = try #require(try await docs.child(at: imgItem))
            #expect(try await img.loadChildren().map(\.name) == ["logo.png"])

            // Ascending returns to the parent level.
            let backToDocs = try #require(try await img.parent())
            #expect(Set(try await backToDocs.loadChildren().map(\.name)) == ["manual.txt", "img"])

            // Ascending from the archive root leaves the archive for the filesystem.
            let outside = try #require(try await root.parent())
            #expect(outside.kind == .fileSystem)
        }
    }

    @Test("Archive levels advertise archive columns, disk levels do not")
    func columnsDifferByLevel() async throws {
        try await withDemoArchive { archive in
            let root = try await ArchiveFolderProvider.open(archiveURL: archive, engine: engine)
            let archiveColumns = root.availableColumns
            #expect(archiveColumns.contains(.name))
            #expect(archiveColumns.contains(.size))
            // A .7z reports packed size and CRC; this is what makes the panel's column
            // set differ from a disk folder's.
            #expect(archiveColumns.contains(.packedSize))
            #expect(archiveColumns.contains(.crc))

            let disk = FileSystemFolderProvider(
                directoryURL: archive.deletingLastPathComponent(),
                engine: engine
            )
            #expect(disk.availableColumns.contains(.packedSize) == false)
            #expect(disk.availableColumns.contains(.crc) == false)
        }
    }

    @Test("A directory reports no size, so panels render it blank")
    func directoriesHaveNoSize() async throws {
        try await withDemoArchive { archive in
            let root = try await ArchiveFolderProvider.open(archiveURL: archive, engine: engine)
            let top = try await root.loadChildren()
            let code = try #require(top.first { $0.name == "code" })
            #expect(code.numericValue(for: .size) == nil)
            #expect(code.numericValue(for: .packedSize) == nil)
            #expect(ColumnModel.displayText(for: code, column: .size).isEmpty)
            #expect(ColumnModel.displayText(for: code, column: .packedSize).isEmpty)
        }
    }
}
