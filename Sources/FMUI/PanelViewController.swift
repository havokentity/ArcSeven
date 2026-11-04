// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// One panel: path bar, file list, status bar.
//
// This is 7zFM's CPanel. It shows whatever `FolderProvider` it is given and does not
// know whether that is a directory on disk, the interior of a `.7z`, or an archive
// nested three deep — which is the whole point of the abstraction.
//
// The table is a view-based `NSTableView` driven by an explicit data source rather
// than bindings. At the row counts archives reach (a Linux kernel source tarball is
// ~80,000 entries) the data source is the only approach that stays responsive: cells
// are created for visible rows only, and reloading is O(visible), not O(entries).

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
/// The panel's sort key, named by module. Foundation exports a `SortDescriptor` too, and
/// with both imported a bare mention in type position is ambiguous — an initialiser call
/// resolves by its argument labels, a parameter type does not. The Xcode build compiles
/// everything as one module, where the local type shadows Foundation's and no module
/// name exists to qualify with, hence the guard.
private typealias PanelSortDescriptor = FMKit.SortDescriptor
#else
private typealias PanelSortDescriptor = SortDescriptor
#endif

/// Told when the panel's contents or selection change, so the window can retitle
/// itself and update its toolbar.
@MainActor
public protocol PanelViewControllerDelegate: AnyObject {
    func panelDidChangeLocation(_ panel: PanelViewController)
    func panelDidChangeSelection(_ panel: PanelViewController)
    func panel(_ panel: PanelViewController, didFailWith error: any Error)

    /// Files were dropped onto the panel. `target` is the directory row they landed
    /// on; `nil` means they were dropped into the level being shown. What the drop
    /// MEANS — a disk copy, or compressing into an archive — is the delegate's call,
    /// because the panel deliberately does not know what its provider is.
    func panel(_ panel: PanelViewController, didReceiveDroppedFiles urls: [URL], onto target: FolderItem?)
}

@MainActor
public final class PanelViewController: NSViewController {
    // MARK: State

    /// The engine used to open archives. Handed to every provider this panel creates.
    private let engine: any ArchiveEngine

    /// The level currently displayed.
    public private(set) var provider: any FolderProvider

    /// Rows as displayed: sorted, and including the synthetic ".." row when not at
    /// the top. Index 0 is therefore not necessarily a real item.
    private(set) var rows: [FolderItem] = []

    /// Columns for the current folder type.
    private var columnModel = ColumnModel(columns: [])

    /// Active sort.
    private var sort = SortDescriptor(column: .name, direction: .ascending)

    /// Incremented on every load; a load whose token is stale on completion is
    /// discarded. Without this, clicking quickly through folders can let a slow
    /// archive listing overwrite a newer, faster one.
    private var loadToken = 0

    /// `true` while a load is in flight, so the spinner and the empty state agree.
    ///
    /// Internal, not private, so a test can wait for a load to settle rather than sleep.
    var isLoading = false

    /// Where the Settings ▸ File List switches are read from.
    ///
    /// Injected by tests, which must not write the five keys into the standard domain and so
    /// change the appearance of the tester's own installed copy of the app.
    var listSettingsStore: UserDefaults = .standard

    /// The Settings ▸ File List switches (OPT-18…OPT-23), consumed in PanelListSettings.swift.
    ///
    /// Computed, never stored: `Support/Defaults.swift` reads settings through on every call
    /// so a change cannot leave a stale copy behind, and this follows that rule.
    var listSettings: PanelListSettings { PanelListSettings(reading: listSettingsStore) }

    /// Paths marked in alternative selection mode (OPT-23), kept apart from the OS selection.
    var markedPaths: Set<String> = []

    public weak var delegate: (any PanelViewControllerDelegate)?

    /// Turns rows into pasteboard writers, so a member can be dragged straight out of
    /// an archive into Finder without extracting it first.
    private let dragController: DragController

    // MARK: Views

    /// Internal, not private: the path bar is drawn in PanelViewController+PathBar.swift.
    let pathControl = NSPathControl()
    /// Internal for the same reason: the list settings are applied in PanelListSettings.swift.
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")

