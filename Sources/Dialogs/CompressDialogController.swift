// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Add to Archive — 7zFM's `IDD_COMPRESS`, the densest dialog in the application.
//
// The Windows resource is a two-column grid of raw dialog units: the left column
// carries the compression parameters, the right carries update mode, path mode and the
// options group, and an encryption groupbox spans the bottom. That arrangement is kept
// here, because it is what makes the dialog readable at a glance — the knobs that
// change the *bytes* on the left, the knobs that change *which files* on the right —
// but it is laid out in `NSGridView` at AppKit metrics rather than in dialog units, so
// the labels align on the baseline grid, the controls are system-sized, and the sheet
// grows with the system font instead of clipping.
//
// Three deliberate departures from a literal transcription:
//
//   * The NTFS group becomes a macOS group (docs/DIVERGENCES.md D-04). Alternate data
//     streams and NT security descriptors name storage APFS does not have; symbolic
//     links, hard links, extended attributes and POSIX permissions are the concepts
//     that actually exist on the user's disk.
//   * Volume-size errors are shown inline under the combo as you type, rather than
//     only as a modal on OK. 7-Zip validates at OK because Win32 combo boxes have no
//     natural place to put a message; a sheet does.
//   * The memory read-outs are labelled as estimates. See `estimateMemory()` in
//     CompressDialogModel.swift for exactly how approximate they are.
//
// This controller never runs the operation. It hands back a `CompressRequest` and
// forgets about it, which is what keeps it testable and what lets the same request be
// produced from a script, a Quick Action or a drag-and-drop without going near AppKit.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

@MainActor
public final class CompressDialogController: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {

    // MARK: - State

    private var model: CompressDialogModel

    /// The state as it stood when OK was pressed.
    ///
    /// `CompressRequest` has no field for macOS extended attributes — capturing those
    /// is engine work that the console tool cannot do (D-17) — so a caller that wants
    /// the full picture reads it from here after the completion handler fires.
    public private(set) var resolvedModel: CompressDialogModel?

    /// Windows PE self-extractor stub, if the user has pointed Settings at one.
    ///
    /// `nil` on a stock install: no stub ships in the bundle (D-07), so checking
    /// `Create SFX archive` renames the output to `.exe` and produces a request with no
    /// module. The note beside the checkbox says so rather than letting it look armed.
    public var selfExtractingModuleURL: URL? {
        didSet {
            model.selfExtractingModuleURL = selfExtractingModuleURL
            refresh()
        }
    }

    private var completion: (@MainActor (CompressRequest?) -> Void)?
    private weak var host: NSWindow?

    /// Held for the lifetime of the sheet so a caller that does not retain the
    /// controller — the common case, `CompressDialogController(...).present(in:)` —
    /// does not have it deallocated out from under the sheet. Cleared in `finish`.
    private var selfRetain: CompressDialogController?

    // MARK: - Controls

    private let sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let archiveField = NSTextField(string: "")
    private let browseButton = NSButton(title: "Browse…", target: nil, action: nil)

    private let formatPopup = NSPopUpButton()
    private let levelPopup = NSPopUpButton()
    private let methodPopup = NSPopUpButton()
    private let dictionaryPopup = NSPopUpButton()
    private let wordSizePopup = NSPopUpButton()
    private let solidPopup = NSPopUpButton()
    private let threadsPopup = NSPopUpButton()
    private let threadsHint = NSTextField(labelWithString: "")

    private let compressMemoryLabel = NSTextField(labelWithString: "?")
    private let decompressMemoryLabel = NSTextField(labelWithString: "?")

    private let updateModePopup = NSPopUpButton()
    private let pathModePopup = NSPopUpButton()

    private let sfxCheckbox = NSButton(checkboxWithTitle: "Create SFX archive", target: nil, action: nil)
    private let sfxNote = NSTextField(labelWithString: "No SFX module configured.")
    private let deleteCheckbox = NSButton(
        checkboxWithTitle: "Delete files after compression", target: nil, action: nil)

