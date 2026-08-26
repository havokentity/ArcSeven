// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Extract dialog — 7zFM's `IDD_EXTRACT` (FIDELITY §12.3, EXT-01…EXT-14).
//
// Win32 lays this out as a two-column dialog-unit grid: destination combo and its
// `...` button across the top, then a left column holding the `Path mode` and
// `Overwrite mode` group boxes and a right column holding the `Password` group box,
// with the two check boxes filling the bottom-left. That arrangement exists because
// Win32 group boxes are the only visual grouping a dialog template has, and because a
// modal dialog with a caption bar can afford the vertical space.
//
// macOS has neither convention. The HIG form idiom is a single column of right-aligned
// labels against left-aligned controls, with grouping expressed by spacing rather than
// by boxes, and a sheet has no caption bar at all — so 7zFM's `Extract : <path>`
// caption becomes a header line inside the content. Every such difference is marked
// with a "Win32:" comment below. The *semantics* — control set, string set, defaults,
// persistence, and the sticky `kCurPaths` rule — are unchanged.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// 7zFM's Extract dialog, presented as a sheet.
///
/// The controller answers with an ``ExtractRequest`` or `nil` for Cancel. It does not
/// run the extraction: resolving ``OverwriteMode/ask`` (the collision pre-scan plus
/// ``OverwriteDialogController``) and driving the engine belong to the caller, which is
/// why ``OverwriteMode/ask`` is a perfectly legal value in the returned request even
/// though an engine handed one would reject it.
@MainActor
public final class ExtractDialogController: NSObject {
    // MARK: Configuration

    /// The archive being extracted. Also the source of the default destination name
    /// and of the header line.
    private let archiveURL: URL

    /// Archive-relative paths the user had selected, or empty for the whole archive.
    private let selectedEntries: [String]

    /// Everything this dialog remembers between runs. See `ExtractDialogStore`.
    private let store = ExtractDialogStore()

    /// The path mode the caller is operating in, used as the initial selection.
    ///
    /// This subsumes 7zFM's sticky-`kCurPaths` quirk (EXT-07). Upstream cannot show
    /// `Current pathnames` in the combo, so it displays `Full pathnames` instead and
    /// silently *preserves* `kCurPaths` on OK if the user never touched the control —
    /// a rule that is invisible in the UI and easy to get wrong. Here the mode is a
    /// real menu item, so "preserve what the caller passed" is just "preselect it",
    /// and changing it away is an explicit act.
    ///
    /// Assign *after* `init`: the initialiser seeds the control from the persisted mode,
    /// so a later assignment is how a caller says "no, I am in this mode right now".
    public var pathMode: ExtractPathMode = .fullPaths {
        didSet { selectPathMode(pathMode) }
    }

    // Win32's `IDX_EXTRACT_NT_SECUR` — `Restore file security`, EXT-11 — has no control
    // here, and its absence is deliberate.
    //
    // Through 0.1.5 there was a `Restore POSIX permissions` check box, a
    // `restoresPOSIXPermissions` property documented "read this after
    // `present(in:completion:)` calls back", and a persisted preference behind it. No
    // caller ever read the property: `MainWindowController.extractSelection` never
    // touches the dialog inside its completion. The box remembered its own state across
    // launches and changed nothing.
    //
    // It could not have been honoured as written. `ExtractRequest` has no field for it,
    // and `7zz` has no switch for it either — the Unix build restores the `st_mode` bits
    // out of the entry's attribute word unconditionally, so "off" would have to mean
    // walking the extracted tree afterwards and rewriting modes. That walk cannot tell
    // which files it actually wrote (an extraction over an existing directory leaves the
    // user's own files in the same tree), so implementing it would risk changing
    // permissions on files ArcSeven did not create. A control that silently does nothing
    // is bad; one that silently chmods the user's files would be worse.
    //
    // Bringing it back means a `restorePermissions` field on `ExtractRequest` and an
    // engine that can act on it. Until then there is nothing to show.

    // MARK: Controls

    /// `internal`, so a test can walk the sheet's real view hierarchy. Asserting on a
    /// control the sheet never adopted is how a dead one goes unnoticed.
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let headerLabel = NSTextField(labelWithString: "Extract")
    private let archiveLabel = NSTextField(labelWithString: "")

