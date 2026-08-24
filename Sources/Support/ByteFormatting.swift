// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Byte counts, in the two spellings the application needs.
//
// Everything here goes through FormatStyle rather than a formatter object. That is not a
// style preference: NumberFormatter and ByteCountFormatter are reference types with
// mutable state and are not Sendable, so the usual `static let formatter = ...` does not
// compile under Swift 6 strict concurrency, and creating one per call is measurably
// expensive in a list that renders thousands of rows. `value.formatted(...)` has neither
// problem - the style is a value, and Foundation caches the machinery behind it.
//
// Both functions are locale-aware, so the grouping separator is the user's, not a hard
// space, and the unit names are localised by the system.

import Foundation

/// Byte-count rendering.
public enum ByteFormatting {

    /// The exact count with digit grouping: `1,048,576` in en-US, `1 048 576` in fr-FR,
    /// `10,48,576` in en-IN, whose grouping is not in threes at all. The separator and
    /// the grouping *shape* are the user's, which is also what the Windows original does
    /// - it formats through the user locale - so an Indian-locale user sees the same
    /// lakh-grouped number in both applications.
    ///
    /// This is the panel's Size and Packed Size spelling, and the one the Windows original
    /// uses everywhere a byte count appears in a list. Exact, because a file manager's
    /// size column is a fact the user may be comparing digit by digit, and a rounded
    /// "1 MB" makes two different files look identical.
    ///
    /// - Note: `FMKit.ColumnModel.groupedByteCount` renders the panel's own cells with the
    ///   identical style. FMKit does not depend on Support, so the call is spelled twice
    ///   rather than importing one module into the other for a single line; if the two
    ///   ever disagree, this one is the definition.
    public static func groupedBytes(_ value: UInt64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// The same, for a signed count.
    public static func groupedBytes(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// A short, human-sized count: `1.2 MB`.
    ///
    /// `.file` style, which is decimal (1 kB = 1000 bytes) and therefore agrees with the
    /// Finder's Get Info window. It deliberately does *not* agree with 7-Zip's own
    /// dialogs, which label binary multiples `KB`/`MB`/`GB`; those readouts are
    /// reproduced verbatim where fidelity requires it (dictionary sizes, the memory
    /// readouts - FIDELITY ADD-14 and ADD-20) by their own renderers. This one is for the
    /// places ArcSeven speaks to a Mac user in Mac units: status bars, summaries, and the
    /// "extracting 1.2 GB" line.
    public static func humanBytes(_ value: UInt64) -> String {
        // Int64(clamping:) rather than Int64(): a corrupt or hostile archive can declare a
        // size of UInt64.max, and a size field is not worth a trap.
        Int64(clamping: value).formatted(.byteCount(style: .file))
    }

    /// The same, for a signed count.
    public static func humanBytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    /// A human-sized count for a value the archive did not declare.
    ///
    /// 7-Zip prints `?` for an undefined size rather than `0`, because the two mean very
    /// different things to someone deciding whether an extraction will fit (ADD-20).
    public static func humanBytes(_ value: UInt64?, undefined: String = "?") -> String {
        guard let value else { return undefined }
        return humanBytes(value)
    }
}