    private let symlinkCheckbox = NSButton(checkboxWithTitle: "Store symbolic links", target: nil, action: nil)
    private let hardLinkCheckbox = NSButton(checkboxWithTitle: "Store hard links", target: nil, action: nil)
    private let xattrCheckbox = NSButton(checkboxWithTitle: "Store extended attributes", target: nil, action: nil)
    private let posixCheckbox = NSButton(checkboxWithTitle: "Store POSIX permissions", target: nil, action: nil)

    private let passwordSecureField = NSSecureTextField(string: "")
    private let passwordPlainField = NSTextField(string: "")
    private let verifyField = NSSecureTextField(string: "")
    private let showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password", target: nil, action: nil)
    private let encryptionMethodPopup = NSPopUpButton()
    private let encryptNamesCheckbox = NSButton(checkboxWithTitle: "Encrypt file names", target: nil, action: nil)
    private let passwordErrorLabel = NSTextField(labelWithString: "")

    /// The sheet's content view, kept so the sheet can be resized to it whenever a row
    /// appears or disappears.
    private var contentRoot: NSView?

    private let volumeCombo = NSComboBox()
    private let volumeErrorLabel = NSTextField(labelWithString: "")
    private let parametersField = NSTextField(string: "")

    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Rows that are hidden rather than disabled, matching 7zFM: the reenter field
    // disappears with Show Password (ADD-33), and `Encrypt file names` exists only for
    // handlers that have header encryption at all (ADD-31).
    //
    // These are stack rows, not `NSGridRow`s. A hidden grid row does not reliably give
    // its height back — the reclaimed space reappears further down the grid — whereas
    // NSStackView drops a hidden arranged view from the layout completely, which is the
    // behaviour a dialog that hides two of its rows depends on.
    private var secureRow: NSStackView?
    private var plainRow: NSStackView?
    private var verifyRow: NSStackView?
    private var encryptNamesRow: NSStackView?
    private var passwordErrorRow: NSStackView?
    private var volumeErrorRow: NSStackView?

    // MARK: - Construction

    public init(defaultArchiveURL: URL, inputs: [URL]) {
        model = CompressDialogModel(defaultArchiveURL: defaultArchiveURL, inputs: inputs)
        super.init()
        buildInterface()
        refresh()
    }

    // MARK: - Presentation

    /// Run the dialog as a sheet on `window`.
    ///
    /// `completion` receives `nil` when the user cancels, and a fully populated
    /// request when they accept. It is called exactly once.
    public func present(
        in window: NSWindow,
        completion: @escaping @MainActor (CompressRequest?) -> Void
    ) {
        host = window
        self.completion = completion
        selfRetain = self
        refresh()
        window.beginSheet(sheet)
        // The path is the one field a user is most likely to want to correct first.
        sheet.makeFirstResponder(archiveField)
    }

    private func finish(with request: CompressRequest?) {
        resolvedModel = model

        let handler = completion
        completion = nil
        host?.endSheet(sheet)
        sheet.orderOut(nil)

        // Keep the last strong reference alive until the handler has run: it may be the
        // only thing holding this controller, and the handler is entitled to read
        // `resolvedModel` off it.
        let keepAlive = selfRetain
        selfRetain = nil
        handler?(request)
        withExtendedLifetime(keepAlive) {}
    }

    // MARK: - Interface construction

