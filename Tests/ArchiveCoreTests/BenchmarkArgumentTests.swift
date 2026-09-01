// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// A benchmark pass costs seconds, and most of these cases differ by one token, so the
// spellings are asserted on the argument array instead. Every expectation here was
// first measured against the vendored 26.02 binary; the exit codes are recorded on
// each test. The one thing an argument array cannot show — that `passes` actually
// produces N passes — is covered live in LiveEngineTests.

import Testing
@testable import ArchiveCore

@Suite("Benchmark arguments")
struct BenchmarkArgumentTests {
    private func arguments(_ request: BenchmarkRequest) -> [String] {
        SevenZipCLIEngine.benchmarkArguments(for: request)
    }

    /// `7zz b [<passes>] [switches]`. The count is positional; `-mmt` is threads.
    /// Verified: `b 3 …` prints three blocks of dictionary rows, `b -mmt3 -mmt1`
    /// prints one and echoes the conflicting `mt3 mt1`.
    @Test("The pass count is positional and the thread count is the only -mmt")
    func passesArePositional() {
        var request = BenchmarkRequest()
        request.passes = 3
        request.threads = 8

        let built = arguments(request)
        #expect(built.first == "b")
        #expect(built.dropFirst().first == "3", "the pass count must follow the command")
        #expect(built.filter { $0.hasPrefix("-mmt") } == ["-mmt=8"])
    }

    /// 7-Zip's own default is one pass, and a pass count of zero would be nonsense to
    /// pass positionally — `7zz b 0` is not a shorter benchmark, it is a parse of the
    /// archive-name slot.
    @Test("A non-positive pass count is omitted rather than sent")
    func nonPositivePassesOmitted() {
        var request = BenchmarkRequest()
        request.passes = 0
        #expect(!arguments(request).contains("0"))
    }

    /// `-mm=`, and the method used not to be emitted at all. Verified: `b -mm=BZip2`
    /// and `b -mm=PPMd` both exit 0.
    @Test("The method is named with -mm=")
    func methodSpelling() {
        var request = BenchmarkRequest()
        request.method = .bzip2
        #expect(arguments(request).contains("-mm=BZip2"))
        #expect(!arguments(request).contains { $0.hasPrefix("-m0=") })
    }

    /// Same byte-count rule as compression: unsuffixed is a log2 exponent. Verified:
    /// `b -md=1048576b` exits 0 and benchmarks a 1 MiB dictionary.
    @Test("The dictionary size carries its byte suffix")
    func dictionaryIsBytes() {
        var request = BenchmarkRequest()
        request.dictionarySize = 1 << 20
        #expect(arguments(request).contains("-md=1048576b"))
    }

    /// Verified: `b -mm=PPMd -md=…` exits 2, `b -mm=PPMd -mmem=16777216b` exits 0.
    @Test("PPMd sizes memory rather than a dictionary")
    func ppmdSizesMemory() {
        var request = BenchmarkRequest()
        request.method = .ppmd
        request.dictionarySize = 16 << 20

        let built = arguments(request)
        #expect(built.contains("-mmem=16777216b"))
        #expect(!built.contains { $0.hasPrefix("-md=") })
    }

    /// Verified: `b -mm=Deflate -md=20` exits 2 while `b -mm=Deflate` exits 0 — the
    /// dictionary switch, not the method, is what the handler rejects.
    @Test("A dictionary size is withheld from a codec that has none")
    func dictionaryWithheld() {
        var request = BenchmarkRequest()
        request.method = .deflate
        request.dictionarySize = 1 << 20
        #expect(!arguments(request).contains { $0.hasPrefix("-md=") || $0.hasPrefix("-mmem=") })
    }
}
