// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Per-folder-kind panel layout: which columns, how wide, sorted how.
//
// The surprising part of 7zFM, and the reason this store exists at all, is that panel
// layout is remembered **per folder type, not per panel and not globally**. Upstream
// keys the saved layout on `GetFolderTypeID()` and stores it under
// `FM\Columns\<TypeID>`, re-reading it in `InitColumns` only when the type ID changes
// (FIDELITY.md COL-15; upstream `CPP/7zip/UI/FileManager/ViewSettings.cpp`, whose
// `CListViewInfo` carries the column vector plus its sort column and direction).
//
// That is not a nicety. The column SETS genuinely differ — a disk folder has no
// Packed Size, no CRC and no Method column at all, because `FSFolder` never advertises
// those properties, while a `.7z` interior advertises all three (COL-04, COL-09). One
// global layout would have to either hide columns that exist or show columns that can
// never have a value. So: widen Name inside an archive and it stays wide inside every
// archive, while the disk folder keeps its own width. Sort a disk folder by Modified
// and stepping into a `.zip` returns you to whatever that `.zip` view was last sorted
// by. Users rely on this without ever noticing it is happening.
//
// **Divergence from upstream's key granularity.** Windows' type ID is per-*handler*
// (`"7z"`, `"zip"`, `"FSFolder"`, …), so a `.zip` and a `.7z` remember separate
// layouts. ArcSeven keys on `FolderKind.rawValue`, so all archive interiors share one
// layout. The archive column set here is derived from what `7zz l -slt` actually
// emitted for the opened archive rather than from a per-format handler table, which
// makes a per-format key mostly meaningless — and `.7z` and `.zip` advertise nearly
// the same properties anyway. Widening the key later is a storage-format change, not
// an API change: only `storageKey(for:)` moves.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// Remembers each folder kind's column layout and sort order.
///
/// ## Concurrency
///
/// `@unchecked Sendable` over an `NSLock`, matching the other two stores. Columns and
/// sort share one stored blob per kind — as they share one registry subkey upstream —
/// so `setColumns(_:for:)` has to read the blob, replace one half and write it back
/// without a concurrent `setSort(_:for:)` landing in between and losing its edit. The
/// lock makes that read-modify-write atomic; the compiler cannot verify it, hence
/// `@unchecked`.
public final class PanelPreferences: @unchecked Sendable {
    /// Prefix of the per-kind key. Mirrors the Windows subkey `FM\Columns\<TypeID>`
    /// (FIDELITY.md PST-12), with `.` where the registry has `\`.
    public static let keyPrefix = "FM.Columns."

    /// Floor applied to any width read back from the domain.
    ///
    /// Defensive, not cosmetic: the value is user-editable through `defaults write`
    /// and a `0` would produce a column that exists, can be sorted on and can be
    /// dragged to, yet is invisible — which reads as data loss rather than as a bad
    /// setting.
    public static let minimumColumnWidth: Double = 16

    private let defaults: UserDefaults
    private let keyPrefix: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = PanelPreferences.keyPrefix
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    /// The `UserDefaults` key holding one kind's layout, e.g. `FM.Columns.archive`.
    public func storageKey(for kind: FolderKind) -> String { keyPrefix + kind.rawValue }

    // MARK: Columns

    /// The remembered visible columns for a kind, in display order, or `nil` when the
    /// user has never touched this kind's layout.
    ///
    /// `nil` means "no opinion stored", and the caller must fall back to
    /// `ColumnModel(available:)`. It deliberately does not mean "no columns": an empty
    /// array is a legitimate stored state that has to survive a round trip, otherwise
    /// hiding every column but Name and relaunching would resurrect the defaults.
    public func columns(for kind: FolderKind) -> [PanelColumn]? {
        guard let stored = load(kind), let columns = stored.columns else { return nil }
        return Self.decode(columns)
    }

    /// Remember a kind's visible columns and their order and widths.
    ///
    /// Passing `nil` forgets the column layout while leaving the sort descriptor
    /// alone — that is the "reset columns to defaults" the header context menu needs,
    /// and it must not silently re-sort the panel.
    ///
    /// Only VISIBLE columns are stored, and their order in the array is their order on
    /// screen. Upstream keeps hidden columns too, each with an `IsVisible` flag, which
    /// lets a hidden column remember the width it had before it was hidden; here it
    /// comes back at `ColumnModel.defaultWidth(for:)`. The simpler shape is worth a
    /// re-drag of a re-shown column, and it means the stored array reads exactly like
    /// the table.
    public func setColumns(_ columns: [PanelColumn]?, for kind: FolderKind) {
        update(kind) { layout in
            layout.columns = columns.map(Self.encode)
        }
    }

    // MARK: Sort

    /// The remembered sort column and direction, or `nil` when none is stored.
    ///
    /// A stored sort on a column this folder no longer advertises is returned as-is;
    /// resolving that is the panel's job, and it already has the rule — COL-12 says an
    /// unavailable sort column falls back to Name ascending.
    public func sort(for kind: FolderKind) -> SortDescriptor? {
        guard let stored = load(kind), let sortID = stored.sortID, !sortID.isEmpty else { return nil }
        // A missing or unrecognised direction reads as ascending: that is the direction
        // a freshly clicked column starts in, and it is the safer half of a partial blob.
        let direction = stored.sortDirection.flatMap(SortDirection.init(rawValue:)) ?? .ascending
        return SortDescriptor(column: PropID(sortID), direction: direction)
    }