    // MARK: Init

    public init(provider: any FolderProvider, engine: any ArchiveEngine) {
        self.provider = provider
        self.engine = engine
        self.dragController = DragController(engine: engine)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: View construction

    override public func loadView() {
        let root = NSView()

        configurePathControl()
        configureTable()
        configureStatusBar()

        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let statusStack = NSStackView(views: [statusLabel, NSView(), selectionLabel, spinner])
        statusStack.orientation = .horizontal
        statusStack.spacing = 8
        statusStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        statusStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let separator = NSBox()
        separator.boxType = .separator

        for subview in [pathControl, scrollView, separator, statusStack, messageLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            // safeArea, not root.top: the window uses .fullSizeContentView with a
            // unified toolbar, so the content view extends UNDER the title bar and a
            // plain top anchor hides the path bar behind the toolbar entirely.
            pathControl.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
            pathControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            pathControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: pathControl.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: statusStack.topAnchor),

            statusStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            messageLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            // A floor for the whole panel. The split view sizes itself from its
            // panes' fitting size, and a scroll view reports no intrinsic height, so
            // without these the window collapses to the height of the path bar.
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        view = root
    }

    private func configurePathControl() {
        pathControl.pathStyle = .standard
        pathControl.backgroundColor = .clear
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathControlClicked(_:))
        pathControl.focusRingType = .none
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowSizeStyle = .default
        tableView.style = .inset
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 20
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.action = #selector(rowClicked(_:))
        applyListSettings()
        startObservingListSettings()

        // Dragging OUT. `.copy` for both, because nothing here is a move: dragging a
        // member out of an archive extracts a copy, and dragging a file off a panel
        // must not delete it.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

        // Dropping IN. Only `.fileURL`: files from Finder or from the other panel.
        // Promise-only drags (a member dragged out of another archive) carry no file
        // URL and are refused — the bytes do not exist on disk to insert.
        tableView.registerForDraggedTypes([.fileURL])
        tableView.headerView = NSTableHeaderView()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
    }

