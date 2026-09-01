// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The overwrite confirmation — 7zFM's `IDD_OVERWRITE` (FIDELITY §12.4, OVR-01…OVR-08).
//
// This is the dialog that makes `OverwriteMode.ask` work at all. `7zz` always runs with
// `-y` (EXT-09): a subprocess that prompts on a closed stdin exits 255, which is
// indistinguishable from a user cancellation, so ArcSeven pre-scans for collisions and
// asks here instead. The four bulk answers (`Yes to All`, `No to All`, `Auto Rename`,
// `Cancel`) therefore change the *rest of the run*, not just this one file — the caller
// maps them onto an `OverwriteMode` and stops asking.
//
// Win32 lays the six buttons out as two rows of three, because a dialog template has no
// notion of a trailing-edge button cluster and `Auto Rename` needs 104 dialog units where
// the rest need 80. macOS does have that convention, so the six collapse into one row:
// Cancel alone at the leading edge, the five answers right-aligned with the default last.
// The information above them keeps 7zFM's exact order and exact strings.

import AppKit
#if canImport(FMKit)   // module-guard
import FMKit
#endif
import UniformTypeIdentifiers

/// What the user chose in the overwrite confirmation.
///
/// The three "…to All" answers are sticky for the remainder of the operation, matching
/// OVR-08: `yesToAll` → ``ArchiveCore/OverwriteMode/overwrite``, `noToAll` →
/// ``ArchiveCore/OverwriteMode/skip``, `autoRename` →
/// ``ArchiveCore/OverwriteMode/autoRename``. `cancel` aborts the whole operation, not
/// just this file.
public enum OverwriteDecision: Sendable, Hashable, CaseIterable {
    case yes
    case yesToAll
    // `no` is two characters, but it is the caption on the button and the other half of a
    // four-case family — renaming it alone would break the `yes`/`no`/`yesToAll`/`noToAll`
    // symmetry that makes this enum readable against 7zFM's dialog.
    // swiftlint:disable:next identifier_name
    case no
    case noToAll
    case autoRename
    case cancel
}

/// One side of the comparison: a file that exists, or one that is about to.
///
/// `size` and `modified` are optional because the incoming side comes out of an archive
/// listing, and not every format records both for every member. Upstream always has both
/// and so has no rendering for their absence; ArcSeven states it plainly rather than
/// leaving a blank line the user has to interpret.
public struct FileInfo: Sendable, Hashable {
    /// Full path. Elided in the middle for display — see ``OverwriteDialogController``.
    public var path: String
    public var size: UInt64?
    public var modified: Date?

    public init(path: String, size: UInt64? = nil, modified: Date? = nil) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

/// 7zFM's `Confirm File Replace`, presented as a sheet.
@MainActor
public final class OverwriteDialogController: NSObject {
    // MARK: Configuration

    private let existing: FileInfo
    private let incoming: FileInfo

    /// OVR-07's `ShowExtraButtons`. When `false` only `Yes`, `No` and `Cancel` remain,
    /// which is what a single-file operation with nothing left to apply "to all" needs.
    public var showsExtraButtons: Bool = true {
        didSet { applyButtonVisibility() }
    }

    /// OVR-07's `DefaultButton_is_NO`. Makes `No` the default and the first responder,
    /// so Return is the safe answer rather than the destructive one.
    public var defaultsToNo: Bool = false {
        didSet { applyDefaultButton() }
    }

    /// The mirror of ``showsExtraButtons``: hides the PER-FILE answers, leaving only the
    /// ones that honestly describe what will happen.
    ///
    /// The subprocess engine cannot be answered mid-run — a decision becomes one `-ao*`
    /// switch for the whole extraction. So when more than one file collides, `Yes` cannot
    /// mean "this one": it silently overwrites every collision, which through 0.1.5 is what
    /// it did. Removing the button is the honest fix; the alternative is a button that
    /// means something other than what it says.
    public var showsPerFileButtons: Bool = true {
        didSet { applyButtonVisibility() }
    }