    private func buildInterface() {
        let header = NSTextField(labelWithString: "Add to Archive")
        header.font = .boldSystemFont(ofSize: 13)

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

        let columns = NSStackView(views: [leftGrid, rightStack])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 32

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

    /// Repopulate a popup without letting `NSPopUpButton.addItem(withTitle:)` dedupe.
    ///
    /// That method removes an existing item with the same title, which would silently
    /// collapse two legitimately identical entries — and leave the index-to-value
    /// mapping the actions rely on off by one.
    private func apply(_ popup: NSPopUpButton, titles: [String], selectedIndex: Int, enabled: Bool) {
        let menu = NSMenu()
        if titles.isEmpty {
            // An empty popup renders as a bare chevron; a dash reads as "not applicable".
            menu.addItem(NSMenuItem(title: "—", action: nil, keyEquivalent: ""))
        } else {
            for title in titles {
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        popup.menu = menu
        popup.selectItem(at: min(max(selectedIndex, 0), menu.numberOfItems - 1))
        popup.isEnabled = enabled && !titles.isEmpty
    }

    // MARK: - Redraw

    /// Rebuild every control from the model.
    ///
    /// Programmatic changes to popups, checkboxes and text fields do not fire their
    /// actions, so this cannot recurse — which is what lets every action handler end
    /// with an unconditional `refresh()` and stop worrying about ordering.
    private func refresh() {
        let availability = model.availability

        if archiveField.stringValue != model.archivePath {
            archiveField.stringValue = model.archivePath
        }

        // Format.
        let formats = model.availableFormats
        apply(
            formatPopup,
            titles: formats.map { FormatCatalog.creatable($0)?.displayName ?? $0.rawValue },
            selectedIndex: formats.firstIndex(of: model.format) ?? 0,
            enabled: formats.count > 1
        )

        // Level.
        let levels = model.levelChoices
        apply(
            levelPopup,
            titles: levels.map(\.displayName),
            selectedIndex: levels.firstIndex(of: model.level) ?? 0,
            enabled: availability.levelEnabled
        )

        // Method. Index 0 carries the `*  ` prefix and means "emit nothing".
        let methods = model.methodChoices
        let methodTitles = methods.enumerated().map { index, method in
            index == 0 ? "*  " + method.rawValue : method.rawValue
        }
        let methodIndex = model.method.flatMap { methods.firstIndex(of: $0) } ?? 0
        apply(methodPopup, titles: methodTitles, selectedIndex: methodIndex, enabled: availability.methodEnabled)

        // Dictionary size.
        let dictionaries = model.dictionaryChoices
        var dictionaryTitles: [String] = []
        if !dictionaries.isEmpty {
            let auto = FormatCatalog.automaticDictionarySize(
                format: model.format, method: model.method, level: model.level)
            dictionaryTitles.append("*  " + (auto.map(CompressDialogModel.dictionaryLabel) ?? ""))
            dictionaryTitles.append(contentsOf: dictionaries.map(CompressDialogModel.dictionaryLabel))
        }
        let dictionaryIndex = model.dictionarySize.byteValue
            .flatMap { dictionaries.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        apply(
            dictionaryPopup,
            titles: dictionaryTitles,
            selectedIndex: dictionaryIndex,
            enabled: availability.dictionaryEnabled
        )

        // Word size — "fast bytes" for the LZ codecs, model order for PPMd (ADD-15).
        let words = model.wordSizeChoices
        var wordTitles: [String] = []
        if !words.isEmpty {
            let auto = FormatCatalog.automaticWordSize(
                format: model.format, method: model.method, level: model.level)
            wordTitles.append("*  " + (auto.map(String.init) ?? ""))
            wordTitles.append(contentsOf: words.map(String.init))
        }
        let wordIndex = model.wordSize.intValue.flatMap { words.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        apply(wordSizePopup, titles: wordTitles, selectedIndex: wordIndex, enabled: availability.wordSizeEnabled)

        // Solid block size.
        let solids = model.solidChoices
        apply(
            solidPopup,
            titles: solids.map(CompressDialogModel.solidLabel),
            selectedIndex: solids.firstIndex(of: model.solidBlockSize) ?? 0,
            enabled: availability.solidEnabled
        )

        // Threads.
        let threadChoices = model.threadChoices
        var threadTitles: [String] = []
        if !threadChoices.isEmpty {
            threadTitles.append("*  \(FormatCatalog.automaticThreads(format: model.format, method: model.method, hardwareThreads: model.hardwareThreads))")
            threadTitles.append(contentsOf: threadChoices.map(String.init))
        }
        let threadIndex = model.threads.intValue
            .flatMap { threadChoices.firstIndex(of: $0) }
            .map { $0 + 1 } ?? 0
        apply(threadsPopup, titles: threadTitles, selectedIndex: threadIndex, enabled: availability.threadsEnabled)
        threadsHint.stringValue = "/ \(model.hardwareThreads)"

        // Update and path mode.
        let updateModes = model.updateModeChoices
        apply(
            updateModePopup,
            titles: updateModes.map(\.displayName),
            selectedIndex: updateModes.firstIndex(of: model.updateMode) ?? 0,
            enabled: availability.updateModeEnabled
        )
        let pathModes = CompressPathMode.allCases
        apply(
            pathModePopup,
            titles: pathModes.map(\.displayName),
            selectedIndex: pathModes.firstIndex(of: model.pathMode) ?? 0,
            enabled: availability.pathModeEnabled
        )

        // Options.
        sfxCheckbox.isEnabled = availability.selfExtractingEnabled
        sfxCheckbox.state = model.createSelfExtracting ? .on : .off
        sfxNote.isHidden = !(model.createSelfExtracting && model.selfExtractingModuleURL == nil)
        deleteCheckbox.state = model.deleteSourcesAfterCompression ? .on : .off

        symlinkCheckbox.isEnabled = availability.symbolicLinksEnabled
        symlinkCheckbox.state = model.storeSymbolicLinks ? .on : .off
        hardLinkCheckbox.isEnabled = availability.hardLinksEnabled
        hardLinkCheckbox.state = model.storeHardLinks ? .on : .off
        xattrCheckbox.isEnabled = availability.extendedAttributesEnabled
        xattrCheckbox.state = model.storeExtendedAttributes ? .on : .off
        posixCheckbox.isEnabled = availability.posixPermissionsEnabled
        posixCheckbox.state = model.storePOSIXPermissions ? .on : .off

        // Encryption.
        let encryptionEnabled = availability.encryptionEnabled
        for control in [passwordSecureField, passwordPlainField, verifyField] as [NSTextField] {
            control.isEnabled = encryptionEnabled
        }
        showPasswordCheckbox.isEnabled = encryptionEnabled
        encryptionMethodPopup.isEnabled = encryptionEnabled
        encryptNamesCheckbox.isEnabled = encryptionEnabled

        if passwordSecureField.stringValue != model.password { passwordSecureField.stringValue = model.password }
        if passwordPlainField.stringValue != model.password { passwordPlainField.stringValue = model.password }
        if verifyField.stringValue != model.verifyPassword { verifyField.stringValue = model.verifyPassword }
        secureRow?.isHidden = model.showPassword
        plainRow?.isHidden = !model.showPassword
        showPasswordCheckbox.state = model.showPassword ? .on : .off
        verifyRow?.isHidden = model.showPassword

        let ciphers = model.descriptor?.encryptionMethods ?? []
        apply(
            encryptionMethodPopup,
            titles: ciphers.map(\.rawValue),
            selectedIndex: ciphers.firstIndex(of: model.encryptionMethod) ?? 0,
            // Enabled whenever the group is, even with a single cipher: 7z's list is
            // just AES-256, and greying it out would read as "unavailable" rather than
            // "there is nothing else to pick".
            enabled: encryptionEnabled
        )
        encryptNamesRow?.isHidden = !availability.encryptFileNamesShown
        encryptNamesCheckbox.state = model.encryptFileNames ? .on : .off

        // Volumes and parameters.
        volumeCombo.isEnabled = availability.volumesEnabled
        if volumeCombo.stringValue != model.volumeText { volumeCombo.stringValue = model.volumeText }
        if parametersField.stringValue != model.parametersText {
            parametersField.stringValue = model.parametersText
        }

        refreshMemory()
        refreshValidation()
    }

    private func refreshMemory() {
        let estimate = model.estimateMemory()
        let ram = ProcessInfo.processInfo.physicalMemory
        // 7-Zip shows `required / limit / RAM`; without a memory-limit control the
        // useful comparison is against the machine, so the RAM figure stays.
        compressMemoryLabel.stringValue =
            "\(CompressDialogModel.memoryLabel(estimate.compressing)) / \(CompressDialogModel.memoryLabel(ram))"
        decompressMemoryLabel.stringValue = CompressDialogModel.memoryLabel(estimate.decompressing)
    }

    private func refreshValidation() {
        let volumeFailure = model.volumeSizeError
        volumeErrorLabel.stringValue = volumeFailure?.errorDescription ?? ""
        volumeErrorRow?.isHidden = volumeFailure == nil

        let passwordFailure = model.passwordError
        passwordErrorLabel.stringValue = passwordFailure?.errorDescription ?? ""
        passwordErrorRow?.isHidden = passwordFailure == nil

        // Only the two conditions that can never produce a runnable command block OK.
        // Everything else 7-Zip validates on OK, and so do we — see `okPressed`.
        let pathEmpty = model.archivePath.trimmingCharacters(in: .whitespaces).isEmpty
        okButton.isEnabled = !pathEmpty && volumeFailure == nil

        resizeSheetToFit()
    }

    /// Track the content's height as rows come and go.
    ///
    /// Hiding the reenter field or an inline error changes how tall the dialog needs to
    /// be. Without this the sheet keeps whatever height it had at build time and the
    /// stack pads the difference out between its gravity areas — which shows up as an
    /// odd gap under the archive path when the encryption group shrinks.
    private func resizeSheetToFit() {
        guard let contentRoot else { return }
        contentRoot.layoutSubtreeIfNeeded()
        let wanted = contentRoot.fittingSize
        let current = sheet.contentLayoutRect.size
        guard abs(wanted.height - current.height) > 0.5 || abs(wanted.width - current.width) > 0.5 else {
            return
        }
        sheet.setContentSize(wanted)
    }

    // MARK: - Actions

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        let formats = model.availableFormats
        guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
        model.applyFormat(formats[sender.indexOfSelectedItem])
        refresh()
    }

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        let levels = model.levelChoices
        guard levels.indices.contains(sender.indexOfSelectedItem) else { return }
        model.level = levels[sender.indexOfSelectedItem]
        model.reconcile()
        refresh()
    }

    @objc private func methodChanged(_ sender: NSPopUpButton) {
        let methods = model.methodChoices
        let index = sender.indexOfSelectedItem
        // Index 0 is the `*` entry: keep `nil` so no method property is emitted and the
        // handler picks its own default, which is what 7-Zip means by that asterisk.
        model.method = index <= 0 ? nil : (methods.indices.contains(index) ? methods[index] : nil)
        model.reconcile()
        refresh()
    }

    @objc private func dictionaryChanged(_ sender: NSPopUpButton) {
        let choices = model.dictionaryChoices
        let index = sender.indexOfSelectedItem - 1
        model.dictionarySize = choices.indices.contains(index) ? .bytes(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc private func wordSizeChanged(_ sender: NSPopUpButton) {
        let choices = model.wordSizeChoices
        let index = sender.indexOfSelectedItem - 1
        model.wordSize = choices.indices.contains(index) ? .value(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc private func solidChanged(_ sender: NSPopUpButton) {
        let choices = model.solidChoices
        guard choices.indices.contains(sender.indexOfSelectedItem) else { return }
        model.solidBlockSize = choices[sender.indexOfSelectedItem]
        model.reconcile()
        refresh()
    }

    @objc private func threadsChanged(_ sender: NSPopUpButton) {
        let choices = model.threadChoices
        let index = sender.indexOfSelectedItem - 1
        model.threads = choices.indices.contains(index) ? .count(choices[index]) : .automatic
        model.reconcile()
        refresh()
    }

    @objc private func updateModeChanged(_ sender: NSPopUpButton) {
        let modes = model.updateModeChoices
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        model.updateMode = modes[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func pathModeChanged(_ sender: NSPopUpButton) {
        let modes = CompressPathMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else { return }
        model.pathMode = modes[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func sfxToggled(_ sender: NSButton) {
        model.setSelfExtracting(sender.state == .on)
        refresh()
    }

    @objc private func deleteToggled(_ sender: NSButton) {
        model.deleteSourcesAfterCompression = sender.state == .on
        refresh()
    }

    @objc private func macOSMetadataToggled(_ sender: NSButton) {
        switch sender {
        case symlinkCheckbox:  model.storeSymbolicLinks = sender.state == .on
        case hardLinkCheckbox: model.storeHardLinks = sender.state == .on
        case xattrCheckbox:    model.storeExtendedAttributes = sender.state == .on
        case posixCheckbox:    model.storePOSIXPermissions = sender.state == .on
        default: return
        }
        refresh()
    }

    @objc private func showPasswordToggled(_ sender: NSButton) {
        model.showPassword = sender.state == .on
        // Dropping the reenter field also drops the match requirement, so anything
        // already typed there stops mattering; clearing it avoids a stale mismatch
        // reappearing if the user turns the checkbox back off.
        if model.showPassword { model.verifyPassword = "" }
        refresh()
    }

    @objc private func encryptionMethodChanged(_ sender: NSPopUpButton) {
        let ciphers = model.descriptor?.encryptionMethods ?? []
        guard ciphers.indices.contains(sender.indexOfSelectedItem) else { return }
        model.encryptionMethod = ciphers[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func encryptNamesToggled(_ sender: NSButton) {
        model.encryptFileNames = sender.state == .on
        refresh()
    }

    @objc private func volumeComboAction(_ sender: NSComboBox) {
        model.volumeText = sender.stringValue
        refreshValidation()
    }

    @objc private func browsePressed(_ sender: Any?) {
        let save = NSSavePanel()
        save.title = "Browse"
        save.canCreateDirectories = true
        // Extensions are managed by the Format popup, not by the panel, so nothing is
        // appended behind the user's back.
        save.allowsOtherFileTypes = true

        let current = URL(fileURLWithPath: (model.archivePath as NSString).expandingTildeInPath)
        save.directoryURL = current.deletingLastPathComponent()
        save.nameFieldStringValue = current.lastPathComponent

        save.beginSheetModal(for: sheet) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .OK, let url = save.url else { return }
                self.model.archivePath = url.path
                // Picking `Backup.zip` in the panel means the user chose zip (ADD-04).
                self.model.adoptFormatFromArchivePath()
                self.refresh()
            }
        }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        finish(with: nil)
    }

    @objc private func okPressed(_ sender: Any?) {
        let request: CompressRequest
        do {
            request = try model.makeRequest()
        } catch {
            presentFailure(error)
            return
        }

        // ADD-26: a volume small enough to produce thousands of files is more often a
        // typo (`10` meaning 10 MB) than an intention, so it is confirmed, not refused.
        if let last = request.volumeSizes.last,
           last < CompressDialogModel.VolumeSizeGrammar.tinyVolumeThreshold {
            confirmTinyVolume(last) { [weak self] proceed in
                guard let self, proceed else { return }
                self.finish(with: request)
            }
            return
        }

        finish(with: request)
    }

    private func confirmTinyVolume(_ bytes: UInt64, then handler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Specified volume size: \(bytes) bytes."
        alert.informativeText = "Are you sure you want to split archive into such volumes?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.beginSheetModal(for: sheet) { response in
            MainActor.assumeIsolated {
                handler(response == .alertFirstButtonReturn)
            }
        }
    }

    private func presentFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: sheet, completionHandler: nil)
    }

    // MARK: - Text editing

    public func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }

        switch field {
        case archiveField:
            model.archivePath = field.stringValue
            model.adoptFormatFromArchivePath()
            // Do not call the full refresh here: it would rewrite the field the user is
            // typing into. Only the format-dependent controls need to catch up.
            refreshDependentControls()
            refreshValidation()

        case passwordSecureField, passwordPlainField:
            model.password = field.stringValue
            // Keep the hidden twin in step so toggling Show Password never loses text.
            let twin: NSTextField = field === passwordSecureField ? passwordPlainField : passwordSecureField
            if twin.stringValue != field.stringValue { twin.stringValue = field.stringValue }
            refreshValidation()

        case verifyField:
            model.verifyPassword = field.stringValue
            refreshValidation()

        case volumeCombo:
            model.volumeText = field.stringValue
            refreshValidation()

        case parametersField:
            model.parametersText = field.stringValue

        default:
            break
        }
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo === volumeCombo else { return }
        let index = combo.indexOfSelectedItem
        let presets = CompressDialogModel.VolumeSizeGrammar.presets
        guard presets.indices.contains(index) else { return }
        // `stringValue` is not updated yet at this point in the notification, so the
        // preset is read from the list rather than from the field.
        model.volumeText = presets[index]
        combo.stringValue = presets[index]
        refreshValidation()
    }

    /// Everything a format switch touches, minus the archive-path field itself.
    private func refreshDependentControls() {
        let archive = model.archivePath
        refresh()
        // `refresh()` writes the model's path back into the field; restore the caret by
        // leaving the text exactly as the user typed it.
        if archiveField.stringValue != archive { archiveField.stringValue = archive }
    }
}
