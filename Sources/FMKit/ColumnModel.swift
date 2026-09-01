// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Which columns a panel shows, how wide, and how each cell renders.
//
// 7zFM varies the column set by folder type — a disk directory has no Packed Size or
// CRC, a `.7z` interior has both — and remembers per-type widths. This model holds
// that state; the table view is a dumb renderer over it.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(Support)   // module-guard
import Support
#endif

/// One column in a panel.
public struct PanelColumn: Sendable, Hashable, Identifiable {
    public var id: PropID { property }

    /// The property this column displays.
    public var property: PropID

    /// Header text. 7-Zip's own property name, so the UI matches the format's
    /// vocabulary rather than inventing new words.
    public var title: String { property.displayName }

    /// Width in points.
    public var width: Double

    /// How the value is drawn.
    public var alignment: Alignment

    public enum Alignment: String, Sendable, Hashable, Codable {
        case leading
        case trailing
    }

    public init(property: PropID, width: Double, alignment: Alignment) {
        self.property = property
        self.width = width
        self.alignment = alignment
    }
}

/// The columns for one folder type.
public struct ColumnModel: Sendable, Hashable {
    public private(set) var columns: [PanelColumn]

    public init(columns: [PanelColumn]) {
        self.columns = columns
    }

    /// Build the default column set for a folder's advertised properties.
    public init(available: [PropID]) {
        self.columns = available.map { property in
            PanelColumn(
                property: property,
                width: Self.defaultWidth(for: property),
                alignment: Self.defaultAlignment(for: property)
            )
        }
    }

    /// Sensible starting widths, chosen so a full timestamp and a 32-bit CRC fit
    /// without truncation at the default font size.
    public static func defaultWidth(for property: PropID) -> Double {
        switch property {
        case .name: 320
        case .size, .packedSize: 100
        case .modified, .created, .accessed: 150
        case .attributes: 100
        case .crc: 90
        case .method: 140
        case .block: 60
        case .encrypted: 80
        default: 110
        }
    }

    /// Numbers right-align so digits line up; everything else reads left.
    public static func defaultAlignment(for property: PropID) -> PanelColumn.Alignment {
        switch property {
        case .size, .packedSize, .crc, .block: .trailing
        default: .leading
        }
    }

    // MARK: Rendering

    /// The text to draw for one row in one column.
    ///
    /// Returns `""` rather than a placeholder for a missing value: 7zFM leaves the
    /// cell blank, and a dash or "n/a" reads as data.
    public static func displayText(for item: FolderItem, column: PropID) -> String {
        // Escaped, not raw: a member name is attacker-controlled, and a bidi override
        // makes `invoice<RLO>gnp.exe` render as `invoice exe.png`. See SECURITY.md §7.
        if column == .name { return PathNormalizer.displaySafe(item.name) }

        // The ".." row carries nothing but its name.
        if item.isParentRow { return "" }

        switch column {
        case .size, .packedSize:
            guard let value = item.numericValue(for: column) else { return "" }
            return groupedByteCount(value)

        case .modified, .created, .accessed:
            if let date = item.dateValue(for: column) {
                return date.formatted(date: .numeric, time: .shortened)
            }
            return item.properties[column] ?? ""

        case .crc:
            if let crc = item.entry?.crc {
                // 7-Zip prints CRC32 as 8 uppercase hex digits, zero-padded.
                return String(format: "%08X", crc)
            }
            return item.properties[column] ?? ""

        case .encrypted:
            guard let entry = item.entry, !entry.isDirectory else { return "" }
            return entry.isEncrypted ? "+" : ""

        default:
            return item.properties[column] ?? ""
        }
    }

    /// A raw byte count with locale digit grouping: `1,048,576`.
    ///
    /// This is 7zFM's Size column, not a human-readable "1.2 MB". The exact count
    /// matters in an archive manager — you compare Size against Packed Size, and
    /// rounded values make that comparison useless. `docs/DIVERGENCES.md` records the
    /// choice.
    ///
    /// Uses `FormatStyle` rather than `NumberFormatter`/`ByteCountFormatter` because
    /// those classes are not `Sendable` and a shared static instance of either is a
    /// data race under Swift 6.
    public static func groupedByteCount(_ value: UInt64) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}