    /// Win32: `IDC_EXTRACT_PATH` is an editable combo whose drop-down is the
    /// destination MRU, capped at `kHistorySize = 16` (EXT-02). `NSComboBox` is the
    /// exact same control, so this one is not a divergence.
    private let destinationCombo = NSComboBox()
    private let browseButton = NSButton(title: "Browse…", target: nil, action: nil)

    private let pathModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overwriteModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Two fields, one visible at a time. Win32 flips `EM_SETPASSWORDCHAR` on a single
    /// edit control and re-sets its text (PWD-02); `NSSecureTextField` has no such
    /// switch — secure input is a property of the field's cell and its text is held in
    /// a shared secure buffer — so the macOS equivalent is to swap fields and carry the
    /// string across. Same behaviour, different mechanism.
    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()
    private let showPasswordCheck = NSButton(
        checkboxWithTitle: "Show password", target: nil, action: nil
    )

    /// Carried into `ExtractRequest.eliminateRootDuplication`, which is what makes it a
    /// control rather than a decoration. See the note above about the one that was not.
    let eliminateRootCheck = NSButton(
        checkboxWithTitle: "Eliminate duplication of root folder", target: nil, action: nil
    )

    let extractButton = NSButton(title: "Extract", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let helpButton = NSButton(title: "", target: nil, action: nil)

    // MARK: Sheet state

    private weak var host: NSWindow?
    private var completion: (@MainActor (ExtractRequest?) -> Void)?

    /// Keeps the controller alive between `present` and the completion call, so callers
    /// can present a throwaway instance without storing it. Cleared on dismissal, which
    /// is the only thing keeping this from being a permanent leak.
    private var selfRetain: ExtractDialogController?

    // MARK: Init

    public init(archiveURL: URL, selectedEntries: [String]) {
        self.archiveURL = archiveURL
        self.selectedEntries = selectedEntries
        super.init()

        buildControls()
        restoreState()
        panel.contentView = buildLayout()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 560, height: 320))
        // Sheets never draw a title bar, but VoiceOver and the window list still read it.
        panel.title = Self.caption(for: archiveURL)
    }

    // MARK: Presentation

    /// Show the dialog as a sheet on `window`.
    ///
    /// `completion` receives the assembled request, or `nil` if the user cancelled. It
    /// is called exactly once, after the sheet has been ordered out.
    public func present(in window: NSWindow, completion: @escaping @MainActor (ExtractRequest?) -> Void) {
        self.completion = completion
        self.host = window
        self.selfRetain = self
        window.beginSheet(panel)
        // `beginSheet` clears the default button cell's key equivalent — AppKit disables
        // it as the sheet attaches, and `enableKeyEquivalentForDefaultButtonCell()` does
        // not put it back. Re-asserting it here is what makes Return mean Extract. Without
        // this the sheet looks correct and silently ignores the Return key, which is the
        // sort of thing that only shows up when someone actually uses the dialog.
        extractButton.keyEquivalent = "\r"
        // The destination is the field a user most often edits, and pre-selecting its
        // text means typing a new path replaces rather than appends.
        panel.makeFirstResponder(destinationCombo)
        destinationCombo.currentEditor()?.selectAll(nil)
    }

    // MARK: Construction

    private func buildControls() {
        headerLabel.font = .boldSystemFont(ofSize: 13)

        // Win32 puts the archive path in the caption: `Extract : C:\…\foo.7z`
        // (EXT-01). A sheet has no caption, so it becomes a secondary line under the
        // header. Middle truncation, because the interesting part of an archive path is
        // the volume at the front and the file name at the back.
        archiveLabel.stringValue = archiveURL.path
        archiveLabel.font = .systemFont(ofSize: 11)
        archiveLabel.textColor = .secondaryLabelColor
        archiveLabel.lineBreakMode = .byTruncatingMiddle
        archiveLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        archiveLabel.toolTip = archiveURL.path

        destinationCombo.usesDataSource = false
        destinationCombo.completes = false
        destinationCombo.numberOfVisibleItems = ExtractDialogStore.historyLimit
        destinationCombo.isEditable = true
        destinationCombo.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseForDestination(_:))

        buildPathModeMenu()
        buildOverwriteMenu()

        for field in [secureField, plainField] {
            field.placeholderString = "None"
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        plainField.isHidden = true

        showPasswordCheck.target = self
        showPasswordCheck.action = #selector(togglePasswordVisibility(_:))

        extractButton.bezelStyle = .rounded
        extractButton.keyEquivalent = "\r"
        extractButton.target = self
        extractButton.action = #selector(confirm(_:))

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))

        helpButton.bezelStyle = .helpButton
        helpButton.target = self
        helpButton.action = #selector(showHelp(_:))
        // Win32 always shows a Help button (EXT-13) because Win32 help is a file next to
        // the executable. Here it is only meaningful if a help book was actually bundled;
        // a button that reports "Help isn't available" is worse than no button.
        helpButton.isHidden = Self.helpBookName == nil
    }

    private func buildPathModeMenu() {
        pathModePopUp.removeAllItems()
        for mode in Self.pathModeOrder {
            let item = NSMenuItem(title: Self.displayName(for: mode), action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            pathModePopUp.menu?.addItem(item)
        }
    }

    private func buildOverwriteMenu() {
        overwriteModePopUp.removeAllItems()
        // Dialog order is fixed by EXT-09 and matches `OverwriteMode`'s declaration
        // order, so `allCases` is the resource order rather than an accident.
        for mode in OverwriteMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: nil, keyEquivalent: "")
            item.representedObject = mode.rawValue
            overwriteModePopUp.menu?.addItem(item)
        }
    }

    private func buildLayout() -> NSView {
        let passwordBox = makePasswordBox()
        let destinationRow = makeDestinationRow()
        let grid = makeFormGrid(destinationRow: destinationRow, passwordBox: passwordBox)
        let buttonRow = makeButtonRow()
        let headerStack = makeHeaderStack()

        let root = NSStackView(views: [headerStack, grid, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Everything else sizes off this: a destination path is the widest thing the
            // sheet has to show, and 420 pt holds roughly 70 characters at the system
            // font — about what the Win32 combo shows at its default dialog width.
            destinationCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            // The password field is the same run of pixels as the destination row above
            // it. With a `.leading` column it would otherwise collapse to the intrinsic
            // width of an empty text field, and a two-character-wide password box next to
            // a 500 pt destination box looks like a bug.
            passwordBox.widthAnchor.constraint(equalTo: destinationRow.widthAnchor),
            headerStack.widthAnchor.constraint(equalTo: grid.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: grid.widthAnchor),
        ])
        return content
    }

    /// The two password fields stacked in one box, so hiding one does not move the row.
    private func makePasswordBox() -> NSView {
        let passwordBox = NSView()
        passwordBox.translatesAutoresizingMaskIntoConstraints = false
        for field in [secureField, plainField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            passwordBox.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: passwordBox.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: passwordBox.trailingAnchor),
                field.topAnchor.constraint(equalTo: passwordBox.topAnchor),
                field.bottomAnchor.constraint(equalTo: passwordBox.bottomAnchor),
            ])
        }
        return passwordBox
    }

    private func makeDestinationRow() -> NSStackView {
        let destinationRow = NSStackView(views: [destinationCombo, browseButton])
        destinationRow.orientation = .horizontal
        destinationRow.spacing = 8
        destinationRow.alignment = .firstBaseline
        return destinationRow
    }

    /// Win32: two side-by-side group boxes plus a third for the password. macOS: one
    /// label column, controls flush left against it, groups separated by row spacing.
    private func makeFormGrid(destinationRow: NSStackView, passwordBox: NSView) -> NSGridView {
        let grid = NSGridView(views: [
            [Self.formLabel("Extract to:"), destinationRow],
            [Self.formLabel("Path mode:"), pathModePopUp],
            [Self.formLabel("Overwrite mode:"), overwriteModePopUp],
            [Self.formLabel("Password:"), passwordBox],
            [NSGridCell.emptyContentView, showPasswordCheck],
            [NSGridCell.emptyContentView, eliminateRootCheck],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        // `.leading`, not `.fill`: a filled column stretches the pop-ups and, worse, the
        // check boxes to the full width of the widest row. An `NSButton` check box is
        // clickable across its entire frame, so a stretched one toggles when the user
        // clicks empty space 400 pt to the right of its label.
        grid.column(at: 1).xPlacement = .leading
        // `Show password` belongs to the field above it, not to the check box below, so
        // it sits tight against the field and the check box is pushed away from both.
        grid.row(at: 4).topPadding = -4
        grid.row(at: 5).topPadding = 10
        return grid
    }

    /// Win32's OK / Cancel / Help sit bottom-right / bottom-right / bottom-right in a
    /// single run. macOS puts Help alone at the leading edge and the affirmative pair
    /// at the trailing edge, default rightmost. "OK" also becomes the verb "Extract":
    /// an action button on macOS names its action.
    private func makeButtonRow() -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [helpButton, spacer, cancelButton, extractButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY
        return buttonRow
    }

    private func makeHeaderStack() -> NSStackView {
        let headerStack = NSStackView(views: [headerLabel, archiveLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        return headerStack
    }

    private static func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    // MARK: State

    /// Restore everything 7zFM persists for this dialog, then seed the destination.
    private func restoreState() {
        destinationCombo.addItems(withObjectValues: store.destinationHistory)

        // The default destination is a folder beside the archive, named after it. 7zFM
        // strips exactly one extension, which is why `foo.tar.gz` proposes `foo.tar/`
        // and needs a second pass to become `foo/`. Reproduced rather than "fixed":
        // the two-step is what makes nested tarballs land predictably.
        destinationCombo.stringValue = Self.normalizedDirectoryPath(Self.defaultDestination(for: archiveURL).path)

        if let stored = store.pathMode {
            pathMode = stored
        } else {
            selectPathMode(pathMode)
        }

        // Nothing stored, or something unreadable, means Ask — the mode that cannot
        // destroy a file without saying so first.
        select(store.overwriteMode ?? .ask)

        eliminateRootCheck.state = store.eliminatesRootDuplication ? .on : .off

        showPasswordCheck.state = store.showsPassword ? .on : .off
        applyPasswordVisibility()
    }

    private func persistState(destination: URL) {
        store.recordDestination(Self.normalizedDirectoryPath(destination.path))
        store.setPathMode(currentPathMode)
        store.setOverwriteMode(currentOverwriteMode)
        store.setEliminatesRootDuplication(eliminateRootCheck.state == .on)
        store.setShowsPassword(showPasswordCheck.state == .on)
    }
}

// MARK: - Actions

/// Split out of the class body only for length; `private` still reaches the stored
/// controls above, because an extension in the same file is inside the same wall.
extension ExtractDialogController {
    @objc private func browseForDestination(_ sender: Any?) {
        let open = NSOpenPanel()
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Choose"
        // EXT-03: Win32's `SHBrowseForFolder` shows this as its instruction text; on
        // macOS the equivalent slot is `message`, above the file list.
        open.message = "Specify a location for extracted files."
        open.directoryURL = resolvedDestination() ?? archiveURL.deletingLastPathComponent()

        open.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = open.url, let self else { return }
                self.destinationCombo.stringValue = Self.normalizedDirectoryPath(url.path)
            }
        }
    }

    @objc private func togglePasswordVisibility(_ sender: Any?) {
        applyPasswordVisibility()
    }

    private func applyPasswordVisibility() {
        let reveal = showPasswordCheck.state == .on
        // Carry the text across before the swap; the hidden field is the source of truth
        // only until the next toggle.
        if reveal {
            plainField.stringValue = secureField.stringValue
        } else {
            secureField.stringValue = plainField.stringValue
        }
        plainField.isHidden = !reveal
        secureField.isHidden = reveal

        // Keep the caret where the user left it rather than dumping focus to the sheet.
        let wasEditing = panel.firstResponder === secureField.currentEditor()
            || panel.firstResponder === plainField.currentEditor()
        if wasEditing {
            panel.makeFirstResponder(reveal ? plainField : secureField)
        }
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    @objc private func confirm(_ sender: Any?) {
        // Commit whatever is sitting in a field editor; a user who types a path and hits
        // Return immediately would otherwise submit the previous value.
        panel.makeFirstResponder(nil)

        guard let destination = resolvedDestination() else {
            // EXT-05's failure string, verbatim.
            presentError("Incorrect output directory path")
            panel.makeFirstResponder(destinationCombo)
            return
        }

        persistState(destination: destination)

        let password = currentPassword
        finish(ExtractRequest(
            archiveURL: archiveURL,
            destinationURL: destination,
            pathMode: currentPathMode,
            overwriteMode: currentOverwriteMode,
            // An empty box means "no password", not "the empty password" — the same
            // convention `CompressRequest.EncryptionOptions` documents.
            password: password.isEmpty ? nil : password,
            selectedEntries: selectedEntries.isEmpty ? nil : selectedEntries,
            formatOverride: nil,
            eliminateRootDuplication: eliminateRootCheck.state == .on,
            restoreSymbolicLinks: true,
            keepBrokenFiles: false
        ))
    }

    @objc private func showHelp(_ sender: Any?) {
        guard let book = Self.helpBookName else { return }
        NSHelpManager.shared.openHelpAnchor("extract", inBook: book)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: panel, completionHandler: nil)
    }

    private func finish(_ request: ExtractRequest?) {
        guard let completion else { return }
        self.completion = nil
        host?.endSheet(panel, returnCode: request == nil ? .cancel : .OK)
        panel.orderOut(nil)
        completion(request)
        selfRetain = nil
    }

    // MARK: Reading the controls

    private var currentPathMode: ExtractPathMode {
        guard let raw = pathModePopUp.selectedItem?.representedObject as? String,
              let mode = ExtractPathMode(rawValue: raw) else { return .fullPaths }
        return mode
    }

    private var currentOverwriteMode: OverwriteMode {
        guard let raw = overwriteModePopUp.selectedItem?.representedObject as? String,
              let mode = OverwriteMode(rawValue: raw) else { return .ask }
        return mode
    }

    private var currentPassword: String {
        showPasswordCheck.state == .on ? plainField.stringValue : secureField.stringValue
    }

    private func selectPathMode(_ mode: ExtractPathMode) {
        selectItem(withRawValue: mode.rawValue, in: pathModePopUp)
    }

    private func select(_ mode: OverwriteMode) {
        selectItem(withRawValue: mode.rawValue, in: overwriteModePopUp)
    }

    private func selectItem(withRawValue raw: String, in popUp: NSPopUpButton) {
        guard let items = popUp.menu?.items else { return }
        for (index, item) in items.enumerated() where (item.representedObject as? String) == raw {
            popUp.selectItem(at: index)
            return
        }
    }

    /// The destination as an absolute, standardised URL, or `nil` if the text cannot be
    /// made into one.
    ///
    /// A relative path resolves against the archive's own directory, which is what a
    /// user typing `out` next to `foo.7z` means. The directory is *not* created here;
    /// `ExtractRequest` documents that as the engine's job.
    private func resolvedDestination() -> URL? {
        let raw = destinationCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let expanded = (raw as NSString).expandingTildeInPath
        let base = archiveURL.deletingLastPathComponent()
        let url = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: base)
        let standardised = url.standardizedFileURL
        // `standardizedFileURL` on garbage such as "///" collapses to "/", which is a
        // valid URL but never a valid extraction target.
        guard standardised.path != "/" else { return nil }
        return standardised
    }
}

