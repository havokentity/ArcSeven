// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Quarantine propagation, the Trash error mapping, the thread budget and byte rendering.
//
// Nothing here touches the user's real Trash: the Trash cases exercise the failure path,
// which is the half with logic in it. Everything else runs against a temporary directory.

import Foundation
import Testing
import ArchiveCore
@testable import Support

@Suite("Support services")
struct SupportServicesTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let manager = FileManager()
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenSupport-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try body(root)
    }

    /// A plausible value: flags, hex timestamp, the agent that downloaded it, and the
    /// LaunchServices event UUID.
    private let quarantineValue = "0081;6613a2c0;Safari;1D5A9A28-1AB0-4F5E-9B4A-3F2B1C4D5E6F"

    // MARK: - Quarantine

    @Test("A file with no quarantine attribute reads as nil, not as an error")
    func absentQuarantine() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("plain.txt")
            try Data("x".utf8).write(to: file)
            #expect(try Quarantine.rawValue(of: file) == nil)
            #expect(try Quarantine.info(of: file) == nil)
            #expect(!Quarantine.isQuarantined(file))
        }
    }

    @Test("The four fields parse, and the raw value is kept verbatim")
    func quarantineParsing() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("download.7z")
            try Data("x".utf8).write(to: file)
            try Quarantine.apply(Data(quarantineValue.utf8), to: file)

            let info = try #require(try Quarantine.info(of: file))
            #expect(info.flags == 0x0081)
            #expect(info.agentName == "Safari")
            #expect(info.eventIdentifier?.uuidString == "1D5A9A28-1AB0-4F5E-9B4A-3F2B1C4D5E6F")
            #expect(info.timestamp == Date(timeIntervalSince1970: TimeInterval(0x6613_A2C0)))
            // The bytes that get propagated are the bytes that were read, whatever the
            // parse made of them.
            #expect(info.rawValue == quarantineValue)
        }
    }

    @Test("A malformed value still reads, because it is only ever displayed")
    func malformedQuarantineValue() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("odd.txt")
            try Data("x".utf8).write(to: file)
            try Quarantine.apply(Data("not-a-quarantine-value".utf8), to: file)

            let info = try #require(try Quarantine.info(of: file))
            #expect(info.rawValue == "not-a-quarantine-value")
            #expect(info.flags == nil)
            #expect(info.timestamp == nil)
        }
    }

    /// The point of the whole file: what Gatekeeper reads on the archive has to end up on
    /// what came out of it.
    @Test("Quarantine propagates from the archive to an extracted file")
    func quarantinePropagates() throws {
        try withTemporaryDirectory { root in
            let archive = root.appendingPathComponent("download.7z")
            try Data("x".utf8).write(to: archive)
            try Quarantine.apply(Data(quarantineValue.utf8), to: archive)

            let extracted = root.appendingPathComponent("payload.app")
            try Data("y".utf8).write(to: extracted)

            #expect(try Quarantine.propagate(from: archive, to: extracted))
            #expect(try Quarantine.info(of: extracted)?.rawValue == quarantineValue)
        }
    }

    @Test("An unquarantined archive propagates nothing")
    func nothingToPropagate() throws {
        try withTemporaryDirectory { root in
            let archive = root.appendingPathComponent("local.7z")
            try Data("x".utf8).write(to: archive)
            let extracted = root.appendingPathComponent("payload.txt")
            try Data("y".utf8).write(to: extracted)

            #expect(try Quarantine.propagate(from: archive, to: extracted) == false)
            #expect(!Quarantine.isQuarantined(extracted))
        }
    }

    /// Replacing a value the system already wrote can only ever make a file look less
    /// suspicious than the system decided it was, so it takes an explicit opt-in.
    @Test("An existing quarantine value is not clobbered by default")
    func existingValueWins() throws {
        try withTemporaryDirectory { root in
            let archive = root.appendingPathComponent("download.7z")
            try Data("x".utf8).write(to: archive)
            try Quarantine.apply(Data(quarantineValue.utf8), to: archive)

            let extracted = root.appendingPathComponent("payload.txt")
            try Data("y".utf8).write(to: extracted)
            try Quarantine.apply(Data("0002;0;Mail;".utf8), to: extracted)

            try Quarantine.propagate(from: archive, to: extracted)
            #expect(try Quarantine.info(of: extracted)?.agentName == "Mail")

            try Quarantine.apply(Data(quarantineValue.utf8), to: extracted, overwritingExisting: true)
            #expect(try Quarantine.info(of: extracted)?.agentName == "Safari")
        }
    }

    @Test("Propagation covers a whole extracted tree")
    func quarantinePropagatesToTree() throws {
        try withTemporaryDirectory { root in
            let manager = FileManager()
            let archive = root.appendingPathComponent("download.7z")
            try Data("x".utf8).write(to: archive)
            try Quarantine.apply(Data(quarantineValue.utf8), to: archive)

            let tree = root.appendingPathComponent("out", isDirectory: true)
            let nested = tree.appendingPathComponent("bin", isDirectory: true)
            try manager.createDirectory(at: nested, withIntermediateDirectories: true)
            let leaf = nested.appendingPathComponent("tool")
            try Data("z".utf8).write(to: leaf)

            let marked = try Quarantine.propagate(from: archive, toTreeAt: tree)
            #expect(marked >= 3)
            #expect(Quarantine.isQuarantined(leaf))
            #expect(Quarantine.isQuarantined(nested))
            #expect(Quarantine.isQuarantined(tree))
        }
    }

    // MARK: - Trash

    @Test("Trashing something that is not there reports it as missing, not as a failure")
    func trashingMissingItem() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenGone-\(UUID().uuidString).txt")

        #expect(throws: TrashError.notFound(path: missing.path)) {
            try TrashService.trash(missing)
        }
    }

    /// Stopping at the first failure leaves the user with a half-deleted selection and no
    /// account of what happened, which is what the original's error list exists to avoid.
    @Test("A batch reports every item rather than stopping at the first failure")
    func batchCarriesOn() throws {
        let first = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenGone-\(UUID().uuidString).txt")
        let second = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenGone-\(UUID().uuidString).txt")

        let summary = TrashService.trash([first, second])
        #expect(summary.trashed.isEmpty)
        #expect(summary.failures.count == 2)
        #expect(!summary.isCompleteSuccess)
        #expect(summary.failures.map(\.source) == [first, second])
        #expect(summary.failures.allSatisfy { $0.error.errorDescription?.isEmpty == false })
    }

    // MARK: - Threads

    /// The whole reason this file exists: on a heterogeneous machine the budget is the
    /// fast cores, not every core.
    @Test("Apple silicon gets the P-core count, Intel gets every logical core")
    func threadBudgetIgnoresEfficiencyCores() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(ThreadPlanner.recommendedThreadCount(topology: silicon) == 12)

        let intel = CPUTopology(
            performanceCoreCount: 8, efficiencyCoreCount: 0,
            logicalCoreCount: 8, physicalCoreCount: 4
        )
        #expect(ThreadPlanner.recommendedThreadCount(topology: intel) == 8)
    }

    @Test("The algorithm's own ceiling wins, and the floor is one thread")
    func threadBudgetClamps() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(ThreadPlanner.recommendedThreadCount(upperBound: 2, topology: silicon) == 2)
        #expect(ThreadPlanner.recommendedThreadCount(upperBound: 64, topology: silicon) == 12)
        #expect(ThreadPlanner.recommendedThreadCount(upperBound: 0, topology: silicon) == 1)
    }

    @Test("Heat and Low Power Mode reduce the budget but never to zero")
    func thermalBackoff() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(
            ThreadPlanner.throttledThreadCount(
                topology: silicon, thermalState: .fair, isLowPowerModeEnabled: false
            ) == 12
        )
        #expect(
            ThreadPlanner.throttledThreadCount(
                topology: silicon, thermalState: .serious, isLowPowerModeEnabled: false
            ) == 6
        )
        #expect(
            ThreadPlanner.throttledThreadCount(
                topology: silicon, thermalState: .critical, isLowPowerModeEnabled: false
            ) == 1
        )
        #expect(
            ThreadPlanner.throttledThreadCount(
                topology: silicon, thermalState: .nominal, isLowPowerModeEnabled: true
            ) == 6
        )
    }

    /// The backoff used to be an overload of `recommendedThreadCount`, and Swift resolved
    /// the argument-free call to the *other* one — the caller who wrote the obvious thing
    /// got no backoff and no diagnostic. Naming it separately is the fix; this asserts the
    /// two are genuinely different functions rather than one shadowing the other.
    @Test("Throttling is a distinct call, and is a no-op on a cool machine")
    func throttlingIsOptIn() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(
            ThreadPlanner.throttledThreadCount(
                topology: silicon, thermalState: .nominal, isLowPowerModeEnabled: false
            ) == ThreadPlanner.recommendedThreadCount(topology: silicon)
        )
        // Same call shape as the plain version, so the trap would reappear as a mismatch.
        #expect(
            ThreadPlanner.throttledThreadCount(
                upperBound: 4, topology: silicon, thermalState: .critical,
                isLowPowerModeEnabled: false
            ) == 1
        )
    }

    /// `.automatic` would mean "emit no -mmt and let 7-Zip pick hw.logicalcpu", which is
    /// the number the planner exists to avoid, so the request always carries a count.
    @Test("The engine request is an explicit count, never automatic")
    func automaticThreadCountIsExplicit() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(ThreadPlanner.automaticThreadCount(topology: silicon) == ThreadCount.count(12))
    }

    /// ADD-17: the user keeps the oversubscription the automatic value never takes.
    @Test("The thread combo still offers up to twice the logical core count")
    func maximumSelectableThreadCount() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(ThreadPlanner.maximumSelectableThreadCount(algorithmMaximum: 64, topology: silicon) == 32)
        #expect(ThreadPlanner.maximumSelectableThreadCount(algorithmMaximum: 8, topology: silicon) == 8)
        #expect(ThreadPlanner.maximumSelectableThreadCount(algorithmMaximum: 0, topology: silicon) == 1)
    }

    @Test("The detected topology is self-consistent on whatever machine runs the suite")
    func detectedTopologyIsSane() {
        let topology = ThreadPlanner.topology
        #expect(topology.logicalCoreCount >= 1)
        #expect(topology.physicalCoreCount >= 1)
        #expect(topology.performanceCoreCount >= 1)
        #expect(topology.performanceCoreCount + topology.efficiencyCoreCount <= topology.logicalCoreCount)
        #expect(!topology.summary.isEmpty)

        let planned = ThreadPlanner.recommendedThreadCount()
        #expect(planned >= 1)
        #expect(planned <= topology.logicalCoreCount)
        if topology.isHeterogeneous {
            #expect(planned == topology.performanceCoreCount)
            #expect(planned < topology.logicalCoreCount)
        }
    }

    /// The previous test passes on the FALLBACK path — an Apple silicon Mac where
    /// `sysctlbyname` silently failed would report `performanceCoreCount == logicalCoreCount`
    /// and satisfy every assertion above while quietly handing compression every E-core.
    /// That is the exact failure ADD-18 is meant to prevent, so it is checked against a
    /// second, independent reader of the same kernel nodes rather than against itself.
    @Test("Detection agrees with the kernel's own hw.perflevel* nodes")
    func detectionMatchesSysctl() {
        let topology = CPUTopology.detect()

        #expect(topology.logicalCoreCount == Self.sysctlCommand("hw.logicalcpu"))
        #expect(topology.physicalCoreCount == Self.sysctlCommand("hw.physicalcpu"))

        // Absent on Intel and inside some virtual machines, where homogeneous is the right
        // answer and `hw.logicalcpu` is the Windows behaviour.
        guard let performance = Self.sysctlCommand("hw.perflevel0.logicalcpu"),
              let efficiency = Self.sysctlCommand("hw.perflevel1.logicalcpu") else {
            #expect(!topology.isHeterogeneous)
            #expect(topology.performanceCoreCount == topology.logicalCoreCount)
            #expect(topology.efficiencyCoreCount == 0)
            return
        }

        // perflevel0 is the FAST cluster. Reading the two the wrong way round would still
        // produce a plausible-looking heterogeneous topology, so the direction is asserted.
        #expect(topology.performanceCoreCount == performance)
        #expect(topology.efficiencyCoreCount == efficiency)
        #expect(topology.isHeterogeneous)
        #expect(ThreadPlanner.recommendedThreadCount(topology: topology) == performance)
    }

    @Test("The hardware hint names both clusters on a heterogeneous machine")
    func topologySummaryShape() {
        let silicon = CPUTopology(
            performanceCoreCount: 12, efficiencyCoreCount: 4,
            logicalCoreCount: 16, physicalCoreCount: 16
        )
        #expect(silicon.summary == "12P + 4E (16 threads)")

        let intel = CPUTopology(
            performanceCoreCount: 8, efficiencyCoreCount: 0,
            logicalCoreCount: 8, physicalCoreCount: 4
        )
        #expect(intel.summary == "8 threads")
    }

    /// `/usr/sbin/sysctl -n`, i.e. not `sysctlbyname`: a test that read the node the same way
    /// the code under test does would agree with it even when both are wrong.
    private static func sysctlCommand(_ name: String) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Bytes

    /// Locale-independent assertions only: the grouping separator and even the grouping
    /// *shape* belong to the user's locale, which is the point of using FormatStyle.
    @Test("Grouped counts are exact")
    func groupedBytes() {
        #expect(ByteFormatting.groupedBytes(UInt64(0)) == "0")
        #expect(ByteFormatting.groupedBytes(UInt64(999)) == "999")
        // Grouping is on: the grouped form differs from the ungrouped one. Asserting the
        // separator itself would only assert the test machine's locale.
        #expect(
            ByteFormatting.groupedBytes(UInt64(1_048_576))
                != UInt64(1_048_576).formatted(.number.grouping(.never))
        )
        #expect(ByteFormatting.groupedBytes(Int64(1_048_576)) == ByteFormatting.groupedBytes(UInt64(1_048_576)))
    }

    @Test("Human counts are short, and an undeclared size is not zero")
    func humanBytes() {
        #expect(!ByteFormatting.humanBytes(UInt64(0)).isEmpty)
        // Shorter than the exact form, without asserting a unit name that is localised.
        #expect(
            ByteFormatting.humanBytes(UInt64(1_500_000)).count
                < ByteFormatting.groupedBytes(UInt64(1_500_000)).count
        )
        #expect(ByteFormatting.humanBytes(nil) == "?")
        #expect(ByteFormatting.humanBytes(nil, undefined: "-") == "-")
        // A hostile archive can declare UInt64.max; a size field is not worth a trap.
        #expect(!ByteFormatting.humanBytes(UInt64.max).isEmpty)
    }
}
