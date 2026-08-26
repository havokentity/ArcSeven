// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The passphrase prompt, used both to open an encrypted archive and to set the
// password on one being created.
//
// 7-Zip's own dialog (CPP/7zip/UI/FileManager/PasswordDialog.cpp) is two edit
// controls plus a "Show password" checkbox: the password, and — only when a
// password is being *set* — the re-typed copy. Windows makes the reveal trivial,
// because masking there is a property of a control instance: EM_SETPASSWORDCHAR
// turns it off in place without touching the text, the caret, or the focus.
//
// AppKit has no equivalent. Masking is a property of the *class*, so revealing a
// password means swapping an `NSSecureTextField` for an `NSTextField` — and every
// naive swap loses something. The three classic bugs are: reading `stringValue`
// off the outgoing control and getting the last *committed* value rather than what
// is in the field editor right now (so the newest keystrokes vanish); handing the
// new control the text but not the selection (so the caret jumps to the end, or the
// whole string ends up selected and the next keystroke wipes the password); and
// hiding a control that still owns the shared field editor (which leaves the editor
// parented to an invisible view and the panel with no usable focus).
// `RevealableSecureField` below exists to get all three right.

import AppKit

/// What the user answered in a password prompt.
public struct PasswordPromptResult: Sendable, Hashable {
    /// The passphrase exactly as typed.
    ///
    /// Never trimmed: leading and trailing spaces are legal password characters and
    /// 7-Zip passes them through untouched, so silently stripping them here would
    /// make archives created by ArcSeven unopenable by 7-Zip and vice versa.
    public var password: String

    /// `true` when the user asked for the passphrase to be remembered.
    ///
    /// This dialog only *reports* the request; it does not link against
    /// Security.framework. The flag is consumed by
    /// `MainWindowController.openArchive(at:in:password:origin:)`, which writes it to
    /// `FMKit.KeychainArchivePasswordStore` — but only once the archive has actually
    /// opened, so a mistyped passphrase is never the one that gets remembered.
    ///
    /// Through 0.1.5 nothing consumed it at all: a grep for `Keychain` across the tree
    /// found this file and nothing else, while the checkbox's tooltip told the user the
    /// archive would open without asking again. It did not.
    public var storeInKeychain: Bool

    public init(password: String, storeInKeychain: Bool = false) {
        self.password = password
        self.storeInKeychain = storeInKeychain
    }
}

/// A modal sheet asking for an archive passphrase.
@MainActor
public final class PasswordDialogController: NSObject, NSTextFieldDelegate {
    /// Which of the two jobs this prompt is doing.
    public enum Mode: Sendable, Hashable {
        /// Opening, listing, testing or extracting an archive that is already
        /// encrypted. One field; the archive itself verifies the answer.
        case unlock
        /// Setting the password on an archive being created. Two fields, because a
        /// mistyped password here is unrecoverable — there is nothing to check it
        /// against until the archive has already been written.
        case confirm
    }

    // MARK: State

    private let mode: Mode
    private let archiveName: String

    private weak var hostWindow: NSWindow?
    private var completion: (@MainActor (PasswordPromptResult?) -> Void)?

    /// Keeps the controller alive between `present(in:completion:)` and dismissal.
    ///
    /// Callers reasonably write `PasswordDialogController(...).present(in: window) { ... }`
    /// and keep no reference. `NSTextField.delegate` is weak, so without this the
    /// controller would be deallocated the moment that statement returns and the
    /// sheet would stop responding to typing.
    private var selfRetain: PasswordDialogController?

    /// The field that most recently owned the field editor. See ``focusedField()``.
    private weak var lastEditedField: RevealableSecureField?

    // MARK: Views

    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let headlineLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let passwordField = RevealableSecureField()
    private let verifyField = RevealableSecureField()
    private let mismatchLabel = NSTextField(labelWithString: "")
    private let showPasswordButton = NSButton(checkboxWithTitle: "Show password", target: nil, action: nil)
    /// `internal`, like `okButton` below, so a test can flip it and press OK. A test
    /// cannot answer a modal sheet, and asserting on a control the sheet never adopted
    /// is exactly the kind of test that passed while this feature did nothing.
    let keychainButton = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: Init