// MARK: - Static helpers

extension ExtractDialogController {
    /// EXT-01's caption. Only ever one archive here, so the `:` form always applies.
    private static func caption(for archiveURL: URL) -> String {
        "Extract : \(archiveURL.path)"
    }

    /// The four modes, in `IDD_EXTRACT` order.
    ///
    /// EXT-06 records that upstream's combo carries only three, omitting `kCurPaths`.
    /// ArcSeven lists all four: on Windows the omission forces the hidden sticky rule of
    /// EXT-07, and a mode the user can end up in but cannot see or choose is exactly the
    /// kind of invisible state a Mac dialog should not have. Reverting to the Win32 set
    /// is deleting one line here plus honouring `ExtractPathMode.selectableCases`.
    private static let pathModeOrder: [ExtractPathMode] = [
        .fullPaths, .currentPaths, .noPaths, .absolutePaths,
    ]

    /// `ExtractPathMode.displayName` is `nil` for `.currentPaths` precisely because
    /// upstream never shows it; supplying the missing string is this dialog's business,
    /// not ArchiveCore's.
    private static func displayName(for mode: ExtractPathMode) -> String {
        mode.displayName ?? "Current pathnames"
    }

    /// `<archive's directory>/<archive name minus one extension>`.
    private static func defaultDestination(for archiveURL: URL) -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        let stem = archiveURL.deletingPathExtension().lastPathComponent
        // A dotfile archive such as `.7z` has an empty stem; fall back to the whole name
        // rather than proposing the parent directory itself, which would scatter the
        // archive's contents next to it.
        let name = stem.isEmpty ? archiveURL.lastPathComponent : stem
        return parent.appendingPathComponent(name, isDirectory: true)
    }

    /// EXT-05: `NormalizeDirPathPrefix()` guarantees a trailing separator so the user can
    /// see at a glance that the field holds a directory and not a file.
    private static func normalizedDirectoryPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    private static var helpBookName: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
    }
}
