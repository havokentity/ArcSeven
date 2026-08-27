// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Settings ▸ File List switches, as the panel sees them (FIDELITY OPT-18…OPT-23).
//
// Until this file existed the settings window wrote seven keys and no module read one of
// them. A switch that persists a value nothing acts on is worse than an absent switch: it
// looks like it worked, so the unchanged behaviour reads as a bug somewhere else entirely.
//
// WHY THE KEYS ARE NAMED IN Support/Defaults.swift AND NOT HERE. SettingsUI is a leaf that
// nothing links, and it depends on FMKit rather than the other way round, so a reader cannot
// import it to reach `SettingsKey`. `Support/Defaults.swift` is the project's answer to that
// — "the one place a runtime setting is read from" — and `.swiftlint.yml` enforces it. The
// remaining risk is that the writer's spelling and the reader's drift apart, so
// `PanelListSettingsTests` pins `Defaults` against `SettingsKey`; the test target links both.
//
// WHY FIVE SWITCHES HERE AND SEVEN ON THE PANE. `FM.FullRow` (OPT-20) is dropped:
// `NSTableView` selects and highlights whole rows always, with no per-cell mode to switch
// out of, so neither position of that checkbox means anything (DIVERGENCES D-29).
// `FM.ShowSystemMenu` (OPT-24) is not a list-drawing setting at all — it governs the
// `Finder ▸` submenu (MF-25), which does not exist yet — so it stays disabled where it is.

import AppKit
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(Support)   // module-guard
import Support
#endif
import UniformTypeIdentifiers

// MARK: - The switches

/// The five Settings ▸ File List switches a panel draws from.
///
/// Grouped into a value so the five travel together and a test can state a whole
/// configuration in one line — but never *stored* by the panel: ``PanelViewController``
/// recomputes it from the defaults domain on each access, per the read-through rule in
/// `Support/Defaults.swift`. A snapshot would go stale the moment a setting changed by any
/// route other than the notification below, and `reload()` alone would then redraw from it.
///
/// Every switch is **off** by default, as on Windows. That is not a placeholder — it is a
/// deliberately preserved surprise, listed in FIDELITY.md §21.
public struct PanelListSettings: Equatable, Sendable {
    /// OPT-18 / DOT-01: show the `..` row in a folder that has a parent.
    public var showDots: Bool
    /// OPT-19: ask the filesystem for each file's own icon instead of its type's icon.
    public var showRealFileIcons: Bool
    /// OPT-21: draw grid lines between rows and columns.
    public var showGrid: Bool
    /// OPT-22: one click opens a row rather than only selecting it.
    public var singleClick: Bool
    /// OPT-23: Norton-style marks, kept separately from the system selection.
    public var alternativeSelection: Bool

    public init(
        showDots: Bool = false,
        showRealFileIcons: Bool = false,
        showGrid: Bool = false,
        singleClick: Bool = false,
        alternativeSelection: Bool = false
    ) {
        self.showDots = showDots
        self.showRealFileIcons = showRealFileIcons
        self.showGrid = showGrid
        self.singleClick = singleClick
        self.alternativeSelection = alternativeSelection
    }

    /// Read the current position of all five out of a defaults domain.
    ///
    /// Absent reads as `false`, which is the shipped default for every one of these, so
    /// none of them needs registering.
    public init(reading defaults: UserDefaults) {
        self.init(
            showDots: Defaults.showsParentRow(in: defaults),
            showRealFileIcons: Defaults.showsRealFileIcons(in: defaults),
            showGrid: Defaults.showsGridLines(in: defaults),
            singleClick: Defaults.opensOnSingleClick(in: defaults),
            alternativeSelection: Defaults.usesAlternativeSelection(in: defaults)
        )
    }

    /// Posted by the settings window whenever any of the five moves.
    ///
    /// A raw string for the same reason the keys are: SettingsUI declares this same name as
    /// `Notification.Name.arcSevenListSettingsDidChange`, and FMUI must not link SettingsUI
    /// to reach it. Pinned to that declaration by the same test.
    public static let didChange = Notification.Name("ArcSevenListSettingsDidChange")
}

// MARK: - Applying them

public extension PanelViewController {
    /// Re-apply everything that is a property of the table itself.
    ///
    /// Only OPT-21 lands here. The other four are consulted where they are used, because
    /// they change what gets drawn rather than how the table is configured.
    func applyListSettings() {
        // Windows' LVS_EX_GRIDLINES draws both axes, so both masks move together.
        tableView.gridStyleMask = listSettings.showGrid
            ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
            : []
    }

    /// Start listening for the settings window.
    ///
    /// Selector-based rather than block-based on purpose: the block form returns a token
    /// that has to be stored and unregistered by hand, whereas an `NSObject` observer is
    /// removed for us when the controller deallocates.
    func startObservingListSettings() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(listSettingsDidChange),
            name: PanelListSettings.didChange,
            object: nil
        )
    }

    /// Re-apply the five — 7zFM's `SetListSettings()` followed by `RefreshAllPanels()`.
    ///
    /// Nothing is re-read into storage here because nothing was stored: `listSettings` reads
    /// through. What this does is the *acting on* a change, which the panel cannot infer —
    /// the grid mask has to be set, and the list has to be rebuilt because OPT-18 changes
    /// which rows exist and OPT-19 changes every icon.
    @objc func listSettingsDidChange() {
        applyListSettings()
        reload()
    }
}

// MARK: - OPT-19: which icon API a row's icon comes from

