// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Parses `7zz l -slt` output into an `ArchiveListing`.
//
// ## The grammar
//
// `-slt` ("show large technical") prints a preamble describing the archive, then a
// run of per-entry property bags. The shape is:
//
//     7-Zip (z) 26.02 (arm64) : <upstream copyright banner> : 2026-06-25
//
//     Scanning the drive for archives:
//     1 file, 4096 bytes (4 KiB)
//
//     Listing archive: sample.7z
//
//     --
//     Path = sample.7z
//     Type = 7z
//     Physical Size = 4096
//     Headers Size = 210
//     Method = LZMA2:12 7zAES
//     Solid = +
//     Blocks = 1
//
//     ----------
//     Path = notes.txt
//     Size = 1024
//     Packed Size = 512
//     Modified = 2026-08-24 17:00:00
//     Attributes = A_ -rw-r--r--
//     CRC = 1A2B3C4D
//     Encrypted = +
//     Method = LZMA2:12 7zAES
//     Block = 0
//
//     Path = docs/
//     Folder = +
//     ...
//
// Three separators matter, and conflating them is the classic bug:
//
// - `--` (exactly two hyphens) opens the **archive** property bag.
// - `----------` (exactly ten hyphens) opens the **entries** section.
// - A **blank line** ends the current entry bag inside the entries section.
//
// So the ten-hyphen line appears once, not once per entry. Entries after the first
// are delimited by blank lines alone.
//
// ## Value grammar
//
// Each property line is `Name = Value`, split on the **first** occurrence of the
// three-character sequence `" = "`. Splitting on `"="` alone corrupts any value
// containing one, and splitting on the *last* occurrence corrupts any value
// containing `" = "` — which real paths do, e.g. `Path = weird = name.txt`.
//
// A property may have an empty value (`Comment = `), which is meaningful and is
// preserved as an empty string rather than dropped.
//
// Property names are used verbatim as `PropID` raw values, so an unrecognised
// property from a format we have never seen still round-trips into the column model.

import Foundation

/// Turns `7zz l -slt` text into a listing.
public struct SLTParser: Sendable {
    // MARK: Configuration

    /// The archive the output describes. Used for `ArchiveListing.url`.
    public var archiveURL: URL

    /// Zone the engine's timestamps are expressed in.
    ///
    /// `7zz` prints local wall-clock time with no zone marker, so this must match
    /// the environment the child ran in.
    public var timeZone: TimeZone

    public init(archiveURL: URL, timeZone: TimeZone = .current) {
        self.archiveURL = archiveURL
        self.timeZone = timeZone
    }

    // MARK: Separators

    /// Opens the archive property bag.
    static let archiveSeparator = "--"
    /// Opens the entries section.
    static let entriesSeparator = "----------"
    /// Splits `Name = Value`.
    static let assignment = " = "

    // MARK: Parsing

    /// Parse a complete `-slt` transcript.
    ///
    /// Never throws on unrecognised content: anything that does not fit the grammar
    /// becomes an `ArchiveWarning` on the listing, because a single odd line in a
    /// 200,000-entry archive must not cost the user the whole listing.
    public func parse(_ text: String) -> ArchiveListing {
        // Split on `isNewline`, not on the literal "\n".
        //
        // In Swift "\r\n" is a SINGLE Character — an extended grapheme cluster — so
        // `split(separator: "\n")` does not split CRLF text at all and silently
        // returns the whole transcript as one line. `isNewline` is true for the
        // "\r\n" cluster as well as for bare LF and CR, which is what we want.
        let lines = text
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        return parse(lines: lines)
    }

