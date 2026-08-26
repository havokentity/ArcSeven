// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Properties / Info panel (7zFM's `Alt+Enter`, our `⌘I`).
//
// 7zFM builds this list by *asking* — `IGetFolderArcProps` for the archive levels,
// the folder's own property list for the focused item — and prints whatever comes
// back, in the order the handler declared it. It does not consult a table of
// properties it knows how to display. That is the whole reason `PropID` is a
// string-backed struct rather than an enum: a `.wim`, a `.dmg` or a handler that
// does not exist yet advertises properties nobody here has heard of, and they must
// still show up. So this controller renders **every key present in the bag**, with
// the well-known ones ordered first and anything unrecognised appended rather than
// dropped.
//
// Divergences from 7zFM, both recorded in docs: the panel is non-modal so it can
// follow the selection (D-27), and the `------------------------` section rule is
// drawn as a group row on screen while still being written literally into the text
// that `⌘C` copies, so a pasted property dump matches 7zFM's byte for byte.

import AppKit
#if canImport(Support)   // module-guard
import Support
#endif
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif

/// A two-column Name / Value inspector for an archive and, optionally, one member.
@MainActor
public final class PropertiesInspectorController: NSViewController {
    // MARK: State

    private var listing: ArchiveListing
    private var entry: ArchiveEntry?
    private var rows: [Row] = []

    private weak var hostWindow: NSWindow?

    /// Keeps the controller alive while the panel is on screen; see the same
    /// reasoning in `PasswordDialogController`. A caller that writes
    /// `PropertiesInspectorController(...).present(in: window)` and keeps no
    /// reference must still get a working panel.
    private var selfRetain: PropertiesInspectorController?

    // MARK: Views

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
        styleMask: [.titled, .closable, .resizable, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)

    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let valueColumn = NSUserInterfaceItemIdentifier("value")

    // MARK: Init