    private func configureStatusBar() {
        for label in [statusLabel, selectionLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        focusTable()
    }

    /// Give the list keyboard focus — but deliberately NOT a selection.
    ///
    /// Focus is needed because a file manager whose arrow keys do nothing until you
    /// click a row feels broken.
    ///
    /// Auto-*selecting* a row is a different matter, and selecting one here was a bug:
    /// every operation treats "nothing selected" as "act on everything", which is
    /// 7zFM's rule. Pre-selecting the first row silently turned "Extract" and "Test"
    /// into "extract/test that one item", so testing a 12-member archive reported 7.
    /// An empty selection is meaningful state, so the panel leaves it empty and lets
    /// the user create one.
    private func focusTable() {
        guard let window = view.window else { return }
        if window.firstResponder !== tableView {
            window.makeFirstResponder(tableView)
        }
    }

    // MARK: Loading

    /// Load the current provider's children and display them.
    public func reload() {
        loadToken += 1
        let token = loadToken
        let provider = self.provider
        let descriptor = sort
        // OPT-18 / DOT-01: `..` needs BOTH a parent to point at and the switch on. The
        // root folder shows none whatever the switch says, which is upstream's rule too.
        let showsParentRow = listSettings.showDots

        isLoading = true
        spinner.startAnimation(nil)
        messageLabel.isHidden = true

        Task { [weak self] in
            do {
                let loaded = try await Self.loadRows(
                    from: provider, sortedBy: descriptor, showingParentRow: showsParentRow
                )
                guard let self, token == loadToken else { return }
                apply(rows: loaded.rows, isEmpty: loaded.isEmpty)
            } catch {
                guard let self, token == loadToken else { return }
                isLoading = false
                spinner.stopAnimation(nil)
                rows = []
                tableView.reloadData()
                showMessage("Could not open this location.")
                delegate?.panel(self, didFailWith: error)
            }
        }
    }

    /// Load a level and sort it, both away from the main actor.
    ///
    /// `nonisolated` and `async`, so it runs on the cooperative pool rather than on the
    /// caller's executor (SE-0338). That is the point: `SortEngine` compares with a
    /// locale-aware, numeric, case-folding comparator, and doing that for an 80,000-row
    /// tarball on the main thread froze the window for the whole of the sort. Here the
    /// listing arrives on the main actor already ordered, in the one hop the load
    /// always needed.
    nonisolated private static func loadRows(
        from provider: any FolderProvider,
        sortedBy descriptor: PanelSortDescriptor,
        showingParentRow: Bool
    ) async throws -> (rows: [FolderItem], isEmpty: Bool) {
        let children = try await provider.loadChildren()
        let hasParent = try await provider.parent() != nil
        let parentRow = hasParent && showingParentRow ? Self.parentRow : nil
        return (SortEngine.sort(children, by: descriptor, parentItem: parentRow), children.isEmpty)
    }

    /// The synthetic `..` row.
    nonisolated private static var parentRow: FolderItem {
        FolderItem(path: "..", name: "..", isNavigable: true, isDirectory: true)
    }

    /// Re-sort what is already loaded, off the main actor when there is enough of it.
    ///
    /// Small listings are sorted inline: the hop costs more than the sort, and a header
    /// click should feel immediate. Large ones go to the pool, and a load that lands in
    /// the meantime wins, because it carries the new descriptor itself.
    private func resortRows() {
        let body = rows.filter { !$0.isParentRow }
        let parentRow = rows.first(where: \.isParentRow)
        let descriptor = sort

        if body.count <= Self.inlineSortLimit {
            rows = SortEngine.sort(body, by: descriptor, parentItem: parentRow)
            tableView.reloadData()
            return
        }

        loadToken += 1
        let token = loadToken
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                SortEngine.sort(body, by: descriptor, parentItem: parentRow)
            }.value
            guard let self, token == loadToken else { return }
            rows = sorted
            tableView.reloadData()
        }
    }

    /// Row counts up to this are sorted on the main actor; see ``resortRows()``.
    private static let inlineSortLimit = 2000

    /// Navigate to a new level.
    public func go(to provider: any FolderProvider) {
        clearMarks()
        self.provider = provider
        rebuildColumns(for: provider)
        updatePathControl()
        reload()
        delegate?.panelDidChangeLocation(self)
    }

    /// Show a loaded, already-sorted level.
    private func apply(rows sorted: [FolderItem], isEmpty: Bool) {
        isLoading = false
        spinner.stopAnimation(nil)

        rows = sorted

        tableView.reloadData()
        updateStatusBar()
        updateSelectionStatus()
        focusTable()

        if isEmpty {
            showMessage("This folder is empty.")
        } else {
            messageLabel.isHidden = true
        }
    }

    private func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        updateStatusBar()
    }

    // MARK: Columns

    private func rebuildColumns(for provider: any FolderProvider) {
        columnModel = ColumnModel(available: provider.availableColumns)

        for column in tableView.tableColumns { tableView.removeTableColumn(column) }

        for spec in columnModel.columns {
            let column = NSTableColumn(identifier: .init(spec.property.rawValue))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 40
            column.maxWidth = 900
            // Header click sorting is wired through `tableView(_:didClick:)`; the
            // descriptor here only supplies the header's arrow.
            column.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.property.rawValue,
                ascending: true
            )
            tableView.addTableColumn(column)
        }
    }

    // MARK: Navigation

    /// What activating a row means.
    ///
    /// Split out of ``open(rowAt:)`` because the decision is the part that goes wrong
    /// and the part that cannot otherwise be observed: `open(rowAt:)` either kicks off
    /// an async descent or calls `NSWorkspace`, and neither is assertable. This is,
    /// and every branch below is reached through it.
    enum RowActivation: Equatable {
        /// The synthetic ".." row: go up a level.
        case ascend
        /// A folder or an archive: ask the provider for a child provider.
        case descend
        /// Anything else with a file behind it — a document, or a package such as a
        /// `.app`. Hand it to Launch Services, which is what Finder does.
        case launch(URL)
        /// A row with nothing behind it: a member of an archive that is not itself
        /// navigable has no URL to open.
        case nothing
    }

    /// Decide what opening `item` should do.
    ///
    /// The ordering matters: `isNavigable` is checked BEFORE falling through to the
    /// URL, so a folder never gets handed to Launch Services, and a row that is not
    /// navigable never reaches `child(at:)` — which would return `nil` and leave the
    /// double-click doing nothing at all. That was the package bug: `isNavigable` was
    /// `true` for a `.app` while `isDirectory` was `false`, so the descent branch ran,
    /// `child(at:)` matched no branch, and the launch fallback was never considered.
    static func activation(for item: FolderItem) -> RowActivation {
        if item.isParentRow { return .ascend }
        if item.isNavigable { return .descend }
        if let url = item.url { return .launch(url) }
        return .nothing
    }

    /// Open the row at `index`, descending if it is navigable.
    public func open(rowAt index: Int) {
        guard rows.indices.contains(index) else { return }
        let item = rows[index]

        switch Self.activation(for: item) {
        case .ascend:
            // `self.provider` must stay qualified: a local named `provider` is declared
            // further down this function, and an unqualified reference here captures
            // that instead. SwiftLint's redundant_self autofix removed the `self.` and
            // broke the build exactly this way.
            let current = self.provider
            Task { [weak self] in
                guard let self, let parent = try? await current.parent() else { return }
                go(to: parent)
            }
            return

        case .launch(let url):
            // A plain file, or a package: hand it to Launch Services, matching 7zFM's
            // Enter and Finder's double-click.
            NSWorkspace.shared.open(url)
            return

        case .nothing:
            return

        case .descend:
            break
        }

        let provider = self.provider
        spinner.startAnimation(nil)
        Task { [weak self] in
            defer { self?.spinner.stopAnimation(nil) }
            do {
                guard let child = try await provider.child(at: item) else { return }
                guard let self else { return }
                go(to: child)
            } catch {
                guard let self else { return }
                delegate?.panel(self, didFailWith: error)
            }
        }
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        // A double-click in the blank area below the rows reports -1.
        guard tableView.clickedRow >= 0 else { return }
        openIfDoubleClick(rowAt: tableView.clickedRow)
    }

    /// Go up one level. Bound to Cmd+Up.
    public func goToParent() {
        Task { [weak self] in
            guard let self, let parent = try? await provider.parent() else { return }
            go(to: parent)
        }
    }

    /// Open whatever is selected. Bound to Return and Cmd+Down.
    public func openSelection() {
        guard tableView.selectedRow >= 0 else { return }
        open(rowAt: tableView.selectedRow)
    }

    // MARK: Selection

    /// Select rows by index, as clicking them would.
    ///
    /// The table itself is private, and everything that reads a selection reads it
    /// through ``selectedItems``, so without this there is no way to put a panel into a
    /// selected state — which is precisely the state the Properties inspector is
    /// supposed to follow, and precisely why nothing noticed that it did not.
    func selectRows(_ indexes: IndexSet) {
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
    }
}

