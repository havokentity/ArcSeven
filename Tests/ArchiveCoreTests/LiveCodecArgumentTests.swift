// SPDX-License-Identifier: Apache-2.0
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

@Suite("Live codec arguments", .enabled(if: vendoredSevenZipBinaryIsBuilt()))
struct LiveCodecArgumentTests {
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

    @Test("An explicit dictionary size is sent as a byte count")
    func explicitDictionarySize() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("payload.bin")
            try writeIncompressibleFile(at: source, byteCount: 2 << 20)

            let archive = dir.appendingPathComponent("dict.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.dictionarySize = .bytes(1 << 20)
            _ = try await drain(engine.compress(request))

            #expect(FileManager.default.fileExists(atPath: archive.path),
                    "a dictionary size must not stop the archive being written")
            // 20 is log2(1 MiB): the byte count asked for, arriving intact.
            #expect(try await storedMethod(of: archive) == "LZMA2:20")
        }
    }

    /// PPMd sizes a model memory budget, not a sliding window, and rejects `-md=`
    /// outright. One property name for every codec was a guaranteed `E_INVALIDARG`.
    @Test("PPMd sizes its model memory rather than a dictionary")
    func ppmdDictionarySize() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("payload.bin")
            try writeIncompressibleFile(at: source, byteCount: 2 << 20)

            let archive = dir.appendingPathComponent("ppmd.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.method = .ppmd
            request.dictionarySize = .bytes(8 << 20)
            _ = try await drain(engine.compress(request))

            #expect(FileManager.default.fileExists(atPath: archive.path))
            // mem23 is log2(8 MiB); o6 is the level-5 default order, left alone here.
            #expect(try await storedMethod(of: archive) == "PPMD:o6:mem23")
        }
    }

    /// The Add dialog's Word size combo means fast bytes for the LZ codecs and model
    /// order for PPMd, which is a different property with a different name — and PPMd
    /// rejects the fast-bytes spelling rather than ignoring it.
    @Test("PPMd's word size is its model order")
    func ppmdWordSize() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("payload.bin")
            try writeIncompressibleFile(at: source, byteCount: 2 << 20)

            let archive = dir.appendingPathComponent("order.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.method = .ppmd
            request.wordSize = .value(10)
            _ = try await drain(engine.compress(request))

            #expect(FileManager.default.fileExists(atPath: archive.path))
            // o10 is the order asked for; mem24 is the level-5 default, left alone.
            #expect(try await storedMethod(of: archive) == "PPMD:o10:mem24")
        }
    }

    /// BZip2 has no word-size control, and rejects `-mfb=` rather than ignoring it.
    @Test("A word size is dropped for a codec that has none")
    func wordSizeDroppedForBZip2() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.txt")
            try "content".write(to: source, atomically: true, encoding: .utf8)

            let archive = dir.appendingPathComponent("bz.7z")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            request.method = .bzip2
            request.wordSize = .value(64)
            _ = try await drain(engine.compress(request))

            #expect(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    /// Deflate's window is fixed by the format and the handler rejects `-md=` for it,
    /// so a stale dictionary size left on the request must not be forwarded.
    @Test("A dictionary size is dropped for a codec that has none")
    func dictionarySizeDroppedForDeflate() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.txt")
            try "content".write(to: source, atomically: true, encoding: .utf8)

            let archive = dir.appendingPathComponent("deflate.zip")
            var request = CompressRequest(archiveURL: archive, inputs: [source], format: .zip)
            request.method = .deflate
            request.dictionarySize = .bytes(1 << 20)
            _ = try await drain(engine.compress(request))

            #expect(FileManager.default.fileExists(atPath: archive.path))
        }
    }

    /// tar's dialect is not reported by `l -slt`, so this reads the ustar magic out of
    /// the first header block instead: bytes 257..<265 are `ustar  \0` for GNU and
    /// `ustar\0` `00` for POSIX. That is the whole difference, and it is the only
    /// place it is visible.
    private func ustarMagic(of archive: URL) throws -> [UInt8] {
        let header = try Data(contentsOf: archive).prefix(265)
        return Array(header[257..<265])
    }

    /// tar's only level is Store, so gating the method switch on `level > 0` meant the
    /// Add dialog's GNU/POSIX combo was enabled and wired to nothing: every tar came
    /// out in the default dialect whatever the user picked.
    @Test("The tar dialect reaches the archive")
    func tarDialect() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.txt")
            try "content".write(to: source, atomically: true, encoding: .utf8)

            let gnu = dir.appendingPathComponent("gnu.tar")
            var gnuRequest = CompressRequest(archiveURL: gnu, inputs: [source], format: .tar)
            gnuRequest.level = .store
            gnuRequest.method = .gnuTar
            _ = try await drain(engine.compress(gnuRequest))

            let posix = dir.appendingPathComponent("posix.tar")
            var posixRequest = CompressRequest(archiveURL: posix, inputs: [source], format: .tar)
            posixRequest.level = .store
            posixRequest.method = .posixTar
            _ = try await drain(engine.compress(posixRequest))

            #expect(try ustarMagic(of: gnu) == Array("ustar  \0".utf8))
            #expect(try ustarMagic(of: posix) == Array("ustar\0".utf8) + Array("00".utf8))
        }
    }

    /// The single-stream handlers reject `-m0=`, so choosing the one method their
    /// combo offers used to fail the whole compression.
    @Test("An explicit method on a single-stream handler is accepted")
    func singleStreamMethod() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("a.txt")
            try "content".write(to: source, atomically: true, encoding: .utf8)

            let gzipArchive = dir.appendingPathComponent("a.txt.gz")
            var gzip = CompressRequest(archiveURL: gzipArchive, inputs: [source], format: .gzip)
            gzip.method = .deflate
            _ = try await drain(engine.compress(gzip))
            #expect(FileManager.default.fileExists(atPath: gzipArchive.path))

            let bz2 = dir.appendingPathComponent("a.txt.bz2")
            var bzip2 = CompressRequest(archiveURL: bz2, inputs: [source], format: .bzip2)
            bzip2.method = .bzip2
            _ = try await drain(engine.compress(bzip2))
            #expect(FileManager.default.fileExists(atPath: bz2.path))
        }
    }

    /// `eliminateRootDuplication` documented itself as `-spe` and then never emitted
    /// it, so the Extract dialog's checkbox and the Settings key that both feed it
    /// were two controls wired to nothing.
    @Test("eliminateRootDuplication drops the duplicated root folder")
    func eliminateRootDuplication() async throws {
        try await withTemporaryDirectory { dir in
            // An archive holding one top-level folder, extracted into a destination
            // of the same name — the shape that produces Foo/Foo.
            let root = dir.appendingPathComponent("Foo", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "one".write(to: root.appendingPathComponent("one.txt"),
                            atomically: true, encoding: .utf8)

            let archive = dir.appendingPathComponent("foo.7z")
            var compress = CompressRequest(archiveURL: archive, inputs: [root], format: .sevenZip)
            compress.baseDirectory = dir
            _ = try await drain(engine.compress(compress))

            let nested = dir.appendingPathComponent("plain/Foo", isDirectory: true)
            _ = try await drain(
                engine.extract(ExtractRequest(archiveURL: archive, destinationURL: nested))
            )
            #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("Foo/one.txt").path),
                    "without -spe the stored root is recreated under the destination")

            let flattened = dir.appendingPathComponent("eliminated/Foo", isDirectory: true)
            var request = ExtractRequest(archiveURL: archive, destinationURL: flattened)
            request.eliminateRootDuplication = true
            _ = try await drain(engine.extract(request))
            #expect(FileManager.default.fileExists(atPath: flattened.appendingPathComponent("one.txt").path))
            #expect(!FileManager.default.fileExists(atPath: flattened.appendingPathComponent("Foo").path),
                    "-spe must not leave a second Foo behind")
        }
    }

    /// `keepBrokenFiles` used to send `-tzip:kb`, which is not a switch 26.02 has and
    /// which forced the zip handler onto every archive besides. Setting it did not
    /// salvage anything — it failed the extraction outright.
    @Test("Asking to keep broken files does not break extraction")
    func keepBrokenFilesExtracts() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("hello.txt")
            try "payload".write(to: source, atomically: true, encoding: .utf8)
            let archive = dir.appendingPathComponent("kb.7z")
            _ = try await drain(
                engine.compress(CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip))
            )

            let destination = dir.appendingPathComponent("out")
            var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
            request.keepBrokenFiles = true
            _ = try await drain(engine.extract(request))

            let restored = destination.appendingPathComponent("hello.txt")
            #expect(try String(contentsOf: restored, encoding: .utf8) == "payload")
        }
    }

    /// The claim `keepBrokenFiles` now rests on: 7zz keeps the partial output of a
    /// member that fails CRC whether or not anyone asks it to, so there is nothing
    /// for the flag to switch on. If this ever stops being true the flag needs a real
    /// implementation, not a doc comment.
    @Test("A member that fails CRC leaves its partial output on disk")
    func brokenMemberLeavesPartialOutput() async throws {
        try await withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("payload.bin")
            try writeIncompressibleFile(at: source, byteCount: 2 << 20)

            let archive = dir.appendingPathComponent("corrupt.7z")
            var compress = CompressRequest(archiveURL: archive, inputs: [source], format: .sevenZip)
            compress.level = .fastest
            _ = try await drain(engine.compress(compress))

            // Flip two bytes in the middle of the compressed stream, past the header.
            var bytes = try Data(contentsOf: archive)
            bytes[bytes.count / 2] ^= 0xFF
            bytes[bytes.count / 2 + 1] ^= 0xFF
            try bytes.write(to: archive)

            let destination = dir.appendingPathComponent("out")
            await #expect(throws: (any Error).self) {
                _ = try await drain(
                    engine.extract(
                        ExtractRequest(archiveURL: archive, destinationURL: destination)
                    )
                )
            }

            let salvaged = destination.appendingPathComponent("payload.bin")
            #expect(FileManager.default.fileExists(atPath: salvaged.path),
                    "the broken member should survive the CRC failure, unasked")
            let recovered = try Data(contentsOf: salvaged)
            #expect(!recovered.isEmpty)
            // Damaged, and kept anyway — which is the whole of what "keep broken
            // files" means. How much survives depends on where the damage lands: a
            // stored stream decodes to the end and only fails CRC, a compressed one
            // stops early.
            #expect(recovered != (try Data(contentsOf: source)))
        }
    }

    /// `b` prints one block of `<log2dict>:` rows per pass, so counting the rows for
    /// the first dictionary size counts the passes. `passes` used to be emitted as
    /// `-mmt<n>` — a thread count — so it never made more than one.
    ///
    /// Copy is the codec that keeps this cheap (about a second for three passes) and
    /// it is also the one with no dictionary at all, so the same run proves the
    /// dictionary size is withheld from a codec that would reject it.
}
