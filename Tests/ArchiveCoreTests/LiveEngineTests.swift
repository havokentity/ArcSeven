// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Integration tests that drive the REAL vendored `7zz`.
//
// The parser suites use byte fixtures and run anywhere. These do not: they build
// actual archives and read them back, which is the only way to catch a switch that
// changed meaning between upstream releases. They skip themselves when the vendored
// binary is absent, so a bare checkout still passes `swift test`.
//
// docs/ENGINE-PROTOCOL.md §10 requires this suite to be re-run against the exact
// bundled 7zz on every version bump.

import Foundation
import Testing
@testable import ArchiveCore

/// Where the staged universal binary lives, built or not.
///
/// Free-standing rather than a static member: a `@Suite` trait cannot reference the
/// type it is attached to without the macro expansion becoming circular.
func vendoredSevenZipBinary() -> URL {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { dir.deleteLastPathComponent() }
    return dir.appendingPathComponent("vendor/bin/7zz")
}

/// Whether that binary has actually been built. The suite skips itself when it has not,
/// so `vendoredSevenZipBinary()` is only ever run against a real executable.
func vendoredSevenZipBinaryIsBuilt() -> Bool {
    FileManager.default.isExecutableFile(atPath: vendoredSevenZipBinary().path)
}

@Suite("Live 7zz engine", .enabled(if: vendoredSevenZipBinaryIsBuilt()))
struct LiveEngineTests {
    private var engine: SevenZipCLIEngine {
        SevenZipCLIEngine(executableURL: vendoredSevenZipBinary(), timeZone: .gmt)
    }

    /// A scratch directory that cleans up after itself.
    private func withTemporaryDirectory<T>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arcseven-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }

    /// Drain an operation stream, returning everything it reported.
    private func drain(
        _ stream: ArchiveOperationStream
    ) async throws -> (result: ArchiveOperationResult?, items: [ArchiveItemEvent], progress: [ArchiveProgress]) {
        var result: ArchiveOperationResult?
        var items: [ArchiveItemEvent] = []
        var progress: [ArchiveProgress] = []
        for try await event in stream {
            switch event {
            case .finished(let value): result = value
            case .item(let item): items.append(item)
            case .progress(let tick): progress.append(tick)
            default: break
            }
        }
        return (result, items, progress)
    }

    @Test("Capabilities report the real vendored version")
    func capabilities() async throws {
        let caps = try await engine.capabilities()
        #expect(caps.versionDescription.contains("7-Zip"))
        #expect(caps.versionDescription.contains("26.02"))
        #expect(caps.creatableFormats.contains(.sevenZip))
        #expect(caps.supportsBenchmark)
        // The CLI engine cannot keep a creation passphrase out of the process table.
        #expect(caps.keepsPasswordsInProcess == false)
    }

    @Test("Round-trip: create a 7z, list it, extract it")
    func roundTrip() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("hello.txt")
            let payload = "the quick brown fox\n"
            try payload.write(to: source, atomically: true, encoding: .utf8)

            let archive = dir.appendingPathComponent("out.7z")
            let compress = try await drain(
                engine.compress(
                    CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
                )
            )
            #expect(compress.result != nil)
            #expect(FileManager.default.fileExists(atPath: archive.path))

            let listing = try await engine.list(ListRequest(archiveURL: archive))
            #expect(listing.entries.count == 1)
            #expect(listing.entries.first?.name == "hello.txt")
            #expect(listing.entries.first?.size == UInt64(payload.utf8.count))
            #expect(listing.format == ArchiveFormat(rawValue: "7z"))

            let destination = dir.appendingPathComponent("out")
            let extract = try await drain(
                engine.extract(ExtractRequest(archiveURL: archive, destinationURL: destination))
            )
            #expect(extract.result != nil)
            let restored = destination.appendingPathComponent("hello.txt")
            #expect(try String(contentsOf: restored, encoding: .utf8) == payload)
        }
    }

    @Test("Testing a good archive succeeds")
    func testArchive() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.txt")
            try "content".write(to: source, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("t.7z")
            _ = try await drain(
                engine.compress(CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip))
            )
            let outcome = try await drain(engine.test(TestRequest(archiveURL: archive)))
            #expect(outcome.result != nil)
        }
    }

    /// The guard against silently handing the user a plaintext archive.
    @Test("An AES-256 archive round-trips and is detected as encrypted")
    func encryptedRoundTrip() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("secret.txt")
            try "classified".write(to: source, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("enc.7z")

            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.encryption = CompressRequest.EncryptionOptions(password: "correct horse")
            // compress() runs verifyEncryption() internally; if it did not encrypt,
            // this throws rather than silently succeeding.
            _ = try await drain(engine.compress(request))

            let listing = try await engine.list(
                ListRequest(archiveURL: archive, password: "correct horse")
            )
            #expect(listing.isEncrypted)
            #expect(listing.entries.contains { $0.name == "secret.txt" })
        }
    }

    @Test("A wrong password is reported as a password problem")
    func wrongPassword() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("s.txt")
            try "data".write(to: source, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("enc2.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.encryption = CompressRequest.EncryptionOptions(password: "right")
            _ = try await drain(engine.compress(request))

            let destination = dir.appendingPathComponent("out")
            do {
                _ = try await drain(
                    engine.extract(
                        ExtractRequest(
                            archiveURL: archive,
                            destinationURL: destination,
                            password: "wrong"
                        )
                    )
                )
                Issue.record("extracting with the wrong password should throw")
            } catch let error as ArchiveError {
                #expect(error.needsPassword, "got \(error)")
            }
        }
    }

    @Test("readEntry streams a member without writing it to disk")
    func readEntryStreams() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("stream.txt")
            let payload = String(repeating: "abcdefghij", count: 500)
            try payload.write(to: source, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("s.7z")
            _ = try await drain(
                engine.compress(CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip))
            )

            var received = Data()
            for try await chunk in engine.readEntry(
                ReadEntryRequest(archiveURL: archive, entryPath: "stream.txt")
            ) {
                received.append(chunk)
            }
            #expect(String(bytes: received, encoding: .utf8) == payload)
        }
    }

    @Test("Listing a non-archive fails rather than returning an empty listing")
    func notAnArchive() async throws {
        try await withTemporaryDirectory { dir in
            let junk = dir.appendingPathComponent("junk.7z")
            try Data(repeating: 0x41, count: 4096).write(to: junk)
            await #expect(throws: (any Error).self) {
                _ = try await engine.list(ListRequest(archiveURL: junk))
            }
        }
    }
}
