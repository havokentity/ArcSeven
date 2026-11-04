// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Add to Archive: the thread rules (FIDELITY ADD-17, ADD-18).
//
// Split out of CompressDialogModel.swift for size; this is the same type. The three
// questions answered here — what `*  <auto>` stands for, how far the combo's explicit list
// runs, and what the request actually carries — all go through `ThreadPlanner`, which is
// where the reasoning about P-cores and E-cores lives. Nothing else in the model counts
// cores by itself.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(Support)   // module-guard
import Support
#endif

extension CompressDialogModel {
    /// A model for a machine whose cores are all the same speed.
    ///
    /// The testing seam the thread rules used to be exercised through, kept so a test
    /// can still say "eight logical CPUs" without describing a topology.
    public init(defaultArchiveURL: URL, inputs: [URL], hardwareThreads: Int) {
        let count = max(1, hardwareThreads)
        self.init(
            defaultArchiveURL: defaultArchiveURL,
            inputs: inputs,
            topology: CPUTopology(
                performanceCoreCount: count,
                efficiencyCoreCount: 0,
                logicalCoreCount: count,
                physicalCoreCount: count
            )
        )
    }

    /// The largest explicit count the combo offers. Deliberately still the *logical*
    /// core count doubled (ADD-17); only the automatic value leaves the E-cores out.
    var selectableThreadCeiling: Int {
        ThreadPlanner.maximumSelectableThreadCount(
            algorithmMaximum: FormatCatalog.maximumThreads(format: format, method: method),
            topology: topology
        )
    }

    /// The count the `*  <auto>` entry stands for.
    ///
    /// `ThreadPlanner`, not `FormatCatalog.automaticThreads`: on Apple silicon the latter
    /// counted every logical core, E-cores included, and LZMA2's equal-size block split
    /// then finished when the slowest E-core block finished — a job handed more threads
    /// than there are fast cores ran *slower*, and paid for the idle threads in
    /// dictionary memory as well. The planner budgets the P-cores alone (ADD-17, ADD-18).
    public var automaticThreadCount: Int {
        ThreadPlanner.recommendedThreadCount(
            upperBound: FormatCatalog.maximumThreads(format: format, method: method),
            topology: topology
        )
    }

    /// What the request carries for the thread count.
    ///
    /// `.automatic` emits no `-mmt` and lets `7zz` decide, and `7zz` decides on every
    /// logical core — the number ``automaticThreadCount`` exists to avoid on a machine
    /// with slow cores. So on a heterogeneous machine the automatic entry is spelled out
    /// as an explicit count; on a homogeneous one it stays `.automatic`, which is the
    /// same number by a shorter route and leaves the command line as it always was.
    var requestedThreads: ThreadCount {
        guard threads == .automatic,
              topology.isHeterogeneous,
              descriptor?.supportsMultithreading == true
        else { return threads }
        return .count(automaticThreadCount)
    }
}
