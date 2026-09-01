// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore

func vendored7zzForLiteralNames() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let candidate = dir.appendingPathComponent("vendor/bin/7zz")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

/// `*` and `?` are legal in an APFS filename, and 7-Zip reads every member name it is given
/// as a wildcard unless told otherwise. Selecting `note*.txt` and pressing Delete destroyed
/// `noteA.txt` and `noteB.txt` as well — exit 0, no warning, no way to tell what went.
@Suite("Literal member names", .enabled(if: vendored7zzForLiteralNames() != nil))
struct LiteralMemberNameTests {
    private var engine: SevenZipCLIEngine {
        SevenZipCLIEngine(
            executableURL: vendored7zzForLiteralNames() ?? URL(fileURLWithPath: "/nonexistent"),
            timeZone: .gmt
        )
    }

    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-literal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Builds an archive holding names that are also glob patterns for their siblings.
    private func makeArchive(in dir: URL) async throws -> URL {
        let stage = dir.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for name in ["note*.txt", "noteA.txt", "noteB.txt", "other.txt"] {
            try Data(name.utf8).write(to: stage.appendingPathComponent(name))
        }
        let archive = dir.appendingPathComponent("a.7z")
        var request = CompressRequest(
            archiveURL: archive,
            inputs: try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil),
            format: .sevenZip
        )
        request.baseDirectory = stage
        for try await _ in engine.compress(request) {}
        return archive
    }

    private func members(of archive: URL) async throws -> Set<String> {
        let listing = try await engine.list(ListRequest(archiveURL: archive))
        return Set(listing.entries.filter { !$0.isDirectory }.map(\.path))
    }

    @Test("Deleting a member whose name is a glob deletes only that member")
    func deleteIsLiteral() async throws {
        try await withScratch { dir in
            let archive = try await makeArchive(in: dir)
            #expect(try await members(of: archive).count == 4)

            let request = DeleteRequest(archiveURL: archive, entryPaths: ["note*.txt"])
            for try await _ in engine.delete(request) {}

            let remaining = try await members(of: archive)
            #expect(remaining == ["noteA.txt", "noteB.txt", "other.txt"],
                    "one member was selected; \(4 - remaining.count) were removed")
        }
    }

    @Test("Extracting a member whose name is a glob extracts only that member")
    func extractIsLiteral() async throws {
        try await withScratch { dir in
            let archive = try await makeArchive(in: dir)
            let destination = dir.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.selectedEntries = ["note*.txt"]
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            let written = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            )
            #expect(written == ["note*.txt"], "a pattern match pulled in unselected members")
        }
    }

    /// `?` matches exactly one character, so it is the sharper probe.
    @Test("A single-character wildcard is also literal")
    func questionMarkIsLiteral() async throws {
        try await withScratch { dir in
            let stage = dir.appendingPathComponent("stage", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            for name in ["report?.pdf", "report1.pdf", "reportX.pdf"] {
                try Data(name.utf8).write(to: stage.appendingPathComponent(name))
            }
            let archive = dir.appendingPathComponent("q.7z")
            var make = CompressRequest(
                archiveURL: archive,
                inputs: try FileManager.default.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil),
                format: .sevenZip
            )
            make.baseDirectory = stage
            for try await _ in engine.compress(make) {}

            let destination = dir.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.selectedEntries = ["report?.pdf"]
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            let written = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            )
            #expect(written == ["report?.pdf"])
        }
    }

    /// Ordinary selections, and members inside directories, must be unaffected.
    @Test("Literal matching does not break normal selection")
    func normalSelectionStillWorks() async throws {
        try await withScratch { dir in
            let archive = try await makeArchive(in: dir)
            let destination = dir.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.selectedEntries = ["noteA.txt", "other.txt"]
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            let written = Set(
                (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            )
            #expect(written == ["noteA.txt", "other.txt"])
        }
    }
}
