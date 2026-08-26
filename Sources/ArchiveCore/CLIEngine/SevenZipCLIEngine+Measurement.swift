// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The two measurement operations: `h` (hash) and `b` (benchmark).
//
// Split out of SevenZipCLIEngine.swift purely for size — this is the same type. They belong
// together: neither reads or writes an archive's contents, both are the least-exercised
// paths in the engine, and both had argument bugs that no caller was hitting yet.

import Foundation

extension SevenZipCLIEngine {
    public func hash(_ request: HashRequest) -> ArchiveOperationStream {
        let delivery = Self.readDelivery(request.password)
        var arguments = ["h"]
        arguments += Self.commonSwitches(passwordOnStdin: delivery.usesStdin)
        arguments.append("-scrc\(request.algorithm.switchValue)")
        arguments.append("--")
        switch request.source {
        case .files(let urls):
            arguments.append(contentsOf: urls.map(\.path))
        case let .archiveEntries(archiveURL, entryPaths):
            // Hashing members means decompressing them, so this is an extract-to-stdout
            // with hashing rather than a plain `h` over files.
            arguments.append(archiveURL.path)
            if let entryPaths { arguments.append(contentsOf: entryPaths) }
        }
        return runStreaming(
            operation: .hash,
            arguments: arguments,
            delivery: delivery,
            path: nil
        )
    }

    public func benchmark(_ request: BenchmarkRequest) -> ArchiveOperationStream {
        runStreaming(
            operation: .benchmark,
            arguments: Self.benchmarkArguments(for: request),
            delivery: .absent,
            path: nil
        )
    }

    /// The `b` command line. Split out so the spellings below can be asserted without
    /// paying for a benchmark run per case — they are slow, and most of them differ
    /// only in one token.
    static func benchmarkArguments(for request: BenchmarkRequest) -> [String] {
        var arguments = ["b"]
        // The pass count is a POSITIONAL argument to `b`, not a switch: `7zz b 3`
        // runs three iterations. It used to be emitted as `-mmt<n>`, which is a
        // THREAD count, and then `threads` appended a second one — so the child was
        // handed `mt2 mt8`, ran whichever won, and never made more than one pass.
        if request.passes > 0 { arguments.append("\(request.passes)") }
        arguments += commonSwitches(passwordOnStdin: false)
        // `-mm=`, the flat spelling. `b` has no coder chain to index with `-m0=`, and
        // the method was previously not emitted at all.
        if let method = request.method { arguments.append("-mm=\(method.switchValue)") }
        // Byte count, and the property name the codec actually has — identical rules
        // to compression, and identical consequences for getting them wrong.
        // Verified: `b -mm=Deflate -md=20` exits 2 while `b -mm=Deflate` exits 0, and
        // `b -mm=PPMd -mmem=16777216b` exits 0. A `nil` method is 7zz's own default
        // benchmark codec, LZMA, which sizes a dictionary.
        if let dictionary = request.dictionarySize,
           let property = (request.method ?? .lzma).dictionaryPropertyName {
            arguments.append("-m\(property)=\(dictionary)b")
        }
        if let threads = request.threads { arguments.append("-mmt=\(threads)") }
        return arguments
    }
}
