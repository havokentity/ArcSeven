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

    // Everything below is `internal` rather than `private`, deliberately. This controller
    // is split across CompressDialogController+Interface / +Redraw / +Actions, and Swift's
    // `private` does not reach an extension in another file. Nothing here is `public`, so
    // the visible surface is unchanged outside the module.

    var model: CompressDialogModel

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

    let sheet = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    let archiveField = NSTextField(string: "")
    let browseButton = NSButton(title: "Browse…", target: nil, action: nil)

    let formatPopup = NSPopUpButton()
    let levelPopup = NSPopUpButton()
    let methodPopup = NSPopUpButton()
    let dictionaryPopup = NSPopUpButton()
    let wordSizePopup = NSPopUpButton()
    let solidPopup = NSPopUpButton()
    let threadsPopup = NSPopUpButton()
    let threadsHint = NSTextField(labelWithString: "")

    let compressMemoryLabel = NSTextField(labelWithString: "?")
    let decompressMemoryLabel = NSTextField(labelWithString: "?")

    let updateModePopup = NSPopUpButton()
    let pathModePopup = NSPopUpButton()

    let sfxCheckbox = NSButton(checkboxWithTitle: "Create SFX archive", target: nil, action: nil)
    let sfxNote = NSTextField(labelWithString: "No SFX module configured.")
    let deleteCheckbox = NSButton(
        checkboxWithTitle: "Delete files after compression", target: nil, action: nil)

    let symlinkCheckbox = NSButton(checkboxWithTitle: "Store symbolic links", target: nil, action: nil)
    let hardLinkCheckbox = NSButton(checkboxWithTitle: "Store hard links", target: nil, action: nil)
    let xattrCheckbox = NSButton(checkboxWithTitle: "Store extended attributes", target: nil, action: nil)
    let posixCheckbox = NSButton(checkboxWithTitle: "Store POSIX permissions", target: nil, action: nil)

    let passwordSecureField = NSSecureTextField(string: "")
    let passwordPlainField = NSTextField(string: "")
    let verifyField = NSSecureTextField(string: "")
    let showPasswordCheckbox = NSButton(checkboxWithTitle: "Show password", target: nil, action: nil)
    let encryptionMethodPopup = NSPopUpButton()
    let encryptNamesCheckbox = NSButton(checkboxWithTitle: "Encrypt file names", target: nil, action: nil)
    let passwordErrorLabel = NSTextField(labelWithString: "")

    /// Discloses that a passphrase used to CREATE an archive is briefly visible to other
    /// local users. `7zz a` has no stdin prompt — it silently writes an unencrypted
    /// archive when `-p` is absent — so the passphrase has to go on argv, where `ps` can
    /// see it for the lifetime of the child. Reading an encrypted archive is unaffected;
    /// there the passphrase is piped. See `docs/SECURITY.md` §4.
    let passwordExposureLabel = NSTextField(labelWithString: "")

    /// The sheet's content view, kept so the sheet can be resized to it whenever a row
    /// appears or disappears.
    var contentRoot: NSView?

    let volumeCombo = NSComboBox()
    let volumeErrorLabel = NSTextField(labelWithString: "")
    let parametersField = NSTextField(string: "")

    let okButton = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // Rows that are hidden rather than disabled, matching 7zFM: the reenter field
    // disappears with Show Password (ADD-33), and `Encrypt file names` exists only for
    // handlers that have header encryption at all (ADD-31).
    //
    // These are stack rows, not `NSGridRow`s. A hidden grid row does not reliably give
    // its height back — the reclaimed space reappears further down the grid — whereas
    // NSStackView drops a hidden arranged view from the layout completely, which is the
    // behaviour a dialog that hides two of its rows depends on.
    var secureRow: NSStackView?
    var plainRow: NSStackView?
    var verifyRow: NSStackView?
    var encryptNamesRow: NSStackView?
    var passwordErrorRow: NSStackView?
    var passwordExposureRow: NSStackView?
    var volumeErrorRow: NSStackView?

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

    func finish(with request: CompressRequest?) {
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
}