    /// Parse from pre-split lines, as the engine produces them.
    public func parse(lines: [String]) -> ArchiveListing {
        var state = State.preamble
        var archiveProperties: [PropID: String] = [:]
        var current: [PropID: String] = [:]
        var entries: [ArchiveEntry] = []
        var warnings: [ArchiveWarning] = []
        var errorLines: [String] = []

        // Close the entry bag under construction, if any.
        func flushEntry() {
            guard !current.isEmpty else { return }
            defer { current.removeAll(keepingCapacity: true) }
            guard let entry = ArchiveEntry(properties: current, timeZone: timeZone) else {
                warnings.append(
                    ArchiveWarning(
                        kind: .malformedOutput,
                        message: "Listing contained a property block with no usable Path; it was skipped."
                    )
                )
                return
            }
            entries.append(entry)
        }

        for rawLine in lines {
            // Strip only a trailing CR. Leading and trailing spaces are significant:
            // a filename may legitimately start or end with one.
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            switch state {
            case .preamble:
                if trimmed == Self.entriesSeparator {
                    state = .entries
                } else if trimmed == Self.archiveSeparator {
                    state = .archive
                } else if isDiagnostic(trimmed) {
                    errorLines.append(line)
                }

            case .archive:
                if trimmed == Self.entriesSeparator {
                    state = .entries
                } else if let (key, value) = Self.splitAssignment(line) {
                    archiveProperties[key] = value
                } else if isDiagnostic(trimmed) {
                    errorLines.append(line)
                }

            case .entries:
                if trimmed.isEmpty {
                    flushEntry()
                } else if let (key, value) = Self.splitAssignment(line) {
                    current[key] = value
                } else if isDiagnostic(trimmed) {
                    flushEntry()
                    errorLines.append(line)
                }
                // Anything else inside the entries section is noise and is ignored.
            }
        }
        flushEntry()

        for message in errorLines {
            warnings.append(ArchiveWarning(kind: .item, message: message))
        }

        return makeListing(
            archiveProperties: archiveProperties,
            entries: entries,
            warnings: warnings
        )
    }

    // MARK: Assembly

    private func makeListing(
        archiveProperties: [PropID: String],
        entries: [ArchiveEntry],
        warnings: [ArchiveWarning]
    ) -> ArchiveListing {
        func number(_ key: PropID) -> UInt64? {
            guard let raw = archiveProperties[key]?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty else { return nil }
            return UInt64(raw)
        }
        func flag(_ key: PropID) -> Bool {
            // 7-Zip renders booleans as "+" / "-".
            archiveProperties[key]?.trimmingCharacters(in: .whitespaces) == "+"
        }

        var format: ArchiveFormat?
        if let type = archiveProperties[PropID.fileType]?.trimmingCharacters(in: .whitespaces),
           !type.isEmpty {
            format = ArchiveFormat(rawValue: type.lowercased())
        }

        var blockCount: Int?
        if let blocks = number(PropID.numBlocks) {
            blockCount = Int(blocks)
        }

        // An archive is header-encrypted when 7-Zip could only list it after being
        // given a password. `-slt` signals it on the archive bag.
        let headerEncrypted = flag("Encrypted")

        return ArchiveListing(
            url: archiveURL,
            format: format,
            entries: entries,
            isSolid: flag(PropID.solid),
            volumes: volumeInfo(from: archiveProperties),
            isHeaderEncrypted: headerEncrypted,
            physicalSize: number(PropID.physicalSize),
            headersSize: number(PropID.headersSize),
            blockCount: blockCount,
            comment: archiveProperties[PropID.comment],
            properties: archiveProperties,
            warnings: warnings
        )
    }

    private func volumeInfo(from properties: [PropID: String]) -> ArchiveListing.VolumeInfo {
        var info = ArchiveListing.VolumeInfo()
        if let raw = properties["Volumes"]?.trimmingCharacters(in: .whitespaces),
           let count = Int(raw), count > 1 {
            info.isMultiVolume = true
            info.count = count
        }
        if let raw = properties["Volume Index"]?.trimmingCharacters(in: .whitespaces),
           let index = Int(raw) {
            info.index = index
            info.isMultiVolume = true
        }
        return info
    }

    // MARK: Line helpers

    /// Split `Name = Value` on the first `" = "`.
    ///
    /// Returns `nil` when the line is not an assignment at all.
    static func splitAssignment(_ line: String) -> (PropID, String)? {
        guard let range = line.range(of: assignment) else { return nil }
        let name = String(line[line.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // The value keeps its internal spacing; only the trailing CR was removed.
        let value = String(line[range.upperBound...])
        return (PropID(rawValue: name), value)
    }

    /// Lines `7zz` uses to report trouble, which we surface rather than discard.
    private func isDiagnostic(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("error")
            || lowered.hasPrefix("errors:")
            || lowered.hasPrefix("warning")
            || lowered.hasPrefix("warnings:")
            || lowered.hasPrefix("cannot open")
            || lowered.hasPrefix("can not open")
            || lowered.hasPrefix("unsupported method")
    }

    // MARK: State

    private enum State {
        /// Before any separator: banner, scan summary, "Listing archive:".
        case preamble
        /// After `--`: the archive's own properties.
        case archive
        /// After `----------`: repeated per-entry bags separated by blank lines.
        case entries
    }
}
