// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The preview itself: a header line and a table of members, or a single sentence when
// there is no table to draw.
//
// Two constraints shape every choice below.
//
// Appearance: a Quick Look preview is composited into the Finder's own panel, so it must
// follow the system appearance exactly. Every colour here is semantic - `.labelColor`,
// `.secondaryLabelColor`, `.textBackgroundColor`, `.separatorColor` - and every font comes
// from `NSFont.preferredFont(forTextStyle:)` rather than a hard point size, so the
// system's text-size setting scales the whole preview including the row heights, which are
// computed from the body font rather than nailed to 17pt. (macOS delivers no notification
// when that setting changes; an appex is spawned fresh for each preview, so it is read at
// launch and that is enough.)
//
// Cost: this view is built inside a short-lived, memory-capped extension. So: a plain
// view-based `NSTableView` with recycled cells rather than a stack of N rows, at most
// `PreviewLimits.maxRenderedEntries` of them, and file icons cached by extension so a
// 4000-row archive of `.png` files asks the workspace for one icon rather than 4000.

import AppKit
import UniformTypeIdentifiers

@MainActor
final class ArchiveListingView: NSView {
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")
    private static let sizeColumn = NSUserInterfaceItemIdentifier("size")

    /// Distinct file extensions we will keep icons for. Bounds the cache on an archive
    /// full of randomly-named members.
    private static let maxCachedIcons = 128

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let headerStack = NSStackView()
    private let separator = NSBox()

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private let messageStack = NSStackView()
    private let messageImageView = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    private var entries: [ArchiveDirectoryEntry] = []
    private var iconsByExtension: [String: NSImage] = [:]
    private lazy var folderIcon: NSImage = Self.resizedIcon(for: .folder)
    private lazy var genericIcon: NSImage = Self.resizedIcon(for: .data)

    // MARK: - Fonts and metrics, all derived from the user's text size

    private var bodyFont: NSFont { .preferredFont(forTextStyle: .body) }

    /// Digits are monospaced so a column of sizes lines up on the decimal point.
    private var sizeFont: NSFont {
        .monospacedDigitSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
    }

    private var rowHeight: CGFloat { ceil(bodyFont.boundingRectForFont.height) + 8 }

    private var iconSide: CGFloat { max(16, ceil(bodyFont.pointSize) + 2) }