// MARK: - Status bar

/// The two footer readouts: the folder tally on the left, the selection tally on the
/// right. In an extension so the controller body stays inside its size budget.
extension PanelViewController {
    private func updateStatusBar() {
        let items = rows.filter { !$0.isParentRow }
        let folders = items.filter(\.isDirectory).count
        let files = items.count - folders
        let bytes = items.reduce(into: UInt64(0)) { total, item in
            total += item.numericValue(for: .size) ?? 0
        }

        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        parts.append("\(files) file\(files == 1 ? "" : "s")")
        if bytes > 0 { parts.append(ColumnModel.groupedByteCount(bytes) + " bytes") }
        statusLabel.stringValue = parts.joined(separator: ", ")
    }

    func updateSelectionStatus() {
        let selected = selectedItems
        guard !selected.isEmpty else {
            selectionLabel.stringValue = ""
            return
        }
        let bytes = selected.reduce(into: UInt64(0)) { total, item in
            total += item.numericValue(for: .size) ?? 0
        }
        var text = "\(selected.count) selected"
        if bytes > 0 { text += " · " + ColumnModel.groupedByteCount(bytes) + " bytes" }
        selectionLabel.stringValue = text
    }
}

// MARK: - Data source

extension PanelViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    /// Supply the pasteboard writer for a dragged row.
    ///
    /// Returning nil makes the row undraggable, which is what we want for the ".."
    /// parent and for directories inside an archive (a promise for a whole subtree
    /// needs the operation queue that lands in a later milestone).
    public func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        guard !item.isParentRow else { return nil }
        return dragController.pasteboardWriter(for: item, in: provider)
    }

    public func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragController.dragSessionEnded()
    }

    // MARK: Dropping in

    /// Decide whether a drag may land here, and where it would land.
    ///
    /// A drop ON a directory row means "into that folder". Everything else — a file
    /// row, the ".." row, a between-rows gap, the space below the last row — is
    /// retargeted to the whole table (`row: -1`), which highlights the panel and
    /// means "into the level being shown".
    public func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }

        if dropOperation == .on, rows.indices.contains(row),
           rows[row].isDirectory, !rows[row].isParentRow {
            tableView.setDropRow(row, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        // Always a copy from the user's side: dropping into an archive compresses a
        // copy of the source, and must never consume the original.
        return .copy
    }

    public func tableView(
        _ tableView: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        // Row → target folder. Anything that is not a real directory row — including
        // the whole-table -1 that validateDrop set — means the level being shown.
        var target: FolderItem?
        if rows.indices.contains(row), rows[row].isDirectory, !rows[row].isParentRow {
            target = rows[row]
        }
        delegate?.panel(self, didReceiveDroppedFiles: urls, onto: target)
        return true
    }

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let property = PropID(rawValue: tableColumn.identifier.rawValue)
        // Clicking the active column flips it; clicking a new one starts ascending.
        sort = property == sort.column
            ? SortDescriptor(column: property, direction: sort.direction.reversed)
            : SortDescriptor(column: property, direction: .ascending)
        updateSortIndicator()

        // A load in flight read the previous descriptor when it started. Restarting it
        // is cheaper than racing it, and the restart sorts with the new one.
        if isLoading {
            reload()
            return
        }
        resortRows()
    }

    private func updateSortIndicator() {
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }
        guard let column = tableView.tableColumns.first(
            where: { $0.identifier.rawValue == sort.column.rawValue }
        ) else { return }
        let name = sort.direction == .ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
        tableView.setIndicatorImage(NSImage(named: name), in: column)
        tableView.highlightedTableColumn = column
    }
}

