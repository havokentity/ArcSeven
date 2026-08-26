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
    /// Everything a completed operation emitted.
    ///
    /// A named type rather than a 4-tuple: every live test destructures this, and the
    /// members are all collections, so positional access reads as noise.
    struct DrainedOperation {
        var result: ArchiveOperationResult?
        var items: [ArchiveItemEvent] = []
        var progress: [ArchiveProgress] = []
        var logs: [String] = []
    }

    private func drain(_ stream: ArchiveOperationStream) async throws -> DrainedOperation {
        var result: ArchiveOperationResult?
        var items: [ArchiveItemEvent] = []
        var progress: [ArchiveProgress] = []
        var logs: [String] = []
        for try await event in stream {
            switch event {
            case .finished(let value): result = value
            case .item(let item): items.append(item)
            case .progress(let tick): progress.append(tick)
            case .log(let line): logs.append(line)
            default: break
            }
        }
        return DrainedOperation(result: result, items: items, progress: progress, logs: logs)
    }

    /// `Method = LZMA2:20` and friends, straight off `l -slt`. This is the only place
    /// the codec settings a compress request asked for become observable, so the
    /// `-m…` tests assert on it rather than on the argument array.
    private func storedMethod(of archive: URL) async throws -> String? {
        let listing = try await engine.list(ListRequest(archiveURL: archive))
        return listing.entries.first { !$0.isDirectory }?.method
    }

    /// Write `byteCount` bytes of incompressible data. Codec settings are only
    /// observable on an input big enough that 7-Zip does not shrink the dictionary
    /// down to the payload size ("reduce size").
    private func writeIncompressibleFile(at url: URL, byteCount: Int) throws {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(capacity: byteCount)
        while bytes.count < byteCount {
            withUnsafeBytes(of: generator.next()) { bytes.append(contentsOf: $0) }
        }
        try bytes.prefix(byteCount).write(to: url)
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

    @Test("An encrypted multi-volume archive verifies against its first volume")
    func encryptedMultiVolume() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("big.bin")
            try Data(repeating: 0x5A, count: 300_000).write(to: source)
            let archive = dir.appendingPathComponent("split.7z")

            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.encryption = CompressRequest.EncryptionOptions(password: "correct horse")
            request.volumeSizes = [100_000]

            // The bug: verification listed `split.7z`, which -v never creates. 7zz exited 2
            // with errno=2, so this call threw and the user was told an archive that had
            // been written correctly, and encrypted correctly, had failed.
            _ = try await drain(engine.compress(request))

            let first = dir.appendingPathComponent("split.7z.001")
            #expect(FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: archive.path),
                    "-v writes numbered volumes and no base archive")

            let listing = try await engine.list(
                ListRequest(archiveURL: first, password: "correct horse")
            )
            #expect(listing.isEncrypted)
        }
    }

    /// Exercises the list-file path against the real binary. The unit tests prove the file
    /// is written correctly; only 7zz can prove it is READ correctly — that `-i@file` is
    /// honoured, that `-scsUTF-8` makes it UTF-8, and that a selection which would have
    /// died with E2BIG on argv now extracts exactly the members asked for.
    ///
    /// The selection is taken from a real listing rather than assumed, because how members
    /// are named depends on the compress request that produced them.
    @Test("A selection too large for argv extracts through a list file")
    func largeSelectionExtracts() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

            let count = 3000
            for index in 0..<count {
                let name = "a-fairly-long-member-name-to-eat-argument-space-\(index).txt"
                try "\(index)".write(to: source.appendingPathComponent(name),
                                     atomically: true, encoding: .utf8)
            }
            // A non-ASCII member: proves the list file round-trips as UTF-8 rather than
            // being read in some OEM code page, where it would silently fail to match.
            let unicode = "café-ünïcode-🗜.txt"
            try "u".write(to: source.appendingPathComponent(unicode),
                          atomically: true, encoding: .utf8)

            let archive = dir.appendingPathComponent("many.7z")
            var compress = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            compress.baseDirectory = dir
            _ = try await drain(engine.compress(compress))

            let listing = try await engine.list(ListRequest(archiveURL: archive))
            let members = listing.entries.filter { !$0.isDirectory }.map(\.path)
            #expect(members.count == count + 1, "archive should hold every file written")

            let budget = members.reduce(0) { $0 + $1.utf8.count + 1 }
            #expect(budget > SelectionListFile.threshold, "selection must exercise the list file")

            let destination = dir.appendingPathComponent("out", isDirectory: true)
            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.selectedEntries = members
            request.overwriteMode = .overwrite
            _ = try await drain(engine.extract(request))

            let extractedRoot = destination.appendingPathComponent("src")
            let extracted = try FileManager.default.contentsOfDirectory(atPath: extractedRoot.path)
            #expect(extracted.count == members.count,
                    "expected \(members.count) members, got \(extracted.count)")
            #expect(extracted.contains(unicode), "the non-ASCII member must survive the list file")
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

    /// The Add dialog's Dictionary size combo produces byte counts. `-md=N` without a
    /// suffix is a log2 exponent that 7zz refuses above 31, so every one of those byte
    /// counts used to exit 2 with `E_INVALIDARG` and write nothing at all.
    @Test("A benchmark runs the passes it was asked for")
    func benchmarkPasses() async throws {
        var request = BenchmarkRequest()
        request.passes = 3
        request.method = .copy
        request.dictionarySize = 1 << 20
        request.threads = 1

        let outcome = try await drain(engine.benchmark(request))
        #expect(outcome.result != nil)

        let firstRowLabel = outcome.logs
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let colon = trimmed.firstIndex(of: ":"),
                      trimmed[trimmed.startIndex..<colon].allSatisfy(\.isNumber),
                      colon > trimmed.startIndex
                else { return nil }
                return String(trimmed[trimmed.startIndex..<colon])
            }
            .first
        let label = try #require(firstRowLabel, "benchmark printed no dictionary rows")
        let blocks = outcome.logs.filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(label):")
        }
        #expect(blocks.count == 3, "expected one \(label): row per pass, got \(blocks.count)")
    }

    /// The parser suite pins the scan grammar against a fixture; this pins the fixture
    /// against the binary. `7zz` paints `  0M Scan ` before it starts compressing, and
    /// the only way to know that is still the shape it emits is to read it off a real
    /// run.
    @Test("The real scan indicator never surfaces as a filename")
    func scanIndicatorIsNotReportedAsAPath() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("tree", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for index in 0..<200 {
                try "\(index)".write(to: source.appendingPathComponent("f\(index).txt"),
                                     atomically: true, encoding: .utf8)
            }

            let archive = dir.appendingPathComponent("scan.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.baseDirectory = dir
            request.level = .store
            let outcome = try await drain(engine.compress(request))

            let paths = outcome.progress.compactMap(\.currentItemPath)
            #expect(!paths.contains { $0.localizedCaseInsensitiveContains("Scan") },
                    "reported paths: \(Set(paths).sorted())")
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
