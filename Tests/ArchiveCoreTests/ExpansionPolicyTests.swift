// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import Foundation
import Testing
@testable import ArchiveCore

/// `docs/SECURITY.md` §3 described byte tracking, absolute and ratio ceilings, and a prompt
/// before filling the disk — for three releases, while nothing implemented any of it.
@Suite("Expansion policy")
struct ExpansionPolicyTests {
    private func listing(
        _ sizes: [UInt64?], physical: UInt64?, names: [String]? = nil
    ) -> ArchiveListing {
        let entries = sizes.enumerated().map { index, size in
            ArchiveEntry(
                path: names?[index] ?? "member-\(index).bin", isDirectory: false, size: size
            )
        }
        return ArchiveListing(
            url: URL(fileURLWithPath: "/tmp/a.7z"), entries: entries, physicalSize: physical
        )
    }

    @Test("An ordinary archive raises nothing")
    func ordinaryArchivePasses() {
        let estimate = ExpansionPolicy.estimate(
            listing: listing([5_000_000, 3_000_000], physical: 4_000_000)
        )
        #expect(!estimate.warrantsConfirmation)
        #expect(estimate.declaredBytes == 8_000_000)
    }

    /// The classic bomb: a few hundred kilobytes claiming terabytes.
    @Test("A high ratio on a large result asks first")
    func bombIsCaught() {
        let estimate = ExpansionPolicy.estimate(
            listing: listing([4 * 1024 * 1024 * 1024], physical: 400_000)
        )
        #expect(estimate.exceedsRatioCeiling)
        #expect(estimate.warrantsConfirmation)
        #expect((estimate.ratio ?? 0) > 1000)
    }

    /// A huge factor on a tiny archive is nobody's problem, and warning about it would train
    /// people to click through the warning that matters.
    @Test("A high ratio on a small result is ignored")
    func smallHighRatioIsQuiet() {
        let estimate = ExpansionPolicy.estimate(
            listing: listing([50 * 1024 * 1024], physical: 1024)
        )
        #expect((estimate.ratio ?? 0) > ExpansionPolicy.ratioCeiling)
        #expect(!estimate.exceedsRatioCeiling, "below the size floor")
        #expect(!estimate.warrantsConfirmation)
    }

    @Test("A very large extraction asks regardless of ratio")
    func absoluteCeiling() {
        // Ratio barely above 1 — an honest, uncompressed, enormous archive.
        let huge = ExpansionPolicy.absoluteCeiling + 1
        let estimate = ExpansionPolicy.estimate(listing: listing([huge], physical: huge))
        #expect(estimate.exceedsAbsoluteCeiling)
        #expect(!estimate.exceedsRatioCeiling)
        #expect(estimate.warrantsConfirmation)
    }

    /// A hostile header can claim UInt64.max. Summing that must not wrap to a small number,
    /// which in a release build would silently disable the whole check.
    @Test("A declared size that overflows saturates instead of wrapping")
    func overflowSaturates() {
        let estimate = ExpansionPolicy.estimate(
            listing: listing([UInt64.max, UInt64.max, 1024], physical: 1024)
        )
        #expect(estimate.declaredBytes == UInt64.max)
        #expect(estimate.warrantsConfirmation)
    }

    @Test("Only the selected members are counted")
    func selectionIsRespected() {
        let names = ["keep.bin", "huge.bin"]
        let full = listing([1024, 8 * 1024 * 1024 * 1024], physical: 2048, names: names)
        let whole = ExpansionPolicy.estimate(listing: full)
        let partial = ExpansionPolicy.estimate(listing: full, selectedEntries: ["keep.bin"])
        #expect(whole.declaredBytes == 8 * 1024 * 1024 * 1024 + 1024)
        #expect(partial.declaredBytes == 1024)
        #expect(!partial.warrantsConfirmation)
    }

    @Test("Members with no declared size are counted as unknown, not as zero-risk")
    func unsizedEntriesAreReported() {
        let estimate = ExpansionPolicy.estimate(listing: listing([1024, nil, nil], physical: 512))
        #expect(estimate.unsizedEntryCount == 2)
        #expect(estimate.declaredBytes == 1024)
    }

    @Test("Directories do not contribute")
    func directoriesIgnored() {
        let entries = [
            ArchiveEntry(path: "dir", isDirectory: true, size: 4096),
            ArchiveEntry(path: "dir/file.bin", isDirectory: false, size: 1000),
        ]
        let listing = ArchiveListing(
            url: URL(fileURLWithPath: "/tmp/a.7z"), entries: entries, physicalSize: 500
        )
        #expect(ExpansionPolicy.estimate(listing: listing).declaredBytes == 1000)
    }

    @Test("Not enough free space asks first")
    func freeSpaceIsChecked() {
        var estimate = ExpansionPolicy.estimate(listing: listing([1000], physical: 900))
        #expect(!estimate.warrantsConfirmation)
        estimate.availableBytes = 500
        #expect(estimate.exceedsAvailableSpace)
        #expect(estimate.warrantsConfirmation)
    }
}