    // MARK: Controls

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    private let headerLabel = NSTextField(labelWithString: "Confirm File Replace")
    private let subtitleLabel = NSTextField(
        labelWithString: "Destination folder already contains processed file."
    )

    private let yesButton = NSButton(title: "Yes", target: nil, action: nil)
    private let yesToAllButton = NSButton(title: "Yes to All", target: nil, action: nil)
    private let noButton = NSButton(title: "No", target: nil, action: nil)
    private let noToAllButton = NSButton(title: "No to All", target: nil, action: nil)
    private let autoRenameButton = NSButton(title: "Auto Rename", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    // MARK: Sheet state

    private weak var host: NSWindow?
    private var completion: (@MainActor (OverwriteDecision) -> Void)?
    private var selfRetain: OverwriteDialogController?

    // MARK: Testing hooks

    /// The sheet's content view, so a test can assert which buttons a user actually sees.
    public var panelContentViewForTesting: NSView? { panel.contentView }

    /// Whether Return is wired to the destructive answer.
    public var destructiveButtonHasReturnKeyForTesting: Bool { yesButton.keyEquivalent == "\r" }

    // MARK: Init

    public init(existing: FileInfo, incoming: FileInfo) {
        self.existing = existing
        self.incoming = incoming
        super.init()

        buildControls()
        panel.contentView = buildLayout()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 560, height: 380))
        panel.title = "Confirm File Replace"
        applyDefaultButton()
        applyButtonVisibility()
    }

    // MARK: Presentation

    /// Show the confirmation as a sheet on `window`.
    ///
    /// `completion` is called exactly once, after the sheet is ordered out. There is no
    /// `nil` case: dismissing the sheet always produces a decision, and the only way out
    /// without choosing is Escape, which *is* ``OverwriteDecision/cancel``.
    public func present(in window: NSWindow, completion: @escaping @MainActor (OverwriteDecision) -> Void) {
        self.completion = completion
        self.host = window
        self.selfRetain = self
        window.beginSheet(panel)
        // `beginSheet` clears the default button cell's key equivalent — AppKit disables it
        // as the sheet attaches, and `enableKeyEquivalentForDefaultButtonCell()` does not
        // put it back. Re-asserting it is what makes Return answer the question at all,
        // and it matters more here than in most sheets: OVR-07's `DefaultButton_is_NO`
        // exists precisely so Return can be aimed at the safe answer.
        applyDefaultButton()
        panel.makeFirstResponder(defaultsToNo ? noButton : yesButton)
    }

    // MARK: Construction

