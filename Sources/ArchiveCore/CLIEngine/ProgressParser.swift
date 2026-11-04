// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Turns `StreamTokenizer` tokens into progress and per-item events.
//
// ## Two kinds of output
//
// `StreamTokenizer` has already done the hard part — recognising that `7zz` paints
// progress by *erasing in place with backspaces* rather than by emitting `\r`. What
// arrives here is therefore already split into:
//
// - `.transient` — a row captured just before it was erased. This is progress.
// - `.line` — a row terminated by a newline. This is permanent log output.
//
// ## Transient grammar
//
// With `-bsp1`/`-bsp2` the progress row looks like:
//
//      16% 9 + docs/manual.pdf
//      42% 1234 - photos/IMG_0001.heic
//      78%
//      99% 12
//
// That is: an optional percentage, an optional count of files processed so far, an
// optional single-character operation marker, and an optional path. Every field
// after the percentage can be absent, and early ticks are often bare (`  0%`). The
// parser therefore treats each field as optional and keeps the last known value for
// anything missing, so the UI never flickers back to zero between ticks.
//
// The leading field is not always a percentage. `7zz` can only print one when it
// knows the total, and during the scan the total is precisely what it is still
// measuring — so it prints a running size instead, and labels the slot the marker
// would occupy with a word:
//
//      0M Scan
//      0M Scan photos/2019
//
// That row is a phase indicator, not a member. Reading `0M Scan ` as a path put it
// in front of the user where a filename belongs, and `lastPath` is sticky, so it
// stayed there for the rest of the operation.
//
// ## Permanent grammar
//
// With `-bb3` each processed member gets its own newline-terminated line, prefixed
// by an operation marker:
//
//      - docs/manual.pdf        extracted / tested
//      + photos/IMG_0001.heic   added
//      U notes.txt              updated
//      . skipped.txt            skipped
//
// Lines that are not member lines (banner text, "Everything is Ok", the totals
// block) are passed through as `.log` so the Diagnostic Messages window can show
// exactly what the engine said.

import Foundation

/// Interprets tokenizer output for one running operation.
///
/// Stateful by design: it remembers the last percentage, file count and path so a
/// partial tick can be reported as a complete `ArchiveProgress`.
public struct ProgressParser: Sendable {
    // MARK: State

    /// The operation being reported on, used to label item events.
    public let operation: ArchiveOperation

    private var lastPercent: Int?
    private var lastFileCount: Int?
    private var lastPath: String?
    private var phase: ArchiveProgress.Phase

    public init(operation: ArchiveOperation) {
        self.operation = operation
        self.phase = .scanning
    }

    // MARK: Output

    /// What a token turned into.
    public enum Output: Sendable, Hashable {
        case progress(ArchiveProgress)
        case item(ArchiveItemEvent)
        case log(String)
        case warning(ArchiveWarning)
        /// The token carried nothing worth reporting.
        case ignored
    }

    // MARK: Entry point

    /// Interpret one token.
    public mutating func consume(_ token: StreamTokenizer.Token) -> Output {
        switch token {
        case .transient(let text):
            return consumeTransient(text)
        case .line(let text):
            return consumeLine(text)
        }
    }

    /// Interpret a batch, dropping the tokens that carried nothing.
    public mutating func consume(_ tokens: [StreamTokenizer.Token]) -> [Output] {
        var results: [Output] = []
        results.reserveCapacity(tokens.count)
        for token in tokens {
            let output = consume(token)
            if output != .ignored { results.append(output) }
        }
        return results
    }

    // MARK: Transient rows

    private mutating func consumeTransient(_ text: String) -> Output {
        guard let tick = Self.parseProgressRow(text) else { return .ignored }

        if let percent = tick.percent { lastPercent = percent }
        if let count = tick.fileCount { lastFileCount = count }
        if let path = tick.path, !path.isEmpty { lastPath = path }

        // Any percentage at all means scanning is over and work has begun.
        if lastPercent != nil { phase = .processing }

        return .progress(
            ArchiveProgress(
                phase: phase,
                fractionCompleted: lastPercent.map { Double($0) / 100.0 },
                processedItemCount: lastFileCount,
                currentItemPath: lastPath
            )
        )
    }

    // MARK: Permanent rows

    private mutating func consumeLine(_ text: String) -> Output {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .ignored }

        if let warning = Self.warning(from: trimmed) {
            return .warning(warning)
        }

        if let (action, path) = Self.parseMemberLine(text) {
            lastPath = path
            phase = .processing
            return .item(ArchiveItemEvent(action: action, path: path, rawMarker: text.first))
        }

        // "Everything is Ok" marks the tail of the run.
        if trimmed.caseInsensitiveCompare("everything is ok") == .orderedSame {
            phase = .finalising
        }

