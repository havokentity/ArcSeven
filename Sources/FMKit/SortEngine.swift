// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The panel's sort comparator.
//
// Reimplements the ordering rules of upstream 7-Zip's CPP/7zip/UI/FileManager/
// PanelSort.cpp. The rules are unusual enough that "just call sorted(by:)" gets them
// wrong, and users notice immediately because the ordering is muscle memory:
//
// 1. The ".." parent row is ALWAYS first, in both directions. It is not a real item
//    and never participates in the comparison.
// 2. Folders sort before files, in both directions. Reversing the sort does NOT put
//    files above folders — it reverses the order *within* each group. This is the
//    rule most reimplementations get wrong.
// 3. Within a group, compare on the active column.
// 4. Name comparison is case-insensitive and NATURAL: "file2" precedes "file10".
// 5. Ties fall back to the name, ascending, so the order is deterministic and a
//    re-sort on another column never shuffles equal rows arbitrarily.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// Which direction a column is sorted in.
public enum SortDirection: String, Sendable, Hashable, Codable {
    case ascending
    case descending

    public var reversed: Self { self == .ascending ? .descending : .ascending }
}

/// A column plus a direction.
public struct SortDescriptor: Sendable, Hashable, Codable {
    public var column: PropID
    public var direction: SortDirection

    public init(column: PropID = .name, direction: SortDirection = .ascending) {
        self.column = column
        self.direction = direction
    }
}

/// Orders panel rows the way 7zFM does.
public enum SortEngine {
    /// Sort a folder listing.
    ///
    /// - Parameters:
    ///   - items: the rows, in any order.
    ///   - descriptor: the active column and direction.
    ///   - parentItem: the ".." row, kept first regardless of direction.
    public static func sort(
        _ items: [FolderItem],
        by descriptor: SortDescriptor,
        parentItem: FolderItem? = nil
    ) -> [FolderItem] {
        let body = items.filter { !$0.isParentRow }
        let sorted = body.sorted { compare($0, $1, descriptor) }
        guard let parentItem else { return sorted }
        return [parentItem] + sorted
    }

    /// The comparator. `true` when `lhs` sorts before `rhs`.
    static func compare(_ lhs: FolderItem, _ rhs: FolderItem, _ descriptor: SortDescriptor) -> Bool {
        // Rule 2: folders always above files, regardless of direction.
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }

        let ordering = order(lhs, rhs, by: descriptor.column)
        switch ordering {
        case .orderedSame:
            // Rule 5: deterministic tiebreak on name, always ascending.
            return naturalCompare(lhs.name, rhs.name) == .orderedAscending
        case .orderedAscending:
            return descriptor.direction == .ascending
        case .orderedDescending:
            return descriptor.direction == .descending
        }
    }

    /// Compare two rows on one column, direction-independent.
    static func order(_ lhs: FolderItem, _ rhs: FolderItem, by column: PropID) -> ComparisonResult {
        switch column {
        case .name, .path:
            return naturalCompare(lhs.name, rhs.name)

        case .size, .packedSize:
            return compareNumbers(lhs.numericValue(for: column), rhs.numericValue(for: column))

        case .modified, .created, .accessed:
            return compareDates(lhs.dateValue(for: column), rhs.dateValue(for: column))

        default:
            let lhsText = lhs.properties[column] ?? ""
            let rhsText = rhs.properties[column] ?? ""
            // Numeric-looking columns compare numerically, so "10" is not before "9".
            if let x = UInt64(lhsText), let y = UInt64(rhsText) { return compareNumbers(x, y) }
            return naturalCompare(lhsText, rhsText)
        }
    }

    // MARK: Primitives

    /// Case- and diacritic-insensitive natural ordering.
    ///
    /// `.numeric` is what makes "file2" precede "file10". `.forcedOrdering` keeps the
    /// comparison stable for strings that differ only by case, so equal-ignoring-case
    /// names still have a fixed order rather than an arbitrary one.
    static func naturalCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric, .forcedOrdering, .widthInsensitive],
            range: nil,
            locale: .current
        )
    }

    /// Compare optionals so that "no value" sorts last in ascending order.
    ///
    /// A directory has no size and must not be treated as size zero, or every folder
    /// would clump at one end of a size sort and look like a bug.
    static func compareNumbers(_ lhs: UInt64?, _ rhs: UInt64?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (left?, right?):
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
    }

    static func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (left?, right?):
            left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
        }
    }
}

// MARK: - Row accessors

extension FolderItem {
    /// `true` for the synthetic ".." row.
    public var isParentRow: Bool { name == ".." }

    /// The column's value as a number, when it has one.
    public func numericValue(for column: PropID) -> UInt64? {
        if let entry {
            switch column {
            // A directory has no size of its own. Reporting the stored 0 would both
            // render as "0" in the panel and clump every folder at one end of a
            // size sort, which reads as a bug.
            case .size: return entry.isDirectory ? nil : entry.size
            case .packedSize: return entry.isDirectory ? nil : entry.packedSize
            default: break
            }
        }
        guard let raw = properties[column], !raw.isEmpty else { return nil }
        return UInt64(raw)
    }

    /// The column's value as a date, when it has one.
    public func dateValue(for column: PropID) -> Date? {
        guard let entry else { return nil }
        switch column {
        case .modified: return entry.modified
        case .created: return entry.created
        case .accessed: return entry.accessed
        default: return nil
        }
    }
}