    /// Remember a kind's sort column and direction; `nil` forgets it, leaving the
    /// column layout intact.
    public func setSort(_ sort: SortDescriptor?, for kind: FolderKind) {
        update(kind) { layout in
            layout.sortID = sort?.column.rawValue
            layout.sortDirection = sort?.direction.rawValue
        }
    }

    // MARK: Resetting

    /// Forget one kind's layout entirely, columns and sort together.
    public func reset(for kind: FolderKind) {
        lock.withLock { defaults.removeObject(forKey: storageKey(for: kind)) }
    }

    /// Forget every kind's layout.
    public func resetAll() {
        lock.withLock {
            for kind in FolderKind.allCases {
                defaults.removeObject(forKey: storageKey(for: kind))
            }
        }
    }

    // MARK: Storage

    /// The persisted shape of one kind's layout.
    ///
    /// Field names mirror upstream's `CListViewInfo` members so the two are readable
    /// side by side: `Columns` and `SortID` keep their names exactly. Upstream's
    /// boolean `Ascending` becomes `SortDirection`, carrying `SortDirection`'s own raw
    /// value — the codebase already models direction as that enum rather than as a
    /// bare flag, and `"SortDirection":"descending"` says in a `defaults read` dump
    /// what `"Ascending":false` only implies.
    ///
    /// The whole layout is written as a JSON **string** rather than as `Data`, again
    /// for auditability: keeping the upstream key names buys nothing if the value
    /// itself prints as an opaque blob.
    private struct StoredLayout: Codable {
        var columns: [StoredColumn]?
        var sortID: String?
        var sortDirection: String?

        enum CodingKeys: String, CodingKey {
            case columns = "Columns"
            case sortID = "SortID"
            case sortDirection = "SortDirection"
        }

        var isEmpty: Bool { columns == nil && sortID == nil && sortDirection == nil }
    }

    /// One column's persisted shape.
    ///
    /// `PropID` is stored by its raw value, which IS the 7-Zip display name
    /// (`"Packed Size"`), so an unknown property from a format we have never seen
    /// round-trips intact instead of being dropped on the way in or out.
    private struct StoredColumn: Codable {
        var propID: String
        var width: Double
        var alignment: String

        enum CodingKeys: String, CodingKey {
            case propID = "PropID"
            case width = "Width"
            case alignment = "Alignment"
        }
    }

    private static func encode(_ columns: [PanelColumn]) -> [StoredColumn] {
        columns.map {
            StoredColumn(
                propID: $0.property.rawValue,
                width: $0.width,
                alignment: $0.alignment.rawValue
            )
        }
    }

    private static func decode(_ stored: [StoredColumn]) -> [PanelColumn] {
        var seen = Set<PropID>()
        var columns: [PanelColumn] = []
        for column in stored {
            let property = PropID(column.propID)
            // A duplicated property would produce two table columns with the same
            // identifier, which `NSTableView` will not tolerate. Keep the first.
            guard !column.propID.isEmpty, seen.insert(property).inserted else { continue }
            columns.append(
                PanelColumn(
                    property: property,
                    width: max(minimumColumnWidth, column.width.isFinite ? column.width : 0),
                    // An unrecognised alignment falls back to the column's natural
                    // one rather than to `.leading`, so a corrupt value still puts
                    // numbers under numbers.
                    alignment: PanelColumn.Alignment(rawValue: column.alignment)
                        ?? ColumnModel.defaultAlignment(for: property)
                )
            )
        }
        return columns
    }

    private func load(_ kind: FolderKind) -> StoredLayout? {
        lock.withLock { loadLocked(kind) }
    }

    private func loadLocked(_ kind: FolderKind) -> StoredLayout? {
        let key = storageKey(for: kind)
        // Accept `Data` as well as `String`: `defaults write -data` and a future
        // binary writer both produce it, and refusing it would look like the layout
        // had been forgotten.
        let bytes: Data?
        if let text = defaults.string(forKey: key) {
            bytes = text.data(using: .utf8)
        } else {
            bytes = defaults.data(forKey: key)
        }
        guard let bytes, !bytes.isEmpty else { return nil }
        // A hand-mangled value is treated as "nothing stored" rather than thrown:
        // there is no caller that could do anything useful with the error, and the
        // fallback — the default layout for the kind — is exactly right.
        return try? JSONDecoder().decode(StoredLayout.self, from: bytes)
    }

    /// Read-modify-write one kind's blob under the lock.
    private func update(_ kind: FolderKind, _ body: (inout StoredLayout) -> Void) {
        lock.withLock {
            var layout = loadLocked(kind) ?? StoredLayout()
            body(&layout)

            let key = storageKey(for: kind)
            guard !layout.isEmpty else {
                // Clearing the last field removes the key rather than leaving `{}`
                // behind, so a reset really does restore the pristine domain.
                defaults.removeObject(forKey: key)
                return
            }

            let encoder = JSONEncoder()
            // Deterministic key order: the value is meant to be diffed and eyeballed,
            // and a dictionary that reshuffles on every write is neither.
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(layout),
                  let text = String(data: data, encoding: .utf8)
            else { return }
            defaults.set(text, forKey: key)
        }
    }
}