        return .log(text)
    }

    // MARK: Row grammars

    /// One decoded progress tick. Every field is optional.
    struct ProgressRow: Sendable, Hashable {
        var percent: Int?
        /// The `<n>M` size `7zz` prints in place of a percentage while the total is
        /// still unknown. Recognising it is what keeps it out of ``path``.
        var megabytes: Int?
        var fileCount: Int?
        var marker: Character?
        /// A word in the marker's slot, such as `Scan`. Names a phase rather than a
        /// member, so it is deliberately not surfaced as a path.
        var command: String?
        var path: String?
    }

    /// Decode ` 16% 9 + docs/manual.pdf` and its degenerate forms.
    static func parseProgressRow(_ text: String) -> ProgressRow? {
        var scanner = text[...]
        func dropSpaces() { scanner = scanner.drop(while: { $0 == " " || $0 == "\t" }) }

        dropSpaces()
        guard !scanner.isEmpty else { return nil }

        var row = ProgressRow()

        // Leading numeric field. A percentage when `7zz` knows the total, a running
        // size in `M` when it does not — which is every tick of the scan, since the
        // total is what the scan exists to measure.
        //
        // ASCII digits only. `Character.isNumber` is also true of `½`, `²` and every
        // non-Latin digit, none of which `Int(_:)` accepts, so a path starting with one
        // of those used to read as a percentage that then parsed to `nil`.
        let digits = scanner.prefix(while: Self.isASCIIDigit)
        guard !digits.isEmpty else { return nil }   // Not a progress row at all.
        switch scanner.dropFirst(digits.count).first {
        case "%":
            row.percent = Int(digits).map { min(max($0, 0), 100) }
            scanner = scanner.dropFirst(digits.count + 1)
        case "M":
            row.megabytes = Int(digits)
            scanner = scanner.dropFirst(digits.count + 1)
        default:
            // Leave the digits for the file-count field below.
            break
        }

        dropSpaces()

        // File count: a bare integer.
        let countDigits = scanner.prefix(while: Self.isASCIIDigit)
        if !countDigits.isEmpty {
            let after = scanner.dropFirst(countDigits.count).first
            if after == nil || after == " " {
                row.fileCount = Int(countDigits)
                scanner = scanner.dropFirst(countDigits.count)
            }
        }

        dropSpaces()

        // Operation marker: a single non-space character followed by a space.
        if let first = scanner.first,
           Self.markerCharacters.contains(first),
           scanner.dropFirst().first == " " {
            row.marker = first
            scanner = scanner.dropFirst(2)
        }

        // The same slot can hold a word instead: `7zz` writes `Scan` there while it
        // is still walking the input. Only consulted for the sizing form — in the
        // percentage form the marker is always present, so a word at this point is
        // the first word of a path that contains a space.
        if row.megabytes != nil, row.marker == nil {
            let word = scanner.prefix(while: \.isLetter)
            if !word.isEmpty, scanner.dropFirst(word.count).first == " " {
                row.command = String(word)
                scanner = scanner.dropFirst(word.count + 1)
            }
        }

        dropSpaces()

        if !scanner.isEmpty {
            row.path = String(scanner)
        }

        // A row with nothing but a percentage is still a valid tick.
        return row
    }

    /// Markers `7zz` uses in both progress rows and `-bb3` member lines.
    static let markerCharacters: Set<Character> = ["-", "+", "U", "T", ".", "="]

    /// `0`...`9` and nothing else — the only digits `7zz` prints and `Int(_:)` reads.
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// Decode a `-bb3` member line into an action and a path.
    static func parseMemberLine(_ text: String) -> (ArchiveItemEvent.Action, String)? {
        guard let marker = text.first, markerCharacters.contains(marker) else { return nil }
        let rest = text.dropFirst()
        // The marker must be followed by exactly one space, then a non-empty path.
        // This is what keeps "- - -" separator rows and "--" from being read as members.
        guard rest.first == " " else { return nil }
        let path = String(rest.dropFirst())
        guard !path.isEmpty, path.first != " ", !path.allSatisfy({ $0 == "-" }) else { return nil }

        let action: ArchiveItemEvent.Action
        switch marker {
        case "+": action = .added
        case "U", "=": action = .updated
        case ".": action = .skipped
        case "T": action = .tested
        case "-": action = .extracted
        default: action = .unknown
        }
        return (action, path)
    }

    /// Recognise a diagnostic line and classify it.
    static func warning(from trimmed: String) -> ArchiveWarning? {
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("warning:") {
            return ArchiveWarning(
                kind: .item,
                message: String(trimmed.dropFirst("warning:".count)).trimmingCharacters(in: .whitespaces)
            )
        }
        if lowered.hasPrefix("cannot open") || lowered.hasPrefix("can not open") {
            return ArchiveWarning(kind: .scan, message: trimmed)
        }
        if lowered.hasPrefix("skipping") {
            return ArchiveWarning(kind: .scan, message: trimmed)
        }
        return nil
    }
}
