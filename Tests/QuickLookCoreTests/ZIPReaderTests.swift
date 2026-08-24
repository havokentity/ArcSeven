// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Quick Look extension parses archive headers itself, in Swift, because a
// sandboxed appex cannot execute the bundled `7zz`. That means it reads attacker-
// controlled bytes with no process boundary to hide behind, and it is the least
// forgiving code in the project.
//
// These tests do two things: check the reader against archives built by the real 7zz,
// and feed it deliberately malformed input to confirm it degrades instead of crashing
// or hanging.

import Foundation
import Testing
@testable import QuickLookCore

/// The vendored binary, used to build fixtures. Nil on a bare checkout.
func vendored7zzForQuickLook() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let candidate = dir.appendingPathComponent("vendor/bin/7zz")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

@Suite("Quick Look archive reader")
struct QuickLookReaderTests {

    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-ql-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    @discardableResult
    private func run7zz(_ arguments: [String]) throws -> Int32 {
        guard let binary = vendored7zzForQuickLook() else { return -1 }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: Real archives

    @Test("A real ZIP's members are listed with correct names and sizes",
          .enabled(if: vendored7zzForQuickLook() != nil))
    func realZip() async throws {
        try await withScratch { dir in
            let source = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let payloads = ["alpha.txt": "aaaa", "beta.txt": String(repeating: "b", count: 1000)]
            for (name, body) in payloads {
                try body.write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            let archive = dir.appendingPathComponent("t.zip")
            try run7zz(["a", "-y", "-tzip", archive.path, source.path + "/."])

            let directory = await ArchiveDirectoryReader.read(fileAt: archive)
            #expect(directory.format == .zip)
            #expect(directory.countsAreKnown)

            let names = Set(directory.entries.map(\.name))
            #expect(names.contains("alpha.txt"))
            #expect(names.contains("beta.txt"))

            let beta = directory.entries.first { $0.name == "beta.txt" }
            #expect(beta?.uncompressedSize == 1000, "declared size must come from the central directory")
            #expect(directory.fileCount == 2)
        }
    }

    @Test("A 7z is identified by signature even though its metadata is compressed",
          .enabled(if: vendored7zzForQuickLook() != nil))
    func real7z() async throws {
        try await withScratch { dir in
            let file = dir.appendingPathComponent("a.txt")
            try "hello".write(to: file, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("t.7z")
            try run7zz(["a", "-y", "-t7z", archive.path, file.path])

            let directory = await ArchiveDirectoryReader.read(fileAt: archive)
            // The version comes from the signature header's two version bytes, so
            // match the case rather than a fixed value.
            if case .sevenZip(let version) = directory.format {
                #expect(!version.isEmpty)
            } else {
                Issue.record("expected .sevenZip, got \(directory.format)")
            }
            #expect(directory.archiveByteSize > 0)
            // 7z's member table lives inside a compressed header, which the preview
            // deliberately does not decode. It must say "unknown", never "0 files".
            #expect(directory.countsAreKnown == false)
        }
    }

    // MARK: Hostile input

    @Test("An empty file does not crash the reader")
    func emptyFile() async throws {
        try await withScratch { dir in
            let file = dir.appendingPathComponent("empty.zip")
            try Data().write(to: file)
            let directory = await ArchiveDirectoryReader.read(fileAt: file)
            #expect(directory.entries.isEmpty)
        }
    }

    @Test("Random bytes with a ZIP extension do not crash the reader")
    func randomBytes() async throws {
        try await withScratch { dir in
            let file = dir.appendingPathComponent("junk.zip")
            var bytes = Data(count: 8192)
            // Deterministic pseudo-random: reproducible failures beat flaky ones.
            var seed: UInt64 = 0x2545_F491_4F6C_DD1D
            for index in 0..<bytes.count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
            }
            try bytes.write(to: file)
            let directory = await ArchiveDirectoryReader.read(fileAt: file)
            #expect(directory.entries.isEmpty || directory.entries.count < 1000)
        }
    }

    /// A truncated archive is the commonest real-world malformation — an interrupted
    /// download. It must not be read past its end.
    @Test("A truncated ZIP is handled, not read past its end",
          .enabled(if: vendored7zzForQuickLook() != nil))
    func truncatedZip() async throws {
        try await withScratch { dir in
            let file = dir.appendingPathComponent("a.txt")
            try String(repeating: "x", count: 5000).write(to: file, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("t.zip")
            try run7zz(["a", "-y", "-tzip", archive.path, file.path])

            let whole = try Data(contentsOf: archive)
            for fraction in [0.25, 0.5, 0.9] {
                let cut = archive.deletingLastPathComponent()
                    .appendingPathComponent("cut\(Int(fraction * 100)).zip")
                try whole.prefix(Int(Double(whole.count) * fraction)).write(to: cut)
                // The contract is "does not crash or hang", not "recovers the data".
                let directory = await ArchiveDirectoryReader.read(fileAt: cut)
                #expect(directory.archiveByteSize > 0)
            }
        }
    }

    /// A central-directory record claiming an absurd filename length must be rejected
    /// against the actual file size rather than trusted and used to allocate.
    @Test("A lying length field is rejected")
    func lyingLengthField() async throws {
        try await withScratch { dir in
            var bytes = Data()
            bytes.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])            // central dir signature
            bytes.append(Data(repeating: 0, count: 24))
            bytes.append(contentsOf: [0xFF, 0xFF])                        // filename length: 65535
            bytes.append(Data(repeating: 0, count: 20))
            bytes.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])            // EOCD signature
            bytes.append(Data(repeating: 0, count: 18))
            let file = dir.appendingPathComponent("lying.zip")
            try bytes.write(to: file)

            let directory = await ArchiveDirectoryReader.read(fileAt: file)
            #expect(directory.entries.count < 10, "must not fabricate entries from a bogus length")
        }
    }

    @Test("A nonexistent file is reported, not crashed on")
    func missingFile() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/nowhere/absent.zip")
        let directory = await ArchiveDirectoryReader.read(fileAt: missing)
        #expect(directory.entries.isEmpty)
    }
}
