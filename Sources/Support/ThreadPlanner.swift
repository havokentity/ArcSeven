// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// How many compression threads to ask 7-Zip for. FIDELITY ADD-17, ADD-18.
//
// The Windows original's automatic thread count is `min(cpus, numAlgoThreadsMax)`, reduced
// while the estimated memory exceeds the limit. `cpus` there is every logical processor,
// which is right on a machine where all the processors are the same. On Apple silicon they
// are not, and taking that number is actively harmful:
//
//   * LZMA2's multithreaded mode cuts the input into equal-size blocks, one per thread,
//     and the operation finishes when the *last* block finishes. An E-core sustains
//     roughly a third of a P-core's throughput on this kind of code, so the block that
//     lands on an E-core takes about three times as long while the P-cores sit idle
//     having finished theirs. The wall-clock time of the whole job is set by that
//     straggler. Handing the job more threads than there are fast cores therefore makes
//     it *slower* than not using the slow cores at all - the equal-partitioning is what
//     turns extra workers into a longer critical path.
//
//   * Every additional LZMA2 thread costs another dictionary-sized allocation, plus the
//     fixed overheads the memory estimator models (see FIDELITY ADD-21). Threads that add
//     no throughput still add memory, and once the estimate crosses the memory limit the
//     dialog compensates by shrinking the dictionary - so E-core threads are paid for in
//     compression ratio.
//
//   * The topology is not even the whole story: macOS chooses P-cores or E-cores from the
//     thread's QoS, not from how many threads exist. A job running at `.utility` or
//     `.background` is placed on the E-cores whatever this function returns, which is why
//     the Progress window's Background button is a QoS change and why a compress must run
//     at `.userInitiated` for this budget to mean anything at all.
//
// Extraction is different in kind - it is usually I/O-bound and the decoder is far less
// parallel - so none of this is applied to it; the engine's own defaults stand.
//
// On Intel Macs `hw.perflevel*` does not exist, `sysctlbyname` fails, and the fallback is
// `hw.logicalcpu`, which is the Windows behaviour and correct there.
//
// NOTHING CALLS THIS YET, and saying so here is the point. `CompressDialogModel` still takes
// `ProcessInfo.processInfo.activeProcessorCount` and hands it to
// `FormatCatalog.automaticThreads`, so ADD-17's "prefers the P-core count on Apple silicon"
// and ADD-18's `hw.perflevel*` hardware hint are, today, claims and not behaviour - every
// automatic compression on an Apple silicon Mac asks for every logical core, E-cores
// included, which the analysis above calls actively harmful. Sources/Dialogs is where that
// changes, in three places:
//
//   * `CompressDialogModel.effectiveThreads` - replace
//     `FormatCatalog.automaticThreads(format:method:hardwareThreads:)` with
//     `ThreadPlanner.recommendedThreadCount(upperBound: FormatCatalog.maximumThreads(format:method:))`.
//   * `CompressDialogModel.threadChoices` and `reconcileThreads` - the `hardwareThreads * 2`
//     ceilings become `ThreadPlanner.maximumSelectableThreadCount(algorithmMaximum:)`. Note
//     that this ceiling is deliberately still the *logical* core count doubled, per ADD-17;
//     only the automatic value drops the E-cores.
//   * `CompressDialogModel.init`'s `hardwareThreads` default -
//     `ThreadPlanner.topology.logicalCoreCount`, which is the same number
//     `activeProcessorCount` reports but comes from the same read as everything else here.
//
// `CPUTopology.summary` ("12P + 4E (16 threads)") is ADD-18's hint string, and has no home
// until the Add dialog grows a place to show it.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// What the machine actually has.
public struct CPUTopology: Hashable, Sendable {
    /// Logical CPUs at performance level 0 - the fastest cluster. On Apple silicon these
    /// are the P-cores, and because they have no SMT the count is also the physical count.
    public let performanceCoreCount: Int

    /// Logical CPUs at performance level 1, the E-cores. Zero on a homogeneous machine.
    public let efficiencyCoreCount: Int

    /// `hw.logicalcpu`: every schedulable thread, SMT siblings included.
    public let logicalCoreCount: Int

    /// `hw.physicalcpu`: cores, without SMT siblings.
    public let physicalCoreCount: Int

    /// Whether the machine has cores of different speeds - every Apple silicon Mac.
    public var isHeterogeneous: Bool {
        performanceCoreCount > 0 && efficiencyCoreCount > 0
    }

    /// For the Benchmark window and the Add dialog's hardware hint (ADD-18).
    public var summary: String {
        guard isHeterogeneous else { return "\(logicalCoreCount) threads" }
        return "\(performanceCoreCount)P + \(efficiencyCoreCount)E (\(logicalCoreCount) threads)"
    }

    public init(
        performanceCoreCount: Int,
        efficiencyCoreCount: Int,
        logicalCoreCount: Int,
        physicalCoreCount: Int
    ) {
        self.performanceCoreCount = performanceCoreCount
        self.efficiencyCoreCount = efficiencyCoreCount
        self.logicalCoreCount = logicalCoreCount
        self.physicalCoreCount = physicalCoreCount
    }