// MARK: - Delegate

extension PanelViewController: NSTableViewDelegate {
    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let property = PropID(rawValue: tableColumn.identifier.rawValue)

        let identifier = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? Self.makeCell(identifier: identifier, isNameColumn: property == .name)

        cell.textField?.stringValue = ColumnModel.displayText(for: item, column: property)
        cell.textField?.alignment =
            ColumnModel.defaultAlignment(for: property) == .trailing ? .right : .left

        if property == .name {
            cell.imageView?.image = Self.icon(
                for: item, showRealFileIcons: listSettings.showRealFileIcons
            )
        }
        // OPT-23: a mark is not the system selection, so it needs a colour of its own.
        cell.textField?.textColor = isMarked(rowAt: row) ? .controlAccentColor : .labelColor
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionStatus()
        delegate?.panelDidChangeSelection(self)
    }

    /// Build a reusable cell.
    ///
    /// Only the Name column carries an icon; the rest are plain text, which keeps the
    /// per-cell cost down when many columns are visible.
    private static func makeCell(
        identifier: NSUserInterfaceItemIdentifier,
        isNameColumn: Bool
    ) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.font = .systemFont(ofSize: 12)
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        if isNameColumn {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            cell.addSubview(image)
            cell.imageView = image

            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),

                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }
}
