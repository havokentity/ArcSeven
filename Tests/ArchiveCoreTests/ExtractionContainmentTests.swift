// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Extraction must not write outside the destination directory.
//
// `docs/SECURITY.md` §1 and §2 used to describe these as ArcSeven's own mitigations. They
// are not: nothing in ArcSeven inspects member paths before extraction, and `PathSafety`
// is not on the extraction path at all. The containment is 7-Zip's, and it holds — but
// "it holds" was an assumption nobody had tested, and an assumption is exactly what
// silently stops being true when a switch is added or the vendored binary is bumped.
//
// So these tests build genuinely hostile archives and assert nothing escapes.

import Foundation
import Testing
@testable import ArchiveCore

func vendored7zzForContainment() -> URL? {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    let candidate = dir.appendingPathComponent("vendor/bin/7zz")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
}

@Suite("Extraction containment", .enabled(if: vendored7zzForContainment() != nil))
struct ExtractionContainmentTests {
    private var engine: SevenZipCLIEngine {
        let executable = vendored7zzForContainment() ?? URL(fileURLWithPath: "/nonexistent")
        return SevenZipCLIEngine(executableURL: executable, timeZone: .gmt)
    }

    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-containment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Writes a ZIP by hand. `7zz` will not create a member named `../x`, which is exactly
    /// why the hostile archive has to be built at the byte level.
    private func writeZip(_ members: [(name: String, body: String)], to url: URL) throws {
        var local = Data()
        var central = Data()
        func u16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func u32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }

        for (name, body) in members {
            let nameBytes = Data(name.utf8)
            let bodyBytes = Data(body.utf8)
            let crc = Self.crc32(bodyBytes)
            let offset = local.count

            local += u32(0x0403_4B50) + u16(10) + u16(0) + u16(0) + u16(0) + u16(0)
            local += u32(Int(crc)) + u32(bodyBytes.count) + u32(bodyBytes.count)
            local += u16(nameBytes.count) + u16(0) + nameBytes + bodyBytes

            central += u32(0x0201_4B50) + u16(20) + u16(10) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(Int(crc)) + u32(bodyBytes.count) + u32(bodyBytes.count)
            central += u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(0) + u32(offset) + nameBytes
        }

        var out = local
        let centralOffset = out.count
        out += central
        out += u32(0x0605_4B50) + u16(0) + u16(0)
        out += u16(members.count) + u16(members.count)
        out += u32(central.count) + u32(centralOffset) + u16(0)
        try out.write(to: url)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1) }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// Every file written anywhere under `root`, so escapes are detected by absence from
    /// the destination rather than by guessing where they landed.
    private func files(under root: URL) -> Set<String> {
        var found: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: { _, _ in true }
        )
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.insert(url.standardizedFileURL.path)
            }
        }
        return found
    }

    @Test("A member with ../ cannot escape the destination")
    func traversalIsContained() async throws {
        try await withScratch { dir in
            let archive = dir.appendingPathComponent("evil.zip")
            try writeZip([
                (name: "../../ESCAPED.txt", body: "escaped"),
                (name: "normal.txt", body: "ok"),
            ], to: archive)

            let destination = dir.appendingPathComponent("dest", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            // Nothing outside `dest` — checked across the whole scratch tree, not just the
            // two paths a `../../` happens to produce today.
            let escaped = files(under: dir)
                .filter { !$0.hasPrefix(destination.standardizedFileURL.path + "/") }
                .filter { $0 != archive.standardizedFileURL.path }
            #expect(escaped.isEmpty, "extraction wrote outside the destination: \(escaped)")
            #expect(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("normal.txt").path))
        }
    }

    @Test("A member with an absolute path cannot escape the destination")
    func absolutePathIsContained() async throws {
        try await withScratch { dir in
            let outside = dir.appendingPathComponent("OUTSIDE.txt")
            let archive = dir.appendingPathComponent("abs.zip")
            try writeZip([(name: outside.path, body: "absolute")], to: archive)

            let destination = dir.appendingPathComponent("dest", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            #expect(!FileManager.default.fileExists(atPath: outside.path),
                    "an absolute member path must not be honoured literally")
        }
    }

    /// The `.absolutePaths` path mode passes `-spf2`, which exists to preserve stored
    /// paths. It must still not let an archive write outside where the user pointed.
    @Test("Absolute-paths mode is still contained")
    func absolutePathsModeIsContained() async throws {
        try await withScratch { dir in
            let outside = dir.appendingPathComponent("SPF-ESCAPED.txt")
            let archive = dir.appendingPathComponent("spf.zip")
            try writeZip([
                (name: "../../SPF-ESCAPED.txt", body: "escaped"),
                (name: outside.path, body: "absolute"),
            ], to: archive)

            let destination = dir.appendingPathComponent("dest", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.pathMode = .absolutePaths
            request.overwriteMode = .overwrite
            for try await _ in engine.extract(request) {}

            let escaped = files(under: dir)
                .filter { !$0.hasPrefix(destination.standardizedFileURL.path + "/") }
                .filter { $0 != archive.standardizedFileURL.path }
            #expect(escaped.isEmpty, "-spf2 allowed an escape: \(escaped)")
        }
    }
}