    private func buildControls() {
        headerLabel.font = .boldSystemFont(ofSize: 13)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        for button in [yesButton, yesToAllButton, noButton, noToAllButton, autoRenameButton, cancelButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        yesButton.action = #selector(chooseYes(_:))
        yesToAllButton.action = #selector(chooseYesToAll(_:))
        noButton.action = #selector(chooseNo(_:))
        noToAllButton.action = #selector(chooseNoToAll(_:))
        autoRenameButton.action = #selector(chooseAutoRename(_:))
        cancelButton.action = #selector(chooseCancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
    }

    private func buildLayout() -> NSView {
        // OVR-02: the two question halves bracket the two info blocks, in this order.
        // Reading top to bottom the dialog is one sentence — "replace the existing file
        // <block> with this one? <block>" — and reordering it would break that.
        let existingBlock = Self.fileBlock(
            question: "Would you like to replace the existing file",
            info: existing,
            // The file on disk exists, so its icon can be the real one: a custom icon,
            // an app bundle's own artwork, a `.icns`. OVR-06's "slot 2".
            icon: NSWorkspace.shared.icon(forFile: existing.path)
        )
        let incomingBlock = Self.fileBlock(
            question: "with this one?",
            info: incoming,
            // The incoming file is still inside the archive, so only its extension is
            // known — exactly the constraint that makes OVR-06's "slot 1" extension-only.
            icon: Self.typeIcon(forPathExtension: (incoming.path as NSString).pathExtension)
        )

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Cancel is not one of the five answers and must not read as the sixth. The sheet
        // is usually exactly as wide as its content, so without a floor the spacer
        // collapses to nothing and Cancel ends up shoulder to shoulder with `No to All`.
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true

        // Trailing cluster reads left to right as increasing commitment, with the two
        // negative answers first so an accidental click lands on the safe side.
        let buttonRow = NSStackView(views: [
            cancelButton, spacer,
            noToAllButton, noButton, autoRenameButton, yesToAllButton, yesButton,
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let headerStack = NSStackView(views: [headerLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2

        let root = NSStackView(views: [headerStack, existingBlock, incomingBlock, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            existingBlock.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40),
            incomingBlock.widthAnchor.constraint(equalTo: existingBlock.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: existingBlock.widthAnchor),
        ])
        return content
    }

    /// One question line plus OVR-04's four-line info block, with an icon at the leading
    /// edge.
    ///
    /// Win32 stacks the four statics with the icon floating to their left in absolute
    /// coordinates. The macOS version is the same shape, expressed as a horizontal stack
    /// so the text column reflows if the sheet is ever resized.
    private static func fileBlock(question: String, info: FileInfo, icon: NSImage) -> NSView {
        let questionLabel = NSTextField(labelWithString: question)
        questionLabel.font = .systemFont(ofSize: 12)

        let directory = (info.path as NSString).deletingLastPathComponent
        let lines = [
            // OVR-04 line 1 is the directory *prefix*, trailing separator included, so it
            // is unmistakably a folder and not a sibling file with a similar name.
            reduce(directory.hasSuffix("/") ? directory : directory + "/"),
            reduce((info.path as NSString).lastPathComponent),
            sizeLine(info.size),
            modifiedLine(info.modified),
        ]

        let textStack = NSStackView(views: [questionLabel] + lines.map(detailLabel))
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        let iconView = NSImageView()
        iconView.image = icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),
        ])

        let row = NSStackView(views: [iconView, textStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        // The detail labels give up width freely (low compression resistance) so that a
        // pathological name can never stretch the sheet. That alone lets the button row
        // — six buttons, the widest incompressible thing here — decide the sheet width
        // and squeeze the paths down to a third of their length, which throws away
        // exactly the characters `reduce(_:)` worked to keep. This floor reserves room
        // for a full 77-character elided line, so truncation only ever kicks in for text
        // that is genuinely wider than the fidelity limit allows for.
        textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 430).isActive = true
        return row
    }

    private static func detailLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        // Belt and braces. `reduce(_:)` already caps the string at 72 characters, which is
        // the fidelity behaviour; this stops a pathological 72-character run of wide
        // glyphs from stretching the sheet anyway. The two are not redundant — one is
        // content, one is layout.
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.toolTip = text
        return label
    }

    // MARK: Actions

    @objc private func chooseYes(_ sender: Any?) { finish(.yes) }
    @objc private func chooseYesToAll(_ sender: Any?) { finish(.yesToAll) }
    @objc private func chooseNo(_ sender: Any?) { finish(.no) }
    @objc private func chooseNoToAll(_ sender: Any?) { finish(.noToAll) }
    @objc private func chooseAutoRename(_ sender: Any?) { finish(.autoRename) }
    @objc private func chooseCancel(_ sender: Any?) { finish(.cancel) }

    private func finish(_ decision: OverwriteDecision) {
        guard let completion else { return }
        self.completion = nil
        host?.endSheet(panel, returnCode: decision == .cancel ? .cancel : .OK)
        panel.orderOut(nil)
        completion(decision)
        selfRetain = nil
    }

    private func applyButtonVisibility() {
        for button in [yesToAllButton, noToAllButton, autoRenameButton] {
            button.isHidden = !showsExtraButtons
        }
        for button in [yesButton, noButton] {
            button.isHidden = !showsPerFileButtons
        }
        panel.setContentSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    private func applyDefaultButton() {
        yesButton.keyEquivalent = defaultsToNo ? "" : "\r"
        noButton.keyEquivalent = defaultsToNo ? "\r" : ""
    }

    // MARK: Text

    /// OVR-05's `ReduceString`: anything over 72 characters loses its middle.
    ///
    /// Upstream deletes `len - 72` UTF-16 units starting at offset 36 and splices `" ... "`
    /// into the gap. This counts grapheme clusters instead, so the cut never lands inside
    /// an emoji or a combining sequence and produces mojibake — same rule, applied to what
    /// a reader actually perceives as a character.
    ///
    /// The quote-wrap for trailing spaces is a security behaviour, not a cosmetic one: a
    /// crafted archive member named `"invoice.pdf                    .app"` renders in a
    /// proportional font as though it ends where the padding starts, and the closing quote
    /// is what makes the padding visible.
    static func reduce(_ string: String) -> String {
        var characters = Array(string)
        if characters.count > limit {
            let excess = characters.count - limit
            characters.removeSubrange(limit / 2 ..< (limit / 2 + excess))
            characters.insert(contentsOf: Array(" ... "), at: limit / 2)
        }
        let result = String(characters)
        return result.hasSuffix(" ") ? "\"\(result)\"" : result
    }

    /// `kCurrentStringLimit` in `OverwriteDialog.cpp`.
    private static let limit = 72

    /// OVR-04 line 3: the exact byte count, plus a rounded unit once it stops being
    /// readable. The thresholds are upstream's and are deliberately lopsided — you only
    /// see MiB from 10 MiB up, so a 3 MiB file still reads in KiB.
    ///
    /// The exact count leads because that is the number you compare between the two
    /// blocks; the rounded one is the one you can hold in your head.
    static func sizeLine(_ size: UInt64?) -> String {
        guard let size else {
            // Upstream never renders this case — its dialog is only ever built with both
            // sizes known. An archive member with no recorded size gets a plain statement
            // rather than a blank line that reads as "zero".
            return "Size unknown"
        }
        // Grouped digits, matching the panel's Size column (`ColumnModel.groupedByteCount`)
        // so the same number looks the same everywhere in the app.
        var line = "\(ColumnModel.groupedByteCount(size)) bytes"
        if size >= 1024 {
            let unit: (UInt64, String)
            if size >= 10 << 30 {
                unit = (30, "GiB")
            } else if size >= 10 << 20 {
                unit = (20, "MiB")
            } else {
                unit = (10, "KiB")
            }
            line += " : \(ColumnModel.groupedByteCount(size >> unit.0)) \(unit.1)"
        }
        return line
    }

    /// OVR-04 line 4.
    ///
    /// Upstream prints UTC, not local time, and ArcSeven keeps that. It looks wrong at
    /// first glance on a Mac — Finder shows local — but the whole point of these two
    /// blocks is a side-by-side comparison, and one timestamp read from a filesystem
    /// while the other is read from an archive header can only be compared in a single
    /// fixed frame. The `UTC` suffix is added because a bare timestamp that silently is
    /// not local time is a trap; the format is otherwise upstream's.
    static func modifiedLine(_ date: Date?) -> String {
        guard let date else { return "Modified: unknown" }
        // A locally-created formatter, not a shared static: `DateFormatter` is not
        // `Sendable` and a static instance of one is a data race under Swift 6.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Modified: \(formatter.string(from: date)) UTC"
    }

    /// OVR-06 slot 1: the icon a shell derives from the extension alone, with no access
    /// to the file itself.
    private static func typeIcon(forPathExtension ext: String) -> NSImage {
        guard !ext.isEmpty else { return NSWorkspace.shared.icon(for: .data) }
        if let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}