    // MARK: - Construction

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        buildHeader()
        buildTable()
        buildMessage()
        installConstraints()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ArchiveListingView is created in code, never from a nib.")
    }

    private func buildHeader() {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.usesSingleLineMode = true

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.usesSingleLineMode = true

        noteLabel.font = .preferredFont(forTextStyle: .footnote)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // A stack rather than three stacked constraints, because `NSStackView` detaches a
        // hidden arranged subview from layout entirely. Pinning the separator below a
        // hidden `noteLabel` would still reserve a line's worth of empty space for it,
        // which is a visible hole under the header on every archive that has no note.
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.setViews([titleLabel, subtitleLabel, noteLabel], in: .leading)
        headerStack.setCustomSpacing(8, after: subtitleLabel)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerStack)
    }

    private func buildTable() {
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = "Name"
        name.minWidth = 120
        name.resizingMask = [.autoresizingMask, .userResizingMask]

        let size = NSTableColumn(identifier: Self.sizeColumn)
        size.title = "Size"
        size.width = 96
        size.minWidth = 72
        size.maxWidth = 160
        size.resizingMask = []

        tableView.addTableColumn(name)
        tableView.addTableColumn(size)
        tableView.headerView = nil          // Two columns; a header row would be noise.
        tableView.style = .plain            // Edge-to-edge, like the system's own previews.
        tableView.gridStyleMask = []
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = .clear
        // All spare width goes to the path column; the size column stays put.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
    }

    private func buildMessage() {
        messageImageView.imageScaling = .scaleProportionallyUpOrDown
        messageImageView.contentTintColor = .secondaryLabelColor

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center

        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 12
        messageStack.setViews([messageImageView, messageLabel], in: .center)
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.isHidden = true
        addSubview(messageStack)
    }

    private func installConstraints() {
        NSLayoutConstraint.activate([
            headerStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            headerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            titleLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),
            noteLabel.widthAnchor.constraint(equalTo: headerStack.widthAnchor),

            separator.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageStack.widthAnchor.constraint(lessThanOrEqualToConstant: 380),

            messageImageView.widthAnchor.constraint(equalToConstant: 40),
            messageImageView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - Appearance

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved inside the view's own appearance so the light and dark values are both
        // correct; a raw `.cgColor` read outside a drawing context resolves against
        // whatever appearance happens to be current, which in an appex is not ours.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Content

    /// Draw one parsed archive. Safe to call once; the preview is not re-used.
    func apply(_ directory: ArchiveDirectory) {
        titleLabel.stringValue = directory.displayName
        titleLabel.toolTip = directory.displayName
        subtitleLabel.stringValue = Self.subtitle(for: directory)

        entries = directory.entries
        tableView.rowHeight = rowHeight
        tableView.reloadData()

        if directory.hasListing {
            scrollView.isHidden = false
            messageStack.isHidden = true
            noteLabel.stringValue = directory.note ?? ""
            noteLabel.isHidden = directory.note == nil
        } else {
            // No rows: the whole preview is the explanation, so it goes in the middle of
            // the content area rather than in the header's small print.
            scrollView.isHidden = true
            messageStack.isHidden = false
            noteLabel.stringValue = ""
            noteLabel.isHidden = true

            let isFailure = directory.failure != nil
            messageLabel.stringValue = directory.failure
                ?? directory.note
                ?? "This archive has no files in it."
            messageImageView.image = NSImage(
                systemSymbolName: isFailure ? "exclamationmark.triangle" : "doc.zipper",
                accessibilityDescription: nil
            )
        }
    }

    /// A sensible size for the Quick Look panel: tall enough to show the listing, never
    /// taller than the screenful Quick Look would give it anyway.
    var preferredSize: NSSize {
        let visibleRows = CGFloat(min(entries.count, 14))
        let bodyHeight = entries.isEmpty ? 180 : max(120, visibleRows * rowHeight + 12)
        return NSSize(width: 620, height: min(620, headerHeight + bodyHeight))
    }

    /// Measured from the fonts rather than hard-coded, so that raising the system text size
    /// grows the header's reserved space along with the text inside it.
    private var headerHeight: CGFloat {
        func lineHeight(_ style: NSFont.TextStyle) -> CGFloat {
            ceil(NSFont.preferredFont(forTextStyle: style).boundingRectForFont.height)
        }
        var height: CGFloat = 14                       // top inset
        height += lineHeight(.headline) + 2 + lineHeight(.subheadline)
        if !noteLabel.isHidden {
            height += 8 + 2 * lineHeight(.footnote)    // notes wrap to two lines often enough
        }
        return height + 12 + 1                         // gap below the header, then the rule
    }

    private static func subtitle(for directory: ArchiveDirectory) -> String {
        var parts = [directory.format.displayName]

        if directory.countsAreKnown {
            parts.append(directory.fileCount == 1 ? "1 file" : "\(directory.fileCount.formatted(.number)) files")
            if directory.directoryCount > 0 {
                parts.append(
                    directory.directoryCount == 1
                        ? "1 folder"
                        : "\(directory.directoryCount.formatted(.number)) folders"
                )
            }
            if directory.fileCount > 0 {
                // The archive's own claim about its uncompressed total. Nothing here
                // decompresses anything, so it is not verified and is not presented as if
                // it were - it is simply what the directory says.
                parts.append(byteText(directory.totalUncompressedSize))
            }
        }

        parts.append("\(byteText(directory.archiveByteSize)) on disk")

        if directory.encryptedCount > 0 {
            parts.append(
                directory.encryptedCount == 1
                    ? "1 encrypted"
                    : "\(directory.encryptedCount.formatted(.number)) encrypted"
            )
        }
        if directory.isTruncated {
            parts.append("listing truncated")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// `FormatStyle`, not `ByteCountFormatter`: a formatter is a non-Sendable reference
    /// type, so it cannot be a shared `static let` under Swift 6, and building one per row
    /// is measurably expensive in a list this long.
    private static func byteText(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .file))
    }

    // MARK: - Icons

    private func icon(for entry: ArchiveDirectoryEntry) -> NSImage {
        if entry.isDirectory { return folderIcon }

        let fileExtension = (entry.path as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return genericIcon }
        if let cached = iconsByExtension[fileExtension] { return cached }

        let type = UTType(filenameExtension: fileExtension) ?? .data
        let image = Self.resizedIcon(for: type)
        if iconsByExtension.count < Self.maxCachedIcons {
            iconsByExtension[fileExtension] = image
        }
        return image
    }

    private static func resizedIcon(for type: UTType) -> NSImage {
        let image = NSWorkspace.shared.icon(for: type)
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

// MARK: - Table data

extension ArchiveListingView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }
}

extension ArchiveListingView: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        // `row` comes from AppKit and should always be in range, but the array it indexes
        // was built from a hostile file, so it is checked rather than assumed.
        guard row >= 0, row < entries.count, let identifier = tableColumn?.identifier else {
            return nil
        }
        let entry = entries[row]

        switch identifier {
        case Self.nameColumn:
            let cell = tableView.makeView(withIdentifier: Self.nameColumn, owner: self)
                as? NSTableCellView ?? makeNameCell()
            cell.imageView?.image = icon(for: entry)
            cell.textField?.font = bodyFont
            cell.textField?.stringValue = entry.path
            cell.textField?.textColor = entry.isDirectory ? .secondaryLabelColor : .labelColor
            cell.toolTip = entry.path
            return cell

        case Self.sizeColumn:
            let cell = tableView.makeView(withIdentifier: Self.sizeColumn, owner: self)
                as? NSTableCellView ?? makeSizeCell()
            cell.textField?.font = sizeFont
            // A directory has no meaningful size of its own; an em dash says that more
            // honestly than "Zero bytes".
            cell.textField?.stringValue = entry.isDirectory
                ? "\u{2014}"
                : Self.byteText(entry.uncompressedSize)
            cell.textField?.textColor = .secondaryLabelColor
            return cell

        default:
            return nil
        }
    }

    private func makeNameCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.nameColumn

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        // Truncating the HEAD keeps the filename visible on a deep in-archive path, which
        // is the part the user is reading. Truncating the tail would hide it.
        textField.lineBreakMode = .byTruncatingHead
        textField.cell?.usesSingleLineMode = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        let side = iconSide
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: side),
            imageView.heightAnchor.constraint(equalToConstant: side),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func makeSizeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.sizeColumn

        let textField = NSTextField(labelWithString: "")
        textField.alignment = .right
        textField.lineBreakMode = .byClipping
        textField.cell?.usesSingleLineMode = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