    /// Ask the kernel.
    public static func detect() -> Self {
        let logical = max(sysctlInteger("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount, 1)
        let physical = sysctlInteger("hw.physicalcpu") ?? logical

        // Absent on Intel, where there is only one performance level and the node is not
        // published at all. Both must be present to believe the split.
        let performance = sysctlInteger("hw.perflevel0.logicalcpu")
        let efficiency = sysctlInteger("hw.perflevel1.logicalcpu")

        guard let performance, let efficiency, performance > 0 else {
            return Self(
                performanceCoreCount: logical,
                efficiencyCoreCount: 0,
                logicalCoreCount: logical,
                physicalCoreCount: physical
            )
        }

        return Self(
            performanceCoreCount: performance,
            efficiencyCoreCount: max(efficiency, 0),
            logicalCoreCount: logical,
            physicalCoreCount: physical
        )
    }

    /// One `sysctlbyname` integer node, or `nil` when the node does not exist.
    private static func sysctlInteger(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, size == MemoryLayout<Int32>.size else {
            return nil
        }
        return Int(value)
    }
}

/// Chooses the thread count for a compression job.
public enum ThreadPlanner {
    /// The machine, read once. Core counts do not change while the process runs.
    public static let topology = CPUTopology.detect()

    /// The thread count to use when the user has left the Add dialog on `*  <auto>`.
    ///
    /// - Parameters:
    ///   - upperBound: The algorithm's own ceiling - `numAlgoThreadsMax` for the chosen
    ///     method, or a count the memory estimator has already reduced. `nil` for none.
    ///   - topology: Injectable so the decision is testable without the host's hardware.
    /// - Returns: At least 1.
    public static func recommendedThreadCount(
        upperBound: Int? = nil,
        topology: CPUTopology = Self.topology
    ) -> Int {
        // The whole point of the file: on a heterogeneous machine the budget is the fast
        // cores only. See the header for why counting the E-cores loses time and memory.
        let base = topology.isHeterogeneous ? topology.performanceCoreCount : topology.logicalCoreCount
        return clamped(base, upperBound: upperBound)
    }

    /// The same decision, reduced for a machine that is too hot or has been asked to save
    /// power.
    ///
    /// Sustained compression is one of the few things a file manager does that will pin
    /// every core for minutes, which is exactly what pushes a fanless Mac into throttling
    /// - at which point more threads buy nothing and the machine gets slower for
    /// everything else the user is doing.
    ///
    /// SEPARATELY NAMED, not an overload. It was one, and the overload silently did not
    /// work: given two candidates that differ only in how many defaulted parameters they
    /// carry, Swift prefers the one with fewer, so `recommendedThreadCount()` and
    /// `recommendedThreadCount(upperBound: n)` both resolved to the plain version above and
    /// the backoff never ran. A caller had to name `thermalState:` or
    /// `isLowPowerModeEnabled:` explicitly to reach it - which is precisely what a caller
    /// wanting "the recommended count, whatever that means today" would never think to do.
    ///
    /// Which of the two to call is a real choice, not a detail. The Add dialog's `*  <auto>`
    /// entry should use the plain version: it is a number shown in a combo box, and a
    /// displayed default that changes between two openings of the same dialog because the
    /// Mac got warm is unexplainable. A job that has already started, or a background
    /// re-compress, should use this one.
    ///
    /// - Parameter thermalState: Injectable for testing; defaults to the live state.
    public static func throttledThreadCount(
        upperBound: Int? = nil,
        topology: CPUTopology = Self.topology,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
        isLowPowerModeEnabled: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    ) -> Int {
        let planned = recommendedThreadCount(upperBound: upperBound, topology: topology)

        var reduced = planned
        switch thermalState {
        case .nominal, .fair: break
        case .serious: reduced = planned / 2
        case .critical: reduced = 1
        @unknown default: reduced = planned / 2
        }

        if isLowPowerModeEnabled {
            reduced = min(reduced, max(planned / 2, 1))
        }

        return max(reduced, 1)
    }

    /// ``recommendedThreadCount(upperBound:topology:)`` as the engine's request type.
    ///
    /// Returned as an explicit `.count`, never `.automatic`: `.automatic` means "emit no
    /// `-mmt` and let 7-Zip decide", and 7-Zip would decide `hw.logicalcpu`, which is the
    /// number this file exists to avoid.
    public static func automaticThreadCount(
        upperBound: Int? = nil,
        topology: CPUTopology = Self.topology
    ) -> ThreadCount {
        .count(recommendedThreadCount(upperBound: upperBound, topology: topology))
    }

    /// The largest value the Add dialog offers in the thread combo.
    ///
    /// Unchanged from the original (ADD-17): the list runs to `min(hwThreads * 2,
    /// numAlgoThreadsMax)`. Oversubscribing beyond the core count is occasionally the
    /// right answer for a job that stalls on I/O, so the *user* keeps the option even
    /// though the automatic value never takes it.
    public static func maximumSelectableThreadCount(
        algorithmMaximum: Int,
        topology: CPUTopology = Self.topology
    ) -> Int {
        max(min(topology.logicalCoreCount * 2, algorithmMaximum), 1)
    }

    private static func clamped(_ value: Int, upperBound: Int?) -> Int {
        let ceiling = upperBound.map { max($0, 1) } ?? Int.max
        return max(min(value, ceiling), 1)
    }
}
