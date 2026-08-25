// SPDX-License-Identifier: GPL-3.0-or-later
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
#endif
import UniformTypeIdentifiers

/// Told when the panel's contents or selection change, so the window can retitle
/// itself and update its toolbar.
@MainActor
public protocol PanelViewControllerDelegate: AnyObject {
    func panelDidChangeLocation(_ panel: PanelViewController)
    func panelDidChangeSelection(_ panel: PanelViewController)
    func panel(_ panel: PanelViewController, didFailWith error: any Error)
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
    private var isLoading = false

    public weak var delegate: (any PanelViewControllerDelegate)?

    /// Turns rows into pasteboard writers, so a member can be dragged straight out of
    /// an archive into Finder without extracting it first.
    private let dragController: DragController

    // MARK: Views

    private let pathControl = NSPathControl()
    private let tableView = NSTableView()
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

        // Dragging OUT. `.copy` for both, because nothing here is a move: dragging a
        // member out of an archive extracts a copy, and dragging a file off a panel
        // must not delete it.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
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

        isLoading = true
        spinner.startAnimation(nil)
        messageLabel.isHidden = true

        Task { [weak self] in
            do {
                let children = try await provider.loadChildren()
                let parent = try await provider.parent()
                guard let self, token == loadToken else { return }
                apply(children: children, hasParent: parent != nil)
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

    /// Navigate to a new level.
    public func go(to provider: any FolderProvider) {
        self.provider = provider
        rebuildColumns(for: provider)
        updatePathControl()
        reload()
        delegate?.panelDidChangeLocation(self)
    }

    private func apply(children: [FolderItem], hasParent: Bool) {
        isLoading = false
        spinner.stopAnimation(nil)

        let parentRow = hasParent
            ? FolderItem(path: "..", name: "..", isNavigable: true, isDirectory: true)
            : nil
        rows = SortEngine.sort(children, by: sort, parentItem: parentRow)

        tableView.reloadData()
        updateStatusBar()
        updateSelectionStatus()
        focusTable()

        if children.isEmpty {
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

    // MARK: Path bar

    private func updatePathControl() {
        pathControl.url = nil
        pathControl.pathItems = pathComponents().map { component in
            let item = NSPathControlItem()
            item.title = component.title
            item.image = component.image
            return item
        }
    }

    /// Break the display path into clickable crumbs.
    ///
    /// Inside an archive the crumbs continue past the archive file itself, which is
    /// what makes `archive.7z/docs/img` read as one continuous path — 7zFM's model.
    private func pathComponents() -> [(title: String, image: NSImage?)] {
        let archiveIcon = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)
        let folderIcon = NSWorkspace.shared.icon(for: .folder)
        folderIcon.size = NSSize(width: 16, height: 16)

        switch provider.kind {
        case .archive:
            guard let archive = provider as? ArchiveFolderProvider else { return [] }
            var crumbs: [(String, NSImage?)] = [(archive.archiveURL.lastPathComponent, archiveIcon)]
            if !archive.subPath.isEmpty {
                for component in archive.subPath.split(separator: "/") {
                    crumbs.append((String(component), folderIcon))
                }
            }
            return crumbs
        default:
            let path = provider.displayPath
            let components = path.split(separator: "/").map(String.init)
            return components.isEmpty
                ? [("/", folderIcon)]
                : components.map { ($0, folderIcon) }
        }
    }

    @objc private func pathControlClicked(_ sender: NSPathControl) {
        guard let clicked = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(where: { $0 === clicked })
        else { return }
        let levelsUp = sender.pathItems.count - 1 - index
        guard levelsUp > 0 else { return }
        ascend(levels: levelsUp)
    }

    private func ascend(levels: Int) {
        Task { [weak self] in
            guard let self else { return }
            var target = provider
            for _ in 0..<levels {
                guard let parent = try? await target.parent() else { break }
                target = parent
            }
            go(to: target)
        }
    }

    // MARK: Navigation

    /// Open the row at `index`, descending if it is navigable.
    public func open(rowAt index: Int) {
        guard rows.indices.contains(index) else { return }
        let item = rows[index]

        if item.isParentRow {
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
        }

        guard item.isNavigable else {
            // A plain file: hand it to Launch Services, matching 7zFM's Enter.
            if let url = item.url { NSWorkspace.shared.open(url) }
            return
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
        open(rowAt: tableView.clickedRow)
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

    /// The rows the user has selected, excluding the ".." row.
    public var selectedItems: [FolderItem] {
        tableView.selectedRowIndexes.compactMap { index in
            guard rows.indices.contains(index) else { return nil }
            let item = rows[index]
            return item.isParentRow ? nil : item
        }
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

    private func updateSelectionStatus() {
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

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let property = PropID(rawValue: tableColumn.identifier.rawValue)
        // Clicking the active column flips it; clicking a new one starts ascending.
        sort = property == sort.column
            ? SortDescriptor(column: property, direction: sort.direction.reversed)
            : SortDescriptor(column: property, direction: .ascending)

        let parentRow = rows.first(where: \.isParentRow)
        rows = SortEngine.sort(
            rows.filter { !$0.isParentRow },
            by: sort,
            parentItem: parentRow
        )
        tableView.reloadData()
        updateSortIndicator()
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
            cell.imageView?.image = Self.icon(for: item)
        }
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

    /// The icon for a row.
    private static func icon(for item: FolderItem) -> NSImage {
        let image: NSImage
        if item.isParentRow {
            image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Parent folder")
                ?? NSWorkspace.shared.icon(for: .folder)
        } else if item.isDirectory {
            image = NSWorkspace.shared.icon(for: .folder)
        } else if let url = item.url {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            // Inside an archive there is no file on disk to ask about, so fall back to
            // the type implied by the extension.
            let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
            image = NSWorkspace.shared.icon(for: type ?? .data)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