    public init(listing: ArchiveListing, entry: ArchiveEntry?) {
        self.listing = listing
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
        rows = Self.buildRows(listing: listing, entry: entry)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Presentation

    /// Show the inspector for `window`.
    ///
    /// Presented as a child window rather than a sheet: property inspection is a
    /// browsing activity, and a sheet would force open/close/reopen for every item
    /// the user wants to compare (D-27). Being a child window means it follows the
    /// document window around the screen and cannot be lost behind it.
    public func present(in window: NSWindow) {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        hostWindow = window
        selfRetain = self

        configurePanelIfNeeded()
        position(over: window)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
    }

    /// `true` while the panel is on screen.
    ///
    /// The controller outlives its window: closing the panel drops `selfRetain` and
    /// `hostWindow`, but whoever opened it still holds a reference, and `present(in:)`
    /// will put the same panel back. The owner needs to be able to tell the two states
    /// apart — see `MainWindowController.showInfo`.
    public var isOnScreen: Bool { panel.isVisible }

    /// What the panel is rendering right now.
    ///
    /// Exposed because "the inspector follows the selection" is otherwise unobservable
    /// from outside — and it was asserted in two documents (`DIVERGENCES.md` D-27,
    /// `FIDELITY.md` PRP-01) for two releases while `update(listing:entry:)` had no
    /// call sites at all.
    public var inspectedEntryPath: String? { entry?.path }

    /// The archive the panel is describing.
    public var inspectedArchiveURL: URL { listing.url }

    /// The panel's window title, which names whatever is selected.
    public var inspectedTitle: String { panel.title }

    /// How many rows the table is showing. Asked of the *table*, not of the row array,
    /// so a state change that never reached `reloadData` still reads as stale.
    public var inspectedRowCount: Int { tableView.numberOfRows }

    /// Re-render for a new selection, keeping the panel where it is.
    ///
    /// This is what makes the inspector *live*: the panel owner calls it from its
    /// selection-changed hook rather than tearing the controller down and building
    /// a new one, so the scroll position of an unchanged section survives.
    /// Replace the contents, and re-fit — a newly selected member can have many more
    /// rows than the one before it, and keeping the old height would clip them.
    public func update(listing: ArchiveListing, entry: ArchiveEntry?) {
        self.listing = listing
        self.entry = entry
        rows = Self.buildRows(listing: listing, entry: entry)
        panel.title = Self.panelTitle(listing: listing, entry: entry)
        tableView.reloadData()

        // Grow to fit a larger selection, but never shrink: once the user has sized the
        // panel by hand, taking that away on every selection change is worse than a bit
        // of empty space.
        if panel.isVisible {
            let wanted = preferredContentSize()
            let current = panel.contentLayoutRect.size
            if wanted.height > current.height {
                panel.setContentSize(NSSize(width: current.width, height: wanted.height))
            }
        }
    }

    private func configurePanelIfNeeded() {
        guard panel.contentViewController !== self else { return }
        // Programmatically created windows default to releasing themselves on close,
        // which under ARC means the panel is deallocated while `self` still points
        // at it. Explicitly off.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        // Title last: assigning `contentViewController` hands the window's title over
        // to the view controller, which would otherwise blank what we just set.
        panel.contentViewController = self
        panel.title = Self.panelTitle(listing: listing, entry: entry)

        // Size AFTER assigning contentViewController, never before.
        //
        // Assigning it resizes the window to the view's fitting size and throws away the
        // contentRect passed to init — so the panel opened at a few hundred points and
        // had to be dragged bigger by hand every single time. Exactly the defect the main
        // window had (it opened at 278x85); the fix is the same, and the ordering is the
        // whole point.
        panel.setContentSize(preferredContentSize())
        panel.minSize = NSSize(width: 420, height: 260)
    }

    /// A size that shows the whole table without scrolling, within reason.
    ///
    /// Properties panels vary enormously — a `.tar` member has a handful of rows, a
    /// solid `.7z` with an encrypted header has dozens — so a fixed height is either
    /// wasteful or immediately scrolling. Height follows the row count and is then
    /// clamped to 70% of the visible screen, because "fit the content" must not mean a
    /// panel taller than the display.
    private func preferredContentSize() -> NSSize {
        let headerHeight: CGFloat = 24
        let chrome: CGFloat = 76          // button row, insets, separator
        let contentHeight = CGFloat(max(rows.count, 6)) * tableView.rowHeight
            + headerHeight + chrome

        let screen = panel.screen ?? NSScreen.main
        let ceilingHeight = (screen?.visibleFrame.height ?? 900) * 0.7
        return NSSize(
            width: 560,
            height: min(max(contentHeight, 260), ceilingHeight)
        )
    }

    private func position(over window: NSWindow) {
        let hostFrame = window.frame
        let size = panel.frame.size
        var origin = NSPoint(x: hostFrame.maxX + 12, y: hostFrame.maxY - size.height)

        // Prefer sitting alongside the window; tuck inside its top-right corner when
        // that would push the panel off the screen.
        if let visible = window.screen?.visibleFrame, origin.x + size.width > visible.maxX {
            origin.x = max(visible.minX, hostFrame.maxX - size.width - 24)
            origin.y = hostFrame.maxY - size.height - 44
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: View construction

    override public func loadView() {
        configureTable()

        copyButton.target = self
        copyButton.action = #selector(copy(_:))
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Copy the selected rows, or all of them when nothing is selected."

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, copyButton])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 10, right: 12)

        let separator = NSBox()
        separator.boxType = .separator

        let root = NSView()
        for subview in [scrollView, separator, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // A scroll view has no intrinsic size, so a window sized from
        // `contentViewController` would collapse to nothing. These give the panel a
        // sensible opening size without pinning it there — the user can resize.
        let width = root.widthAnchor.constraint(equalToConstant: 560)
        let height = root.heightAnchor.constraint(equalToConstant: 480)
        width.priority = .defaultLow
        height.priority = .defaultLow
        NSLayoutConstraint.activate([width, height])

        view = root
    }

    private func configureTable() {
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "Name"
        name.width = 190
        name.minWidth = 90
        name.maxWidth = 400

        let value = NSTableColumn(identifier: Self.valueColumn)
        value.title = "Value"
        value.width = 340
        value.minWidth = 120

        tableView.addTableColumn(name)
        tableView.addTableColumn(value)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.style = .inset
        tableView.rowHeight = 18
        tableView.floatsGroupRows = false
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    override public func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: Commands

    /// `⌘C`, and the Copy button.
    ///
    /// Copies the selected rows, or the whole list when nothing is selected, as
    /// `Name: Value` lines — the format 7zFM's property list writes to the
    /// clipboard, with `\n` line endings instead of `\r\n` (PRP-07). Values are the
    /// full, untruncated ones, not the elided text on screen: a CRC list or an ACL
    /// pasted into a bug report is useless with ` ...` on the end.
    @objc private func copy(_ sender: Any?) {
        let selected = tableView.selectedRowIndexes
        let indexes = selected.isEmpty ? IndexSet(rows.indices) : selected

        let lines = indexes.compactMap { index -> String? in
            guard rows.indices.contains(index) else { return nil }
            switch rows[index] {
            case .section:
                return Self.sectionRule
            case .property(let property):
                return "\(property.name): \(property.value)"
            }
        }
        guard !lines.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// Double-click (and Return, via the table's default binding) opens the full
    /// value in a read-only viewer, because a `Method` chain or an NT security
    /// descriptor is routinely wider than any sane column (PRP-07).
    @objc private func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard rows.indices.contains(row), case .property(let property) = rows[row] else { return }
        presentValueViewer(for: property)
    }

    private func presentValueViewer(for property: Property) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        text.string = property.value
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 4, height: 4)

        let scroller = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 120))
        scroller.documentView = text
        scroller.hasVerticalScroller = true
        scroller.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = property.name
        alert.informativeText = ""
        alert.accessoryView = scroller
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel)
    }
}

