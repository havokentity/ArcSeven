// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The Add dialog's thread rules against a described machine rather than the host's
// (FIDELITY ADD-17, ADD-18). Through 0.1.6 the model counted every logical core and the
// request left the count to `7zz`, which counts the same way — so on Apple silicon an
// automatic LZMA2 compression asked for the E-cores and was slower for it.

import Foundation
import Testing
@testable import ArchiveCore
@testable import Dialogs
@testable import Support

@Suite("Compress dialog threads")
struct CompressDialogThreadTests {
    private let appleSilicon = CPUTopology(
        performanceCoreCount: 8, efficiencyCoreCount: 4, logicalCoreCount: 12, physicalCoreCount: 12
    )

    private func makeModel(_ topology: CPUTopology) -> CompressDialogModel {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        return CompressDialogModel(
            defaultArchiveURL: base.appendingPathComponent("out.7z"),
            inputs: [base.appendingPathComponent("input.txt")],
            topology: topology
        )
    }

    @Test("The automatic entry is the P-core count on a heterogeneous machine")
    func automaticIsPerformanceCores() {
        let model = makeModel(appleSilicon)
        #expect(model.format == .sevenZip)
        #expect(model.automaticThreadCount == 8)
        #expect(model.effectiveThreads == 8)
        // The explicit list still runs to the logical count doubled, as upstream's does.
        #expect(model.threadChoices == Array(1...24))
    }

    @Test("The request spells the automatic count out where 7zz would count E-cores")
    func requestCarriesAnExplicitCount() throws {
        let request = try makeModel(appleSilicon).makeRequest()
        #expect(request.threads == .count(8))
    }

    @Test("A homogeneous machine leaves the count to 7zz")
    func homogeneousStaysAutomatic() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let model = CompressDialogModel(
            defaultArchiveURL: base.appendingPathComponent("out.7z"),
            inputs: [base.appendingPathComponent("input.txt")],
            hardwareThreads: 8
        )
        #expect(model.automaticThreadCount == 8)
        #expect(model.threadChoices == Array(1...16))
        #expect(try model.makeRequest().threads == .automatic)
    }

    @Test("The codec's own ceiling still caps the automatic count")
    func codecCeilingApplies() throws {
        var model = makeModel(appleSilicon)
        model.method = .lzma            // LZMA's encoder uses at most two threads.
        model.reconcile()
        #expect(model.automaticThreadCount == 2)
        #expect(try model.makeRequest().threads == .count(2))
    }

    @Test("An explicit choice is passed through untouched")
    func explicitChoiceWins() throws {
        var model = makeModel(appleSilicon)
        model.threads = .count(3)
        model.reconcile()
        #expect(model.effectiveThreads == 3)
        #expect(try model.makeRequest().threads == .count(3))
    }
}