    public init(mode: Mode, archiveName: String) {
        self.mode = mode
        self.archiveName = archiveName
        super.init()
        buildLayout()
        validate()
    }

    // MARK: Presentation

    /// Show the prompt as a sheet on `window`.
    ///
    /// `completion` is called exactly once, with `nil` when the user cancelled. It
    /// runs *after* the sheet has been dismissed so the caller is free to open
    /// another sheet — a retry prompt after a wrong password, most often —
    /// immediately from inside it.
    public func present(
        in window: NSWindow,
        completion: @escaping @MainActor (PasswordPromptResult?) -> Void
    ) {
        hostWindow = window
        self.completion = completion
        selfRetain = self

        panel.initialFirstResponder = passwordField.focusTarget
        window.beginSheet(panel)
    }

    // MARK: Actions

    @objc private func okClicked(_ sender: Any?) {
        // `passwordField.stringValue` reads the field editor rather than the cell,
        // so a click on OK while a keystroke is still uncommitted takes the text the
        // user can actually see. Reading `NSTextField.stringValue` here is the bug
        // that drops the last character typed before the mouse moved.
        let result = PasswordPromptResult(
            password: passwordField.stringValue,
            storeInKeychain: keychainButton.state == .on
        )
        finish(with: result)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        finish(with: nil)
    }

    @objc private func showPasswordToggled(_ sender: Any?) {
        let revealed = showPasswordButton.state == .on

        // Decide who deserves focus *before* either swap runs: after the first
        // `setRevealed` the window's first responder has already moved, and asking
        // afterwards would put the caret in whichever field happened to be swapped
        // last rather than the one the user was typing in.
        let focused = focusedField()
        passwordField.setRevealed(revealed, restoringFocus: focused === passwordField)
        verifyField.setRevealed(revealed, restoringFocus: focused === verifyField)
    }

    /// Which password field the user is currently editing, if any.
    ///
    /// With Full Keyboard Access switched on, clicking the checkbox makes the
    /// *checkbox* first responder before its action fires, so the field editor is
    /// already gone by the time we look. The last field to have been edited is the
    /// right answer in that case, and it is also the right answer when the user
    /// clicked the toggle with the mouse after typing — focus returns where they
    /// were working.
    private func focusedField() -> RevealableSecureField? {
        if passwordField.isEditing { return passwordField }
        if verifyField.isEditing { return verifyField }
        return lastEditedField
    }

    private func finish(with result: PasswordPromptResult?) {
        guard completion != nil else { return }   // defend against a double dismiss
        let handler = completion
        completion = nil

        // Drop the plaintext from both controls before the panel goes away. Swift
        // strings are copy-on-write and this is not a guarantee that no copy of the
        // passphrase survives anywhere in the heap, but leaving it sitting in a
        // live view's cell for as long as the controller happens to be referenced
        // is a needless extra copy.
        passwordField.stringValue = ""
        verifyField.stringValue = ""

        hostWindow?.endSheet(panel)
        panel.orderOut(nil)

        handler?(result)
        selfRetain = nil
    }

    // MARK: Validation

