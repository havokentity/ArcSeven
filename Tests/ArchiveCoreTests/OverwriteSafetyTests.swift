// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Regression tests for the data-loss bug shipped in 0.1.0.
//
// "Ask before overwrite" — the DEFAULT — silently destroyed existing files. Three
// separate paths reached it, and each of these tests pins one shut by writing a real
// file, running a real extraction over it, and asserting the bytes survived. A test that
// only inspected switches would not have caught the original bug, because each piece
// looked defensible in isolation.

import Foundation
import Testing
@testable import ArchiveCore

func vendored7zzForOverwrite() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let candidate = dir.appendingPathComponent("vendor/bin/7zz")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

@Suite("Overwrite safety", .enabled(if: vendored7zzForOverwrite() != nil))
struct OverwriteSafetyTests {
    /// Safe: the suite is gated on this being non-nil, so reaching it means it exists.
    private var engine: SevenZipCLIEngine {
        let executable = vendored7zzForOverwrite() ?? URL(fileURLWithPath: "/nonexistent")
        return SevenZipCLIEngine(executableURL: executable, timeZone: .gmt)
    }

    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-ow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Build an archive holding `sub/keep.txt`, and a destination already holding a
    /// precious file at both the flattened and the full path.
    private func makeFixture(in dir: URL) async throws -> (archive: URL, destination: URL) {
        let source = dir.appendingPathComponent("src/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "FROM-ARCHIVE".write(to: source.appendingPathComponent("keep.txt"),
                                 atomically: true, encoding: .utf8)

        let archive = dir.appendingPathComponent("a.7z")
        var compress = CompressRequest(
            archiveURL: archive,
            inputs: [dir.appendingPathComponent("src/sub")],
            format: .sevenZip
        )
        compress.baseDirectory = dir.appendingPathComponent("src")
        for try await _ in engine.compress(compress) {}

        let destination = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("sub"), withIntermediateDirectories: true)
        // Both the flattened landing spot and the full-path one.
        try "PRECIOUS".write(to: destination.appendingPathComponent("keep.txt"),
                             atomically: true, encoding: .utf8)
        try "PRECIOUS".write(to: destination.appendingPathComponent("sub/keep.txt"),
                             atomically: true, encoding: .utf8)
        return (archive, destination)
    }

    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>"
    }

    /// The core regression. `.ask` must never reach 7zz as "no switch", because the
    /// mandatory `-y` then answers yes to every overwrite.
    @Test("Ask mode never overwrites: full paths")
    func askDoesNotOverwriteFullPaths() async throws {
        try await withScratch { dir in
            let fixture = try await makeFixture(in: dir)
            var request = ExtractRequest(
                archiveURL: fixture.archive, destinationURL: fixture.destination)
            request.pathMode = .fullPaths
            request.overwriteMode = .ask
            for try await _ in engine.extract(request) {}

            #expect(contents(fixture.destination.appendingPathComponent("sub/keep.txt")) == "PRECIOUS",
                    "Ask mode must not destroy an existing file")
        }
    }

    /// The variant that defeated the pre-scan: `e` flattens, so the member lands at the
    /// BASENAME, which the old pre-scan never probed.
    @Test("Ask mode never overwrites: no pathnames (flattened)")
    func askDoesNotOverwriteFlattened() async throws {
        try await withScratch { dir in
            let fixture = try await makeFixture(in: dir)
            var request = ExtractRequest(
                archiveURL: fixture.archive, destinationURL: fixture.destination)
            request.pathMode = .noPaths
            request.overwriteMode = .ask
            for try await _ in engine.extract(request) {}

            #expect(contents(fixture.destination.appendingPathComponent("keep.txt")) == "PRECIOUS",
                    "flattened extraction must not destroy an existing file in Ask mode")
        }
    }

    @Test("Skip mode leaves existing files alone")
    func skipPreserves() async throws {
        try await withScratch { dir in
            let fixture = try await makeFixture(in: dir)
            var request = ExtractRequest(
                archiveURL: fixture.archive, destinationURL: fixture.destination)
            request.overwriteMode = .skip
            for try await _ in engine.extract(request) {}
            #expect(contents(fixture.destination.appendingPathComponent("sub/keep.txt")) == "PRECIOUS")
        }
    }

    /// The counterpart: an explicit choice to overwrite must still work, or "safe" has
    /// simply become "broken".
    @Test("Overwrite mode still overwrites when explicitly chosen")
    func overwriteStillWorks() async throws {
        try await withScratch { dir in
            let fixture = try await makeFixture(in: dir)
            var request = ExtractRequest(
                archiveURL: fixture.archive, destinationURL: fixture.destination)
            request.pathMode = .fullPaths
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}
            #expect(contents(fixture.destination.appendingPathComponent("sub/keep.txt")) == "FROM-ARCHIVE")
        }
    }

    @Test("Auto-rename keeps both copies")
    func autoRenameKeepsBoth() async throws {
        try await withScratch { dir in
            let fixture = try await makeFixture(in: dir)
            var request = ExtractRequest(
                archiveURL: fixture.archive, destinationURL: fixture.destination)
            request.pathMode = .fullPaths
            request.overwriteMode = .autoRename
            for try await _ in engine.extract(request) {}
            #expect(contents(fixture.destination.appendingPathComponent("sub/keep.txt")) == "PRECIOUS")
            let siblings = (try? FileManager.default.contentsOfDirectory(
                atPath: fixture.destination.appendingPathComponent("sub").path)) ?? []
            #expect(siblings.count >= 2, "the incoming member should land beside it, renamed")
        }
    }

    /// Guards the switch table directly, so a future edit that reintroduces the empty
    /// `.ask` case fails here even before an extraction is run.
    @Test("No overwrite mode maps to an empty switch list")
    func everyModeEmitsASwitch() {
        for mode in [OverwriteMode.ask, .overwrite, .skip, .autoRename, .autoRenameExisting] {
            let emitted = SevenZipCLIEngine.overwriteSwitch(mode)
            #expect(!emitted.isEmpty, "\(mode) emits nothing; -y would then answer yes")
            #expect(emitted.allSatisfy { $0.hasPrefix("-ao") })
        }
        // Ask must be the SAFE end of the range, never -aoa.
        #expect(SevenZipCLIEngine.overwriteSwitch(.ask) == ["-aos"])
    }
}