// MARK: - Rows

extension PropertiesInspectorController {
    /// One line of the inspector.
    private enum Row {
        /// A section heading, drawn as a group row and copied as 7zFM's rule.
        case section(String)
        /// A `Name` / `Value` pair.
        case property(Property)
    }

    private struct Property {
        /// The property's display name — `PropID.displayName`, which *is* 7-Zip's
        /// own name for it, so an exotic key reads exactly as its handler spelt it.
        var name: String
        /// The full value. The table shows `PropertiesInspectorController.elide(_:)`
        /// of this; `⌘C` and the value viewer use it whole.
        var value: String
    }

    /// 7zFM's between-sections rule, reproduced verbatim in copied text.
    private static let sectionRule = "------------------------"

    private static func panelTitle(listing: ArchiveListing, entry: ArchiveEntry?) -> String {
        // Attacker-controlled: escaped for display (SECURITY.md §7).
        if let entry { return "\(PathNormalizer.displaySafe(entry.name)) — Properties" }
        return "\(listing.url.lastPathComponent) — Properties"
    }

    /// Assemble the whole list.
    ///
    /// Item first, then the archive, matching 7zFM's assembly order (item props →
    /// separator → archive-level props, PRP-05). The item is what the user is
    /// looking at; the archive is context.
    private static func buildRows(listing: ArchiveListing, entry: ArchiveEntry?) -> [Row] {
        var rows: [Row] = []

        if let entry {
            rows.append(.section("Item — \(PathNormalizer.displaySafe(entry.name))"))
            rows.append(contentsOf: entryRows(for: entry).map(Row.property))
        }

        rows.append(.section("Archive — \(listing.url.lastPathComponent)"))
        rows.append(contentsOf: archiveRows(for: listing).map(Row.property))
        return rows
    }

