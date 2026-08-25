// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Add to Archive: building the sheet.
//
// Split out of CompressDialogController.swift only because the whole dialog does not fit
// in one 500-line file. This half is construction and nothing else — every function here
// runs once, from `buildInterface()`, and returns a finished view. The regions are the
// Windows dialog's own, in its order; see the file header of CompressDialogController.swift
// for why the grid is `NSGridView` and the hideable rows are `NSStackView`.

import AppKit

extension CompressDialogController {
    // MARK: - Interface construction

    /// Build the sheet.
    ///
    /// The blocks below are the Windows dialog's own regions, in its own order: the
    /// archive path across the top, the two parameter columns, encryption, volumes and
    /// parameters, then the buttons. Each returns its finished view and touches nothing
    /// outside it, so the assembly at the end is the only place layout is wired together.
    func buildInterface() {
        let header = NSTextField(labelWithString: "Add to Archive")
        header.font = .boldSystemFont(ofSize: 13)

        let archiveGrid = makeArchiveRow()
        let columns = makeParameterColumns()
        let encryptionSection = makeEncryptionSection()
        let (bottomStack, parametersRow) = makeVolumeAndParameterRows()
        let buttons = makeButtonRow()

        // --- Assembly --------------------------------------------------------------------
        let root = NSStackView(views: [
            header, archiveGrid, columns, encryptionSection, bottomStack, buttons,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        // `columns` is the widest row and therefore sets the dialog's width. Stretching
        // the full-width rows to *it* rather than to the enclosing stack keeps the width
        // derivation one-directional: tie a child to its parent's width and the parent's
        // fitting size becomes self-referential, which is how a sheet ends up sized to a
        // fraction of its content with everything drawn on top of everything else.
        NSLayoutConstraint.activate([
            archiveGrid.widthAnchor.constraint(equalTo: columns.widthAnchor),
            bottomStack.widthAnchor.constraint(equalTo: columns.widthAnchor),
            parametersRow.widthAnchor.constraint(equalTo: columns.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: columns.widthAnchor),
        ])

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        sheet.contentView = content
        contentRoot = content
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
    }

    private func makeArchiveRow() -> NSGridView {
        // --- Archive path ------------------------------------------------------------
        archiveField.delegate = self
        archiveField.lineBreakMode = .byTruncatingHead
        archiveField.translatesAutoresizingMaskIntoConstraints = false
        archiveField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        browseButton.target = self
        browseButton.action = #selector(browsePressed(_:))
        browseButton.bezelStyle = .rounded

        let archiveGrid = makeGrid([
            [label("Archive:"), archiveField, browseButton]
        ])
        // The path is the one field worth every spare pixel: archive paths are long and
        // the interesting end is the last component.
        archiveGrid.column(at: 1).xPlacement = .fill
        return archiveGrid
    }

    /// The two parameter columns, side by side: what the bytes look like on the left,
    /// which files go in on the right.
    private func makeParameterColumns() -> NSStackView {
        let leftGrid = makeCompressionGrid()
        let rightStack = makeFileSelectionStack()

        let columns = NSStackView(views: [leftGrid, rightStack])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 32
        return columns
    }

    private func makeCompressionGrid() -> NSGridView {
        // --- Left column: what the bytes end up looking like --------------------------
        configure(formatPopup, action: #selector(formatChanged(_:)))
        configure(levelPopup, action: #selector(levelChanged(_:)))
        configure(methodPopup, action: #selector(methodChanged(_:)))
        configure(dictionaryPopup, action: #selector(dictionaryChanged(_:)))
        configure(wordSizePopup, action: #selector(wordSizeChanged(_:)))
        configure(solidPopup, action: #selector(solidChanged(_:)))
        configure(threadsPopup, action: #selector(threadsChanged(_:)))

        threadsHint.font = .systemFont(ofSize: 11)
        threadsHint.textColor = .secondaryLabelColor
        let threadsRow = NSStackView(views: [threadsPopup, threadsHint])
        threadsRow.orientation = .horizontal
        threadsRow.spacing = 6
        threadsRow.alignment = .firstBaseline

        for value in [compressMemoryLabel, decompressMemoryLabel] {
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        let leftGrid = makeGrid([
            [label("Archive format:"), formatPopup],
            [label("Compression level:"), levelPopup],
            [label("Compression method:"), methodPopup],
            [label("Dictionary size:"), dictionaryPopup],
            [label("Word size:"), wordSizePopup],
            [label("Solid Block size:"), solidPopup],
            [label("Number of CPU threads:"), threadsRow],
            [label("Memory usage for Compressing:"), compressMemoryLabel],
            [label("Memory usage for Decompressing:"), decompressMemoryLabel],
        ])
        return leftGrid
    }

    private func makeFileSelectionStack() -> NSStackView {
        // --- Right column: which files, and what rides along with them ----------------
        configure(updateModePopup, action: #selector(updateModeChanged(_:)))
        configure(pathModePopup, action: #selector(pathModeChanged(_:)))

        let rightGrid = makeGrid([
            [label("Update mode:"), updateModePopup],
            [label("Path mode:"), pathModePopup],
        ])

        sfxCheckbox.target = self
        sfxCheckbox.action = #selector(sfxToggled(_:))
        sfxNote.font = .systemFont(ofSize: 11)
        sfxNote.textColor = .secondaryLabelColor
        deleteCheckbox.target = self
        deleteCheckbox.action = #selector(deleteToggled(_:))
        let optionsSection = section("Options", [sfxCheckbox, sfxNote, deleteCheckbox])

        for checkbox in [symlinkCheckbox, hardLinkCheckbox, xattrCheckbox, posixCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(macOSMetadataToggled(_:))
        }
        // Windows calls this group `NTFS`. Naming it after a filesystem the user's disk
        // does not have would be worse than useless, so it is named after the platform
        // whose metadata these four checkboxes actually store (D-04).
        let macOSSection = section(
            "macOS", [symlinkCheckbox, hardLinkCheckbox, xattrCheckbox, posixCheckbox])

        let rightStack = NSStackView(views: [rightGrid, optionsSection, macOSSection])
        rightStack.orientation = .vertical
        rightStack.alignment = .leading
        rightStack.spacing = 16
        return rightStack
    }

    private func makeEncryptionSection() -> NSStackView {
        // --- Encryption ---------------------------------------------------------------
        passwordSecureField.delegate = self
        passwordPlainField.delegate = self
        verifyField.delegate = self
        showPasswordCheckbox.target = self
        showPasswordCheckbox.action = #selector(showPasswordToggled(_:))
        configure(encryptionMethodPopup, action: #selector(encryptionMethodChanged(_:)))
        encryptNamesCheckbox.target = self
        encryptNamesCheckbox.action = #selector(encryptNamesToggled(_:))
        passwordErrorLabel.font = .systemFont(ofSize: 11)
        passwordErrorLabel.textColor = .systemRed

        // The masked and the legible passphrase field get a row each and take it in
        // turns to be hidden, so the caret never has to move between two views that
        // claim the same cell.
        for field in [passwordSecureField, passwordPlainField, verifyField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }

        let secureLabel = label("Enter password:")
        let plainLabel = label("Enter password:")
        let verifyLabel = label("Reenter password:")
        let methodLabel = label("Encryption method:")
        let spacerLabels = [label(""), label(""), label("")]
        let formLabels = [secureLabel, plainLabel, verifyLabel, methodLabel] + spacerLabels

        // One measured width for the whole group, so the fields line up the way an
        // NSGridView column would without a grid's hidden-row behaviour. Measured from
        // the labels themselves rather than hard-coded, so it follows the system font.
        let labelWidth = ceil(formLabels.map(\.intrinsicContentSize.width).max() ?? 0)
        for text in formLabels {
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            text.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        }

        let secure = formRow(secureLabel, passwordSecureField)
        let plain = formRow(plainLabel, passwordPlainField)
        let verify = formRow(verifyLabel, verifyField)
        let showRow = formRow(spacerLabels[0], showPasswordCheckbox)
        let methodRow = formRow(methodLabel, encryptionMethodPopup)
        let namesRow = formRow(spacerLabels[1], encryptNamesCheckbox)
        let errorRow = formRow(spacerLabels[2], passwordErrorLabel)
        secureRow = secure
        plainRow = plain
        verifyRow = verify
        encryptNamesRow = namesRow
        passwordErrorRow = errorRow

        let encryptionSection = section(
            "Encryption", [secure, plain, verify, showRow, methodRow, namesRow, errorRow])
        return encryptionSection
    }

    /// The volume and parameters rows.
    ///
    /// Returns the parameters row as well as the stack: the assembly ties it to the
    /// dialog's width separately, so that one row is allowed to stretch.
    private func makeVolumeAndParameterRows() -> (stack: NSStackView, parametersRow: NSStackView) {
        // --- Volumes and parameters ----------------------------------------------------
        volumeCombo.isEditable = true
        volumeCombo.completes = false
        volumeCombo.usesDataSource = false
        volumeCombo.delegate = self
        volumeCombo.target = self
        volumeCombo.action = #selector(volumeComboAction(_:))
        volumeCombo.addItems(withObjectValues: CompressDialogModel.VolumeSizeGrammar.presets)
        volumeCombo.translatesAutoresizingMaskIntoConstraints = false
        volumeCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        volumeErrorLabel.font = .systemFont(ofSize: 11)
        volumeErrorLabel.textColor = .systemRed

        parametersField.delegate = self
        parametersField.placeholderString = "e.g. x=9 tc=off  (a bare token is read as -m…)"
        parametersField.translatesAutoresizingMaskIntoConstraints = false
        parametersField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        // Stack rows again rather than a grid, for the same reason as the encryption
        // block: the inline volume error is a row that comes and goes, and only a stack
        // gives its height back cleanly when it does.
        let volumeLabel = label("Split to volumes, bytes:")
        let parametersLabel = label("Parameters:")
        let volumeSpacer = label("")
        let bottomLabels = [volumeLabel, parametersLabel, volumeSpacer]
        let bottomLabelWidth = ceil(bottomLabels.map(\.intrinsicContentSize.width).max() ?? 0)
        for text in bottomLabels {
            text.alignment = .right
            text.translatesAutoresizingMaskIntoConstraints = false
            text.widthAnchor.constraint(equalToConstant: bottomLabelWidth).isActive = true
        }

        let volumeRow = formRow(volumeLabel, volumeCombo)
        let volumeError = formRow(volumeSpacer, volumeErrorLabel)
        let parametersRow = formRow(parametersLabel, parametersField)
        volumeErrorRow = volumeError

        let bottomStack = NSStackView(views: [volumeRow, volumeError, parametersRow])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .leading
        bottomStack.spacing = 8

        // Parameters is a free-text field: give it every pixel the dialog has spare.
        parametersField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return (bottomStack, parametersRow)
    }

    private func makeButtonRow() -> NSStackView {
        // --- Buttons -------------------------------------------------------------------
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        okButton.target = self
        okButton.action = #selector(okPressed(_:))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 12
        // Gravity areas rather than a spacer view: the trailing area is where a sheet's
        // accept/cancel pair belongs, and it survives a width change without a
        // hugging-priority fight.
        buttons.addView(cancelButton, in: .trailing)
        buttons.addView(okButton, in: .trailing)
        return buttons
    }

    // MARK: - Interface helpers

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func makeGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        return grid
    }

    private func configure(_ popup: NSPopUpButton, action: Selector) {
        popup.target = self
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
    }

    /// One label-plus-control line, aligned on the control's first baseline.
    ///
    /// Used where a row has to be hidden at runtime; elsewhere `makeGrid` is a better
    /// fit because it aligns columns across the whole block.
    private func formRow(_ text: NSTextField, _ control: NSView) -> NSStackView {
        let row = NSStackView(views: [text, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    /// A titled group of controls.
    ///
    /// 7zFM draws these as Win32 groupboxes. `NSBox` is the literal translation and the
    /// wrong one: it takes its content view's frame back under autoresizing, so a box
    /// wrapping an auto-layout stack collapses to its title rule with the controls drawn
    /// outside it. A quiet heading over an indented stack is both what modern macOS
    /// sheets look like and what actually sizes itself.
    private func section(_ title: String, _ views: [NSView]) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        let body = NSStackView(views: views)
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6
        body.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)

        let group = NSStackView(views: [heading, body])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        return group
    }
}