public extension PanelViewController {
    /// Where a row's icon is fetched from.
    ///
    /// Split out of ``icon(for:showRealFileIcons:)`` so the OPT-19 decision can be asserted
    /// directly. Comparing two bitmaps only proves the switch does *something*; this names
    /// which of the two documented APIs was asked, which is what OPT-19 actually specifies.
    enum IconSource: Equatable, Sendable {
        /// The synthetic `..` row, which is not a file at all.
        case parentRow
        /// A directory: the generic folder icon, on either switch position.
        case folder
        /// `NSWorkspace.icon(forFile:)` — the file's own icon. OPT-19 on.
        case file(URL)
        /// `NSWorkspace.icon(for: UTType)` — one icon per type. OPT-19 off, and the only
        /// option for a row inside an archive, where there is no file on disk to ask.
        case type(UTType)
    }

    static func iconSource(for item: FolderItem, showRealFileIcons: Bool) -> IconSource {
        if item.isParentRow { return .parentRow }
        if item.isDirectory { return .folder }
        if showRealFileIcons, let url = item.url { return .file(url) }
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
        return .type(type ?? .data)
    }

    /// The icon for a row.
    static func icon(for item: FolderItem, showRealFileIcons: Bool) -> NSImage {
        let image: NSImage
        switch iconSource(for: item, showRealFileIcons: showRealFileIcons) {
        case .parentRow:
            image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder")
                ?? NSWorkspace.shared.icon(for: .folder)
        case .folder:
            image = NSWorkspace.shared.icon(for: .folder)
        case .file(let url):
            image = NSWorkspace.shared.icon(forFile: url.path)
        case .type(let type):
            image = NSWorkspace.shared.icon(for: type)
        }
        // Copied before resizing: `NSWorkspace` hands back a shared, cached instance for a
        // given type, and resizing that in place resizes it for every other caller in the
        // process — including the reference a test just fetched to compare against.
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 16, height: 16)
        return sized
    }
}

// MARK: - OPT-22: single-click open

public extension PanelViewController {
    /// The table's single-click action. Fires on mouse-up, on the row under the pointer.
    @objc func rowClicked(_ sender: Any?) {
        // A click in the blank area below the rows reports -1.
        guard tableView.clickedRow >= 0 else { return }
        openIfSingleClick(rowAt: tableView.clickedRow)
    }

    /// Open `index`, if and only if single-click mode is on.
    ///
    /// Separate from ``rowClicked(_:)`` because `NSTableView.clickedRow` cannot be set from
    /// outside AppKit, so this is the seam a test can reach.
    func openIfSingleClick(rowAt index: Int) {
        guard listSettings.singleClick else { return }
        open(rowAt: index)
    }

    /// Open `index` unless single-click mode already did.
    ///
    /// A double-click delivers the single-click action first, so in single-click mode the
    /// row is open by the time this runs and acting again descends two levels on one gesture.
    func openIfDoubleClick(rowAt index: Int) {
        guard !listSettings.singleClick else { return }
        open(rowAt: index)
    }
}

// MARK: - OPT-23: alternative selection mode

public extension PanelViewController {
    /// The rows the user has marked, in listing order, excluding `..`.
    ///
    /// Derived from `rows` rather than stored as items, so a mark on a path that has since
    /// left the listing stops counting instead of resurrecting a row that is not there.
    var markedItems: [FolderItem] {
        rows.filter { !$0.isParentRow && markedPaths.contains($0.path) }
    }

    /// Is this row marked? Drives the row's appearance.
    func isMarked(rowAt index: Int) -> Bool {
        guard listSettings.alternativeSelection, rows.indices.contains(index) else { return false }
        let item = rows[index]
        return !item.isParentRow && markedPaths.contains(item.path)
    }

    /// Toggle the focused row's mark and advance one row — 7zFM's `Insert` (KEY-28).
    ///
    /// A no-op outside alternative selection mode, where the OS selection is the only
    /// selection there is and a second, invisible one would be a trap.
    ///
    /// Advancing does not wrap at the last row, matching upstream: holding `Insert` marks
    /// to the end of the list and stops there rather than starting again at the top.
    func toggleMark() {
        guard listSettings.alternativeSelection else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }

        let item = rows[row]
        if !item.isParentRow {
            if markedPaths.contains(item.path) {
                markedPaths.remove(item.path)
            } else {
                markedPaths.insert(item.path)
            }
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integersIn: 0..<max(tableView.numberOfColumns, 1))
            )
        }

        let next = row + 1
        if rows.indices.contains(next) {
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
        }
        updateSelectionStatus()
    }

    /// Drop every mark. Called on navigation, not on refresh — ⌘R must not lose them.
    func clearMarks() {
        guard !markedPaths.isEmpty else { return }
        markedPaths.removeAll()
        tableView.reloadData()
        updateSelectionStatus()
    }

    /// The rows an operation should act on, excluding the `..` row.
    ///
    /// In alternative selection mode the marks are the answer whenever there are any: that
    /// is the entire point of the mode, and it is why this stays the one property every
    /// operation reads rather than a second one they would each have to learn about.
    ///
    /// With nothing marked it falls back to the system selection, which is what makes the
    /// mode usable rather than modal — upstream behaves the same way, acting on the focused
    /// item when no marks exist.
    var selectedItems: [FolderItem] {
        if listSettings.alternativeSelection {
            let marked = markedItems
            if !marked.isEmpty { return marked }
        }
        return tableView.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index) else { return nil }
            let item = rows[index]
            return item.isParentRow ? nil : item
        }
    }
}