    /// The archive's own properties: the handler's bag, plus the totals the panel
    /// computes because no handler reports them.
    private static func archiveRows(for listing: ArchiveListing) -> [Property] {
        var builder = PropertyBagBuilder()

        builder.add(.path, listing.url.path)
        builder.add(.fileType, listing.format?.rawValue)

        // Counts and totals. These are ArcSeven's arithmetic over the member list,
        // not something `7zz l -slt` prints, so they are added before the bag and
        // the bag is not allowed to overwrite them.
        builder.add(.folders, listing.directoryCount.formatted(.number))
        builder.add(.files, listing.fileCount.formatted(.number))
        builder.add(.size, ColumnModel.groupedByteCount(listing.totalSize))

        // For a solid archive only the first member of each block carries a packed
        // size, so this sum is a floor rather than a total. Saying so beats printing
        // a number that does not add up against Physical Size.
        let packed = ColumnModel.groupedByteCount(listing.totalPackedSize)
        builder.add(.packedSize, listing.packedSizeIsPerBlock ? "\(packed) (per solid block)" : packed)

        builder.add(.physicalSize, listing.physicalSize.map(ColumnModel.groupedByteCount))
        builder.add(.headersSize, listing.headersSize.map(ColumnModel.groupedByteCount))
        builder.add(.numBlocks, listing.blockCount?.formatted(.number))
        builder.add(name: "Ratio", ratioText(listing.compressionRatio))
        builder.add(.solid, booleanMark(listing.isSolid))
        builder.add(.encrypted, booleanMark(listing.isEncrypted))

        // Only worth a row when true: a header-encrypted archive is the case where
        // even the file list was secret, which changes how the rest reads.
        if listing.isHeaderEncrypted {
            builder.add(name: "Header Encrypted", "+")
        }
        if listing.volumes.isMultiVolume {
            builder.add(.isVolume, "+")
            builder.add(.numVolumes, (listing.volumes.count ?? listing.volumes.urls.count).formatted(.number))
            builder.add(.volumeIndex, listing.volumes.index?.formatted(.number))
        }
        builder.add(.comment, listing.comment)

        // Everything the handler advertised that has not already been shown.
        builder.addRemainder(of: listing.properties)

        // Warnings last, one row each, using a synthetic name so several can coexist
        // — the bag is a dictionary and could only ever hold one.
        for warning in listing.warnings {
            builder.add(name: "Warning", warning.path.map { "\($0): \(warning.message)" } ?? warning.message)
        }
        return builder.rows
    }

    /// The selected member's properties.
    private static func entryRows(for entry: ArchiveEntry) -> [Property] {
        var builder = PropertyBagBuilder()

        builder.add(.path, entry.path)
        // Booleans are emitted here only when true, because that is how handlers
        // advertise them; when a handler *does* report `Folder = -` the bag pass
        // below prints it and the distinction between "false" and "not reported"
        // stays visible.
        if entry.isDirectory { builder.add(.isFolder, "+") }
        builder.add(.size, entry.size.map(ColumnModel.groupedByteCount))
        builder.add(.packedSize, entry.packedSize.map(ColumnModel.groupedByteCount))
        builder.add(name: "Ratio", ratioText(entry.compressionRatio))
        builder.add(.modified, entry.modified.map(timestampText))
        builder.add(.created, entry.created.map(timestampText))
        builder.add(.accessed, entry.accessed.map(timestampText))
        builder.add(.attributes, entry.attributes.raw)
        // 7-Zip prints a CRC-32 as eight uppercase hex digits, zero-padded, and
        // PRP-03 makes that uppercasing a rule for short checksums generally.
        builder.add(.crc, entry.crc.map { String(format: "%08X", $0) })
        builder.add(.method, entry.method)
        if entry.isEncrypted { builder.add(.encrypted, "+") }
        builder.add(.block, entry.blockIndex?.formatted(.number))
        builder.add(.hostOS, entry.hostOS)
        builder.add(.symbolicLink, entry.symlinkTarget)
        builder.add(.comment, entry.comment)

        builder.addRemainder(of: entry.properties)
        return builder.rows
    }

    // MARK: Value formatting

    private static func booleanMark(_ value: Bool) -> String { value ? "+" : "-" }

