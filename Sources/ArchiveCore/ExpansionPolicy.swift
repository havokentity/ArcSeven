// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// How much an archive claims it will expand to, and whether that is worth stopping for.
//
// A few hundred kilobytes can expand to petabytes, and nesting multiplies it. `docs/SECURITY.md`
// §3 described exactly this guard for three releases while nothing implemented it — extraction
// ran to completion or to a full disk, whichever came first.
//
// # Estimated, not measured
//
// The figures come from the archive's own header, which is attacker-controlled: a hostile
// archive can understate every size and this check will wave it through. That is a real
// limitation and the reason this is a *warning* rather than a guarantee. It still catches the
// case that actually occurs — a bomb built by the standard recipe, whose headers are honest
// because the compressor wrote them — and it costs nothing, because the listing has already
// been fetched by the time extraction is being set up.
//
// A true guarantee needs live byte accounting with the child killed mid-write, which the
// subprocess engine cannot do without polling the destination. That is worth building; this
// is worth having in the meantime, and `docs/SECURITY.md` now says which one is in place.
//
// # Warn, never forbid
//
// Legitimate archives reach absurd ratios: a sparse disk image, a log full of one repeated
// line, a tarball of zeros. Refusing them would be wrong, so crossing a ceiling asks rather
// than blocks, and says what the numbers are so the answer can be informed.

import Foundation

/// What an archive says extraction will cost, and whether that warrants asking first.
public struct ExpansionEstimate: Sendable, Hashable {
    /// Total uncompressed size the archive declares for the members being extracted.
    public var declaredBytes: UInt64
    /// The archive's own size on disk, when known.
    public var archiveBytes: UInt64?
    /// Free space on the destination volume, when it could be determined.
    public var availableBytes: UInt64?
    /// Members whose size the archive did not report, so `declaredBytes` understates.
    public var unsizedEntryCount: Int

    /// `declaredBytes / archiveBytes`, or `nil` when the archive's size is unknown or zero.
    public var ratio: Double? {
        guard let archiveBytes, archiveBytes > 0 else { return nil }
        return Double(declaredBytes) / Double(archiveBytes)
    }

    public var exceedsAbsoluteCeiling: Bool {
        declaredBytes > ExpansionPolicy.absoluteCeiling
    }

    public var exceedsRatioCeiling: Bool {
        guard let ratio else { return false }
        // Small archives reach silly ratios honestly — a 1 KB file of zeros is 1000:1 and
        // expands to a megabyte, which is nobody's problem. The ratio only matters once the
        // result is large enough to hurt.
        return ratio > ExpansionPolicy.ratioCeiling && declaredBytes > ExpansionPolicy.ratioFloor
    }

    /// The destination cannot hold what the archive says it will produce.
    public var exceedsAvailableSpace: Bool {
        guard let availableBytes else { return false }
        return declaredBytes > availableBytes
    }

    /// Whether the user should be asked before this runs.
    public var warrantsConfirmation: Bool {
        exceedsAbsoluteCeiling || exceedsRatioCeiling || exceedsAvailableSpace
    }
}

public enum ExpansionPolicy: Sendable {
    /// Above this, ask regardless of ratio. Chosen to sit above any plausible everyday
    /// archive and below anything that fills a modern disk unnoticed.
    public static let absoluteCeiling: UInt64 = 64 * 1024 * 1024 * 1024

    /// Expansion factor that counts as suspicious, once the result is also large.
    public static let ratioCeiling: Double = 300

    /// Below this the ratio is ignored: a huge factor on a tiny archive is harmless.
    public static let ratioFloor: UInt64 = 1024 * 1024 * 1024

    /// Estimate the cost of extracting `entries` (or the whole archive when `nil`).
    ///
    /// - Parameters:
    ///   - listing: the archive's listing, already fetched by the caller.
    ///   - selectedEntries: archive-relative member paths, or `nil` for everything.
    ///   - destination: where the files are going, used to read free space.
    public static func estimate(
        listing: ArchiveListing,
        selectedEntries: [String]? = nil,
        destination: URL? = nil
    ) -> ExpansionEstimate {
        let wanted: Set<String>? = selectedEntries.map(Set.init)

        var declared: UInt64 = 0
        var unsized = 0
        for entry in listing.entries where !entry.isDirectory {
            if let wanted, !wanted.contains(entry.path) { continue }
            if let size = entry.size {
                // Saturating: a hostile header can claim UInt64.max and overflow the sum,
                // which in a release build wraps to a small number and disables the check.
                declared = declared.addingReportingOverflow(size).overflow
                    ? UInt64.max
                    : declared + size
            } else {
                unsized += 1
            }
        }

        return ExpansionEstimate(
            declaredBytes: declared,
            archiveBytes: listing.physicalSize ?? fileSize(of: listing.url),
            availableBytes: destination.flatMap(availableCapacity(at:)),
            unsizedEntryCount: unsized
        )
    }

    private static func fileSize(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init)
    }

    /// Free space on the volume holding `url`, walking up to the nearest existing ancestor
    /// because the destination directory itself may not have been created yet.
    private static func availableCapacity(at url: URL) -> UInt64? {
        var candidate = url.standardizedFileURL
        let manager = FileManager.default
        while !manager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
        let values = try? candidate.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
    }
}