    /// Enable OK and show or hide the inline mismatch note.
    private func validate() {
        guard mode == .confirm else {
            // 7-Zip does not gate OK in the unlock case, and neither do we: an empty
            // answer is a legitimate one for a caller that wants to find out whether
            // the archive really needs a password at all.
            okButton.isEnabled = true
            return
        }

        let password = passwordField.stringValue
        let verify = verifyField.stringValue
        let matches = password == verify

        okButton.isEnabled = !password.isEmpty && matches

        // The message appears inline rather than in an alert. An alert here would
        // interrupt typing to say something the user already knows, and it would
        // have to be dismissed before the fields could be corrected.
        //
        // The label is never hidden, only emptied: hiding it would let the stack
        // collapse and the sheet would visibly jump every time the second field
        // caught up with the first.
        mismatchLabel.stringValue = (verify.isEmpty || matches) ? "" : "Passwords do not match."
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidBeginEditing(_ obj: Notification) {
        noteEditing(obj)
    }

    public func controlTextDidChange(_ obj: Notification) {
        noteEditing(obj)
        validate()
    }

    private func noteEditing(_ note: Notification) {
        if passwordField.owns(note.object) {
            lastEditedField = passwordField
        } else if verifyField.owns(note.object) {
            lastEditedField = verifyField
        }
    }

    // MARK: Layout

    /// Assemble the sheet: style the text, wire the controls, then lay them out.
    private func buildLayout() {
        styleLabels()
        configureControls()
        installContent(grid: makeFieldGrid(), buttons: makeButtonRow())
    }

    private func styleLabels() {
        headlineLabel.stringValue = mode == .unlock
            ? "Enter the password for this archive"
            : "Choose a password for this archive"
        headlineLabel.font = .boldSystemFont(ofSize: 13)

        // The archive name is shown but never trusted for layout: an entry crafted
        // with a 4 KB filename must not be able to stretch the sheet off-screen.
        subtitleLabel.stringValue = archiveName
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        mismatchLabel.font = .systemFont(ofSize: 11)
        mismatchLabel.textColor = .systemRed
        mismatchLabel.lineBreakMode = .byTruncatingTail
    }

    private func configureControls() {
        for field in [passwordField, verifyField] {
            field.textDelegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        passwordField.placeholder = "Password"
        verifyField.placeholder = "Re-enter password"

        showPasswordButton.target = self
        showPasswordButton.action = #selector(showPasswordToggled(_:))

        keychainButton.target = self
        keychainButton.action = #selector(keychainToggled(_:))
        keychainButton.toolTip = "Store this password in the login keychain so the archive opens without asking again."

        okButton.target = self
        okButton.action = #selector(okClicked(_:))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"

        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
    }

    /// The password rows. `Verify` and the mismatch line exist only in `.confirm`.
    private func makeFieldGrid() -> NSGridView {
        let grid = NSGridView(views: [
            [label("Password:"), passwordField],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.row(at: 0).yPlacement = .center

        if mode == .confirm {
            let row = grid.addRow(with: [label("Verify:"), verifyField])
            row.yPlacement = .center
            grid.addRow(with: [NSGridCell.emptyContentView, mismatchLabel])
            // Constrained only when the label is actually in the hierarchy: a width
            // constraint on a view the grid never adopted would fight the autoresizing
            // mask the view still has.
            mismatchLabel.widthAnchor.constraint(equalToConstant: 260).isActive = true
        } else {
            // Nothing to verify against when unlocking: the archive is the oracle.
            verifyField.isHidden = true
        }
        grid.addRow(with: [NSGridCell.emptyContentView, showPasswordButton])
        grid.addRow(with: [NSGridCell.emptyContentView, keychainButton])
        return grid
    }

    private func makeButtonRow() -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        return buttons
    }

    private func installContent(grid: NSGridView, buttons: NSStackView) {
        let stack = NSStackView(views: [headlineLabel, subtitleLabel, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(4, after: headlineLabel)
        stack.setCustomSpacing(18, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])

        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    @objc private func keychainToggled(_ sender: Any?) {
        // Nothing to do: the flag is read at OK time. The action exists so the
        // checkbox is a real control rather than a decoration.
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13)
        field.alignment = .right
        return field
    }
}

// MARK: - The revealable field

/// A password field that can switch between masked and plain rendering without
/// losing what the user has typed or where their caret is.
///
/// Both controls exist for the lifetime of the view and are pinned to the same
/// rectangle; revealing swaps which one is visible. Building the replacement on
/// demand would work too, but keeping both means the layout is established once and
/// the sheet cannot flinch by a pixel when the checkbox is clicked.
@MainActor
private final class RevealableSecureField: NSView, NSTextFieldDelegate {
    private let secureField = NSSecureTextField()
    private let plainField = NSTextField()

    /// `true` while the plaintext control is the visible one.
    private(set) var isRevealed = false

    /// Forwarded editing notifications. Weak, like `NSTextField.delegate` itself.
    weak var textDelegate: (any NSTextFieldDelegate)?

    /// The last selection seen in the field editor.
    ///
    /// Only consulted when the field editor has already been taken away by the time
    /// we need the caret — see `PasswordDialogController.focusedField()`. It is
    /// updated on every text change and at end-of-editing, which is as close as
    /// AppKit lets a control get to the caret without becoming the field editor's
    /// own delegate.
    private var rememberedSelection: NSRange?

    /// The control currently on screen.
    private var activeField: NSTextField { isRevealed ? plainField : secureField }

    /// What to hand `NSWindow.initialFirstResponder`.
    var focusTarget: NSTextField { activeField }

    /// `true` when this field owns the field editor right now.
    var isEditing: Bool { activeField.currentEditor() != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for field in [secureField, plainField] as [NSTextField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: 13)
            field.usesSingleLineMode = true
            field.lineBreakMode = .byClipping
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.delegate = self
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor),
                field.trailingAnchor.constraint(equalTo: trailingAnchor),
                field.topAnchor.constraint(equalTo: topAnchor),
                field.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        // A password is not prose. Completion, substitution and the character
        // picker would all happily rewrite what was typed.
        plainField.isAutomaticTextCompletionEnabled = false
        plainField.allowsCharacterPickerTouchBarItem = false
        secureField.allowsCharacterPickerTouchBarItem = false

        plainField.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        // Both controls are the same height; take it from the masked one so the
        // view's height does not depend on which is showing.
        NSSize(width: NSView.noIntrinsicMetric, height: secureField.intrinsicContentSize.height)
    }

    var placeholder: String {
        get { secureField.placeholderString ?? "" }
        set {
            secureField.placeholderString = newValue
            plainField.placeholderString = newValue
        }
    }

    /// The typed text.
    ///
    /// The getter prefers the field editor over the cell: while a control is being
    /// edited its `stringValue` is only refreshed when editing ends, so reading the
    /// cell mid-edit returns a stale value.
    var stringValue: String {
        get { activeField.currentEditor()?.string ?? activeField.stringValue }
        set {
            secureField.stringValue = newValue
            plainField.stringValue = newValue
            if let editor = activeField.currentEditor() { editor.string = newValue }
        }
    }

    /// `true` when `object` is one of this view's two controls.
    func owns(_ object: Any?) -> Bool {
        guard let object = object as AnyObject? else { return false }
        return object === secureField || object === plainField
    }

    /// Switch between masked and plain, carrying the text, the caret and — when
    /// `restoringFocus` is set — first-responder status across the swap.
    func setRevealed(_ revealed: Bool, restoringFocus: Bool) {
        guard revealed != isRevealed else { return }

        let outgoing = activeField
        let incoming = revealed ? plainField : secureField

        // Read from the field editor, not the cell, so keystrokes that have not
        // been committed yet survive.
        let editor = outgoing.currentEditor()
        let text = editor?.string ?? outgoing.stringValue
        let selection = editor?.selectedRange ?? rememberedSelection

        // Give up the field editor *before* hiding the control that owns it. AppKit
        // lends a single field editor per window to whichever control is first
        // responder; hiding a control that still has it leaves an invisible view
        // holding the keyboard.
        if editor != nil { window?.endEditing(for: outgoing) }

        incoming.stringValue = text
        outgoing.stringValue = ""

        isRevealed = revealed
        incoming.isHidden = false
        outgoing.isHidden = true

        guard restoringFocus, let window else { return }
        window.makeFirstResponder(incoming)

        // Becoming first responder selects the whole string, which is exactly what
        // must not happen to a password: the next keystroke would replace it. Put
        // the caret back where it was, clamped to the text in UTF-16 units because
        // that is what NSRange counts.
        guard let selection, let newEditor = incoming.currentEditor() else { return }
        let length = (text as NSString).length
        let location = min(selection.location, length)
        newEditor.selectedRange = NSRange(
            location: location,
            length: min(selection.length, length - location)
        )
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        textDelegate?.controlTextDidBeginEditing?(obj)
    }

    func controlTextDidChange(_ obj: Notification) {
        rememberCaret(from: obj)
        textDelegate?.controlTextDidChange?(obj)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        rememberCaret(from: obj)
        textDelegate?.controlTextDidEndEditing?(obj)
    }

    private func rememberCaret(from note: Notification) {
        guard let editor = note.userInfo?["NSFieldEditor"] as? NSText else { return }
        rememberedSelection = editor.selectedRange
    }
}