    private static func ratioText(_ ratio: Double?) -> String? {
        guard let ratio else { return nil }
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func timestampText(_ date: Date) -> String {
        date.formatted(date: .numeric, time: .standard)
    }

    /// PRP-06: values are collapsed to a single line and truncated past 1024
    /// characters. A comment or an ACL can run to kilobytes, and one row per
    /// property is what makes the list scannable.
    private static func elide(_ value: String) -> String {
        var single = value
        if single.contains(where: \.isNewline) {
            single = single.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        guard single.count > 1024 else { return single }
        return single.prefix(1024) + " ..."
    }

    // MARK: Bag assembly

    /// Accumulates `Name` / `Value` rows and remembers which properties have already
    /// been shown, so the handler's own bag can be poured in afterwards without
    /// producing a second row for anything the typed fields already covered.
    private struct PropertyBagBuilder {
        private(set) var rows: [Property] = []
        private var emitted: Set<PropID> = []

        /// Add a typed value under a real property identifier. A `nil` or empty value
        /// adds nothing *and does not mark the property as shown*, so the handler's bag
        /// still gets its chance to supply one.
        mutating func add(_ property: PropID, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            emitted.insert(property)
            rows.append(.init(name: property.displayName, value: value))
        }

        /// Add a row that has no `PropID` — a computed total, a warning.
        mutating func add(name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(.init(name: name, value: value))
        }

        /// Pour in every remaining key of a handler's property bag.
        ///
        /// Empty values are kept, not skipped: an empty string means the handler emitted
        /// the key with no value, which is a different fact from not emitting it at all,
        /// and the panel exists to report facts rather than tidy them.
        mutating func addRemainder(of bag: [PropID: String]) {
            for property in Self.ordered(Array(bag.keys)) where !emitted.contains(property) {
                emitted.insert(property)
                rows.append(.init(
                    name: property.displayName,
                    value: Self.displayValue(for: property, raw: bag[property] ?? "")
                ))
            }
        }

        /// Well-known properties in 7-Zip's own declaration order, then anything
        /// unrecognised, alphabetically. Same rule as
        /// `ArchiveListing.availableEntryProperties`, so the inspector and the column
        /// picker agree about ordering.
        private static func ordered(_ keys: [PropID]) -> [PropID] {
            let present = Set(keys)
            var result = PropID.wellKnown.filter { present.contains($0) }
            let extras = present.subtracting(result).map(\.rawValue).sorted().map(PropID.init(rawValue:))
            result.append(contentsOf: extras)
            return result
        }

        /// Render a raw bag value according to what kind of value the property is.
        ///
        /// Deliberately conservative: only byte counts and checksums are touched.
        /// Timestamps, attribute strings and 7-Zip's `+`/`-` booleans are already in the
        /// form 7-Zip prints them, and re-formatting a value we may not fully understand
        /// — the exotic-property case this panel exists for — would be worse than
        /// passing it through.
        private static func displayValue(for property: PropID, raw: String) -> String {
            switch property.valueKind {
            case .byteCount:
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard let bytes = UInt64(trimmed) else { return raw }
                return ColumnModel.groupedByteCount(bytes)
            case .checksum:
                return raw.uppercased()
            default:
                return raw
            }
        }
    }
}

// MARK: - Table data source and delegate

extension PropertiesInspectorController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
}

extension PropertiesInspectorController: NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard rows.indices.contains(row), case .section = rows[row] else { return false }
        return true
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), case .section = rows[row] else { return 18 }
        return 24
    }

    /// Section rows are never part of the selection, including under `⌘A`, so a
    /// copied dump never gains a stray rule row the user did not aim at.
    public func tableView(
        _ tableView: NSTableView,
        selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet
    ) -> IndexSet {
        IndexSet(proposedSelectionIndexes.filter { index in
            guard rows.indices.contains(index) else { return false }
            if case .section = rows[index] { return false }
            return true
        })
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row) else { return nil }

        switch rows[row] {
        case .section(let title):
            // A group row is asked for its view with a nil column, which is how one
            // cell spans the full width.
            guard tableColumn == nil else { return nil }
            let cell = reusableCell(identifier: NSUserInterfaceItemIdentifier("section"), bold: true)
            cell.textField?.stringValue = title
            return cell

        case .property(let property):
            guard let tableColumn else { return nil }
            let isName = tableColumn.identifier == Self.nameColumn
            let cell = reusableCell(identifier: tableColumn.identifier, bold: false)
            cell.textField?.stringValue = isName ? property.name : Self.elide(property.value)
            cell.textField?.textColor = isName ? .secondaryLabelColor : .labelColor
            cell.textField?.toolTip = isName ? nil : property.value
            return cell
        }
    }

    /// One reusable cell shape for the whole table: a single label pinned to its
    /// row. Reuse matters less here than in a panel listing 80,000 members, but the
    /// table is the same kind of object and behaves better for it.
    private func reusableCell(
        identifier: NSUserInterfaceItemIdentifier,
        bold: Bool
    ) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return existing
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let text = NSTextField(labelWithString: "")
        text.font = bold ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text

        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Panel lifetime

extension PropertiesInspectorController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        // Detach from the document window first: a child window that is closed while
        // still attached leaves the parent holding a reference to a hidden window,
        // and the parent then drags it back into view on the next move.
        hostWindow?.removeChildWindow(panel)
        hostWindow = nil
        selfRetain = nil
    }
}
