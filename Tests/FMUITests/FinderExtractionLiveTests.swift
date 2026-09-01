// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore
@testable import FMUI

func vendored7zzForFinderExtraction() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let candidate = dir.appendingPathComponent("vendor/bin/7zz")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

/// The root count is computed from what `7zz l -slt` actually reports, and whether a given
/// archive carries explicit directory entries is a property of the tool that wrote it, not
/// something to assume. These build real archives and count real listings.
@MainActor
@Suite("Finder extraction, live", .enabled(if: vendored7zzForFinderExtraction() != nil))
struct FinderExtractionLiveTests {
    private var engine: SevenZipCLIEngine {
        let executable = vendored7zzForFinderExtraction() ?? URL(fileURLWithPath: "/nonexistent")
        return SevenZipCLIEngine(executableURL: executable, timeZone: .gmt)
    }

    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-finder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    private func makeArchive(
        named name: String, in dir: URL, containing layout: [String]
    ) async throws -> URL {
        let staging = dir.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for relative in layout {
            let file = staging.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(relative.utf8).write(to: file)
        }
        let archive = dir.appendingPathComponent(name)
        var request = CompressRequest(
            archiveURL: archive,
            inputs: try FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil
            ),
            format: .zip
        )
        request.baseDirectory = staging
        for try await _ in engine.compress(request) {}
        try FileManager.default.removeItem(at: staging)
        return archive
    }

    @Test("A real single-root archive counts one root and extracts loose")
    func singleRootLive() async throws {
        try await withScratch { dir in
            let archive = try await makeArchive(
                named: "project-1.0.zip", in: dir,
                containing: ["project-1.0/README.md", "project-1.0/src/main.swift"]
            )
            let listing = try await engine.list(ListRequest(archiveURL: archive))
            #expect(MainWindowController.rootEntryCount(of: listing) == 1)

            let destination = MainWindowController.extractionDestination(
                forArchive: archive, rootEntryCount: MainWindowController.rootEntryCount(of: listing)
            )
            // Compared by `path`: `deletingLastPathComponent()` returns a URL carrying a
            // directory hint, so the two URLs differ as values while naming the same place.
            #expect(destination.path == dir.path,
                    "a self-contained archive must not gain a second wrapper")
        }
    }

    @Test("A real scattering archive counts every root and is wrapped")
    func scatteringLive() async throws {
        try await withScratch { dir in
            let loose = (0..<12).map { "loose-\($0).txt" }
            let archive = try await makeArchive(named: "bomb.zip", in: dir, containing: loose)
            let listing = try await engine.list(ListRequest(archiveURL: archive))
            let count = MainWindowController.rootEntryCount(of: listing)
            #expect(count == loose.count, "expected \(loose.count) roots, counted \(count)")

            let destination = MainWindowController.extractionDestination(
                forArchive: archive, rootEntryCount: count
            )
            #expect(destination.lastPathComponent == "bomb",
                    "a scattering archive must be wrapped")
        }
    }

    /// The assumption most likely to be wrong: that a directory with no entry of its own is
    /// still visible as the first component of its members' paths.
    @Test("Two top-level folders count as two roots in a real listing")
    func twoFoldersLive() async throws {
        try await withScratch { dir in
            let archive = try await makeArchive(
                named: "mixed.zip", in: dir,
                containing: ["src/main.swift", "src/util.swift", "docs/readme.md"]
            )
            let listing = try await engine.list(ListRequest(archiveURL: archive))
            #expect(MainWindowController.rootEntryCount(of: listing) == 2, "src and docs")
        }
    }
}
