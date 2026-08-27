// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The main window: toolbar, one or two panels, and the title.
//
// 7zFM's window is a rebar plus one or two panels in a splitter. The default panel
// count is 1 — not 2, despite what most screenshots suggest — and F9 toggles the
// second one in. `NSSplitViewController` gives us the divider behaviour for free.
//
// The toolbar carries 7zFM's seven buttons in their original order: Add, Extract,
// Test, Copy, Move, Delete, Info.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(Dialogs)   // module-guard
import Dialogs
#endif
#if canImport(SettingsUI)   // module-guard
import SettingsUI
#endif
#if canImport(Support)   // module-guard
import Support
#endif

@MainActor
public final class MainWindowController: NSWindowController {
    let engine: any ArchiveEngine
    private let splitViewController = NSSplitViewController()

    /// The panels, left to right. One entry until the second panel is toggled on.
    var panels: [PanelViewController] = []

    /// The panel that has focus. Operations act on this one.
    private var activePanelIndex = 0

    /// Held while the Properties inspector is on screen; it is a sheet, not a child
    /// view controller, so nothing else retains it.
    var propertiesInspector: PropertiesInspectorController?

    /// Where "Remember in Keychain" puts things, and where the open path looks first.
    ///
    /// A `var` so a test can substitute an in-memory store: exercising this against the
    /// real login keychain would prompt the person running the suite for access and
    /// leave items behind in it.
    var passwordStore: any ArchivePasswordStore = KeychainArchivePasswordStore()

    /// How a disk delete reaches the Trash.
    ///
    /// `TrashService.trash(_:)`'s BATCH overload, which carries on past a failure and
    /// reports the whole selection at once. A `var` so a test can substitute it: proving
    /// that the batch call happens, and that a `volumeHasNoTrash` answer is honoured,
    /// must not require moving the tester's files into their real Trash.
    var trashItems: @MainActor ([URL]) -> TrashSummary = { TrashService.trash($0) }

    /// What the last disk delete decided to tell the user.
    ///
    /// Recorded because the alternative is an alert sheet, which a test cannot inspect —
    /// and "the UI must offer the permanent delete instead and say why" is a behaviour
    /// `TrashService` documents, not a comment. Nothing in the app reads this.
    private(set) var lastDeleteOutcome: DeleteOutcome?

    /// Set by ``deleteSelection(from:)``; see ``lastDeleteOutcome``.
    func recordDeleteOutcome(_ outcome: DeleteOutcome) { lastDeleteOutcome = outcome }

    private var activePanel: PanelViewController? {
        panels.indices.contains(activePanelIndex) ? panels[activePanelIndex] : nil
    }

    // MARK: Init

    public init(startingAt url: URL, engine: any ArchiveEngine) {
        self.engine = engine

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ArcSeven"
        window.setFrameAutosaveName("ArcSevenMainWindow")
        window.tabbingMode = .preferred
        super.init(window: window)

        let provider = FileSystemFolderProvider(directoryURL: url, engine: engine)
        let panel = makePanel(provider: provider)
        panels = [panel]

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin

        let item = NSSplitViewItem(viewController: panel)
        // Without a minimum thickness a pane can be dragged to zero width and then
        // cannot be recovered, because there is nothing left to grab.
        item.minimumThickness = 360
        item.canCollapse = false
        splitViewController.addSplitViewItem(item)

        window.contentViewController = splitViewController
        window.delegate = self

        // Assigning `contentViewController` RESIZES the window to the view's fitting
        // size, discarding the contentRect passed to init. With autolayout content
        // that has no intrinsic height that collapses the window to a few hundred
        // points. Set the size after the assignment, not before.
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.minSize = NSSize(width: 720, height: 420)

        configureToolbar()
        panel.go(to: provider)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func makePanel(provider: any FolderProvider) -> PanelViewController {
        let panel = PanelViewController(provider: provider, engine: engine)
        panel.delegate = self
        return panel
    }

    // MARK: Running an operation

    /// Drive an operation stream against the progress sheet.
    ///
    /// One place for the pattern so every action gets cancellation, warning reporting
    /// and error handling identically. Cancelling the task tears down the child
    /// process group; `7zz` unwinds and removes a partial archive.
    ///
    /// `onSettled` fires exactly once on EVERY exit — finished, thrown, cancelled,
    /// even no-window — so a caller can release resources the operation was reading.
    /// It is declared after `completion` so existing trailing-closure call sites
    /// still bind their closure to `completion`.
    func confirmDestructive(
        _ title: String,
        _ body: String,
        proceed: @escaping @MainActor () -> Void
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    func presentMessage(_ title: String, _ body: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.beginSheetModal(for: window)
    }

    /// Reopen an archive whose contents changed underneath us.
    func reopenArchive(_ archive: ArchiveFolderProvider, in panel: PanelViewController) {
        Task { [engine] in
            do {
                let reopened = try await ArchiveFolderProvider.open(
                    archiveURL: archive.archiveURL, engine: engine
                )
                panel.go(to: reopened)
            } catch {
                self.reportFailure(error)
            }
        }
    }

    /// Reload any panel currently showing `directory`, so a new archive appears.
    func refreshPanelsShowing(_ directory: URL) {
        for panel in panels {
            guard let shown = (panel.provider as? FileSystemFolderProvider)?.directoryURL else { continue }
            if shown.standardizedFileURL == directory.standardizedFileURL { panel.reload() }
        }
    }

    // MARK: Panels

    /// F9 in 7zFM: show or hide the second panel.
    public func toggleSecondPanel() {
        if panels.count == 2 {
            let removed = panels.removeLast()
            if let item = splitViewController.splitViewItems.last { splitViewController.removeSplitViewItem(item) }
            if activePanelIndex >= panels.count { activePanelIndex = panels.count - 1 }
            _ = removed
        } else {
            let start = (panels.first?.provider as? FileSystemFolderProvider)?.directoryURL
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let panel = makePanel(provider: FileSystemFolderProvider(directoryURL: start, engine: engine))
            panels.append(panel)
            let item = NSSplitViewItem(viewController: panel)
            item.minimumThickness = 360
            item.canCollapse = false
            splitViewController.addSplitViewItem(item)
            panel.go(to: panel.provider)
        }
    }

    /// Open a file chosen by the user, descending into it if it is an archive.
    public func openDocument(at url: URL) {
        guard let panel = activePanel else { return }
        Task {
            if FileSystemFolderProvider.isArchive(url) {
                await self.openArchive(at: url, in: panel, password: nil)
            } else {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
                panel.go(to: FileSystemFolderProvider(directoryURL: directory, engine: engine))
            }
        }
    }

    /// Where the passphrase currently being tried came from.
    ///
    /// The three cases are genuinely different, and collapsing them is how a remembered
    /// passphrase turns into an unbreakable loop: a stale keychain item is handed back
    /// on every retry, so the user never sees the prompt again and can never correct it.
    enum PasswordOrigin: Sendable, Equatable {
        /// Nothing tried yet — the first attempt at this archive.
        case untried
        /// Read out of the keychain. A failure means the item is stale and must go.
        case remembered
        /// Typed into the prompt just now. `remember` is the checkbox, and is honoured
        /// only once the archive has actually opened.
        case typed(remember: Bool)
    }

    /// Open an archive, prompting for a passphrase when its headers are encrypted.
    ///
    /// An archive with encrypted headers cannot even be LISTED without the password —
    /// `7zz` fails with "Cannot open encrypted archive. Wrong password?" — so the
    /// prompt has to happen here, on the open path, not at extraction time.
    /// `ArchiveError.needsPassword` covers both the wrong-password case and the
    /// prompt-was-required case, which is exactly the retry condition.
    ///
    /// The keychain rules, in one place because they only make sense together:
    ///
    /// * A remembered passphrase is tried BEFORE the prompt, which is the whole point of
    ///   the checkbox — otherwise it is a write with no read, which is the same bug.
    /// * It is saved only AFTER the archive opens. Storing what the user typed the
    ///   moment they press OK would happily remember a typo and then re-fail forever.
    /// * A remembered passphrase that fails is deleted before the prompt goes up. The
    ///   archive has been re-encrypted, or the item was always wrong; either way, keeping
    ///   it means the next open silently retries it.
    ///
    /// `internal` rather than `private` so a test can drive each origin directly: the
    /// alternative is answering a modal sheet, which a test cannot do.
    func openArchive(
        at url: URL,
        in panel: PanelViewController,
        password: String?,
        origin: PasswordOrigin = .untried
    ) async {
        do {
            let provider = try await ArchiveFolderProvider.open(
                archiveURL: url, engine: engine, password: password
            )
            panel.go(to: provider)

            if case .typed(remember: true) = origin, let password, !password.isEmpty {
                passwordStore.save(password, forArchiveAt: url)
            }
        } catch let error as ArchiveError where error.needsPassword {
            if origin == .remembered {
                passwordStore.removePassword(forArchiveAt: url)
            }
            if origin == .untried, let remembered = passwordStore.password(forArchiveAt: url) {
                await openArchive(at: url, in: panel, password: remembered, origin: .remembered)
                return
            }
            promptForPassword(archiveName: url.lastPathComponent) { [weak self] result in
                guard let self, let result else { return }
                Task {
                    await self.openArchive(
                        at: url,
                        in: panel,
                        password: result.password,
                        origin: .typed(remember: result.storeInKeychain)
                    )
                }
            }
        } catch {
            presentMessage("Could not open \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    private func promptForPassword(
        archiveName: String,
        completion: @escaping @MainActor (PasswordPromptResult?) -> Void
    ) {
        guard let window else { completion(nil); return }
        let dialog = PasswordDialogController(mode: .unlock, archiveName: archiveName)
        dialog.present(in: window, completion: completion)
    }

    /// Ask for an archive's passphrase, using a remembered one rather than prompting.
    ///
    /// The insertion path's entry point. It reads the keychain but never writes to it:
    /// only ``openArchive(at:in:password:origin:)`` can tell whether a passphrase was
    /// actually right, and an unverified write is how a typo gets remembered.
    func password(
        forArchiveAt url: URL,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        if let remembered = passwordStore.password(forArchiveAt: url) {
            completion(remembered)
            return
        }
        promptForPassword(archiveName: url.lastPathComponent) { result in
            completion(result?.password)
        }
    }

    // MARK: Finder entry points

    /// Extract archives handed over by Finder (extension or Services).
    ///
    /// Extracts each into a sibling folder named after the archive, which is the
    /// "Extract Here"-with-a-folder behaviour people expect from a context menu — no
    /// dialog, because someone who right-clicked and chose Extract has already made
    /// the decision the dialog would ask about.
    /// How a Finder extraction decides where to put things.
    public enum FinderExtractionMode: Sendable {
        /// Let the archive decide. See ``extractionDestination(forArchive:rootEntryCount:)``.
        case smart
        /// Never wrap.
        case loose
        /// Always wrap in a folder named after the archive.
        case subfolder
    }

    // MARK: Menu actions

    @objc public func openLocation(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        guard let window else { return }
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = openPanel.url else { return }
            self?.openDocument(at: url)
        }
    }

    @objc public func goBack(_ sender: Any?) { activePanel?.goToParent() }
    @objc public func openSelection(_ sender: Any?) { activePanel?.openSelection() }
    @objc public func toggleDualPane(_ sender: Any?) { toggleSecondPanel() }
    @objc public func extractAction(_ sender: Any?) { perform(.extract) }
    @objc public func infoAction(_ sender: Any?) { perform(.info) }
    @objc public func addAction(_ sender: Any?) { perform(.add) }
    @objc public func testAction(_ sender: Any?) { perform(.test) }
    @objc public func deleteAction(_ sender: Any?) { perform(.delete) }
    @objc public func copyAction(_ sender: Any?) { perform(.copy) }
    @objc public func moveAction(_ sender: Any?) { perform(.move) }
    @objc public func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
}

// MARK: - Panel delegate

extension MainWindowController: PanelViewControllerDelegate {
    public func panelDidChangeLocation(_ panel: PanelViewController) {
        if let index = panels.firstIndex(where: { $0 === panel }) { activePanelIndex = index }
        // 7zFM titles the window with the focused panel's path, falling back to the
        // app name when there is none.
        window?.title = panel.provider.displayPath.isEmpty ? "ArcSeven" : panel.provider.displayPath
        // Stepping into a nested archive changes the listing under the inspector too,
        // not just the selection.
        refreshPropertiesInspector(from: panel)
    }

    public func panelDidChangeSelection(_ panel: PanelViewController) {
        if let index = panels.firstIndex(where: { $0 === panel }) { activePanelIndex = index }
        // The selection-changed hook `PropertiesInspectorController.update(listing:entry:)`
        // documents itself as being called from, and for two releases was not.
        refreshPropertiesInspector(from: panel)
    }

    public func panel(_ panel: PanelViewController, didFailWith error: any Error) {
        // Routed through reportFailure so an encrypted nested archive says "wrong
        // password" rather than dumping a raw engine message.
        reportFailure(error)
    }

    /// Files dropped onto a panel: a copy on disk, an insertion inside an archive.
    public func panel(_ panel: PanelViewController, didReceiveDroppedFiles urls: [URL], onto target: FolderItem?) {
        if let archive = panel.provider as? ArchiveFolderProvider {
            // Into the folder row the drop landed on, else the level being shown.
            let subPath = if let target, target.isDirectory { target.path } else { archive.subPath }
            insertIntoArchive(urls, into: archive, at: subPath, shownIn: panel)
        } else {
            copyDroppedFiles(urls, onto: target, in: panel)
        }
    }
}

// MARK: - Files coming in

/// The reverse of `DragController`: files arriving IN a panel, by drop or by the Add
/// button while an archive is open. In an extension so the controller body stays
/// inside its size budget.
extension MainWindowController {
    /// A drop onto a disk level: a Finder-style copy into the shown directory, or
    /// into the folder row the drop landed on.
    private func copyDroppedFiles(_ urls: [URL], onto target: FolderItem?, in panel: PanelViewController) {
        let destination: URL
        if let target, target.isDirectory, let url = target.url {
            destination = url
        } else if let shown = (panel.provider as? FileSystemFolderProvider)?.directoryURL {
            destination = shown
        } else {
            return    // the volumes / root levels are not writable drop targets
        }

        let manager = FileManager.default
        var failures: [String] = []
        for url in urls {
            let landing = destination.appendingPathComponent(url.lastPathComponent)
            // A file dropped back onto its own folder is a no-op, not an error.
            guard landing.standardizedFileURL != url.standardizedFileURL else { continue }
            do { try manager.copyItem(at: url, to: landing) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for other in panels { other.reload() }
        if !failures.isEmpty {
            presentMessage("Some items could not be copied",
                           failures.prefix(5).joined(separator: "\n"))
        }
    }

    /// Insert files into an archive open in a panel, landing under `destinationSubPath`.
    ///
    /// The shared tail of both routes in: a drop onto the panel, and Add while a level
    /// of the archive is showing. An encrypted archive prompts for the password FIRST:
    /// `7zz` rewrites the whole archive on update, so it must be able to read the
    /// existing members, not merely encrypt the new ones.
    private func insertIntoArchive(
        _ files: [URL],
        into archive: ArchiveFolderProvider,
        at destinationSubPath: String,
        shownIn panel: PanelViewController
    ) {
        guard !files.isEmpty else { return }
        guard archive.listing.isEncrypted else {
            runInsertion(files, into: archive, at: destinationSubPath, password: nil, shownIn: panel)
            return
        }
        // Through the keychain-aware helper, so an archive the user asked to be
        // remembered is not re-prompted here either — "opens without asking again" is
        // not a promise that should hold for one command and not the next.
        password(forArchiveAt: archive.archiveURL) { [weak self] password in
            guard let self, let password else { return }
            runInsertion(files, into: archive, at: destinationSubPath, password: password, shownIn: panel)
        }
    }

    /// Plan, compress, clean up, reopen — the insertion itself.
    ///
    /// The planner stages a symlink tree when the destination is below the archive
    /// root, because `7zz a` stores every input under the path it was given; the
    /// staged tree is what makes `docs/img/logo.png` land at `docs/img/logo.png`.
    private func runInsertion(
        _ files: [URL],
        into archive: ArchiveFolderProvider,
        at destinationSubPath: String,
        password: String?,
        shownIn panel: PanelViewController
    ) {
        let plan: ArchiveInsertionPlan
        do {
            plan = try ArchiveInsertionPlanner.plan(
                adding: files, to: archive.archiveURL, at: destinationSubPath,
                format: archive.listing.format, password: password
            )
        } catch {
            // Covers `.archiveInsideItself` — the archive dropped into itself — whose
            // message names the problem; nothing was staged that needs undoing.
            presentMessage("Cannot add to \(archive.archiveURL.lastPathComponent)",
                           error.localizedDescription)
            return
        }

        run(
            operation: engine.compress(plan.request),
            title: "Updating \(archive.archiveURL.lastPathComponent)",
            completion: { [weak self] _ in
                // The listing is now stale; reopen so the new members appear.
                self?.reopenArchive(archive, in: panel)
            },
            // On EVERY exit, success or not: the staging directory must outlive the
            // run — `7zz` reads the inputs through its symlinks — and no longer.
            onSettled: { plan.cleanUp() }
        )
    }

    /// Add while a level of an archive is showing: choose items, insert them at this
    /// level. (On disk, Add keeps its create-an-archive dialog — see `addToArchive`.)
    private func addIntoOpenArchive(_ archive: ArchiveFolderProvider, shownIn panel: PanelViewController) {
        guard let window else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = "Add"
        let inside = archive.subPath.isEmpty ? "" : "/" + archive.subPath
        openPanel.message = "Add to \(archive.archiveURL.lastPathComponent)\(inside)"
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            insertIntoArchive(openPanel.urls, into: archive, at: archive.subPath, shownIn: panel)
        }
    }
}

// MARK: - Window delegate

extension MainWindowController: NSWindowDelegate {}

// MARK: - Toolbar

/// The rebar, and the seven buttons on it. In an extension so the controller body
/// stays inside its size budget. `ToolbarActionStyle` lives in its own file so the
/// `NSToolbarDelegate` conformance below is the only other place that reads it.
extension MainWindowController {
    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "ArcSevenMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// 7zFM's seven toolbar buttons, in its order.
    /// The sender is the badge button, so the action is recovered from its accessibility
    /// label rather than from a toolbar item identifier.
    @objc private func toolbarActionInvoked(_ sender: Any?) {
        let title = (sender as? NSButton)?.accessibilityLabel()
        guard let action = ToolbarActionStyle.allCases.first(where: { $0.title == title })
        else { return }
        perform(action)
    }

    private func perform(_ action: ToolbarActionStyle) {
        guard let panel = activePanel else { return }
        switch action {
        case .add:
            // Viewing an archive, Add means "insert into THIS archive at THIS
            // level"; on disk it keeps addToArchive's create-an-archive dialog.
            if let archive = panel.provider as? ArchiveFolderProvider {
                addIntoOpenArchive(archive, shownIn: panel)
            } else {
                addToArchive(from: panel)
            }
        case .extract: extractSelection(from: panel)
        case .test:    testArchive(from: panel)
        case .delete:  deleteSelection(from: panel)
        case .copy:    transferSelection(from: panel, move: false)
        case .move:    transferSelection(from: panel, move: true)
        case .info:    showInfo(for: panel)
        }
    }
}

// MARK: - Toolbar delegate

extension MainWindowController: NSToolbarDelegate {
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []
        for action in ToolbarActionStyle.allCases {
            identifiers.append(action.itemIdentifier)
            if action == .test { identifiers.append(.space) }
        }
        return identifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarActionStyle.allCases.map(\.itemIdentifier) + [.space, .flexibleSpace]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let action = ToolbarActionStyle.allCases.first(where: { $0.itemIdentifier == itemIdentifier })
        else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = action.title
        item.paletteLabel = action.title
        item.toolTip = action.title

        // A custom view rather than `item.image`: the badge is drawn, and a toolbar item
        // renders its image as a monochrome template. `isBordered` stays off so AppKit does
        // not draw its own chrome behind ours.
        let button = BubbleToolbarButton(
            symbol: action.symbolName, tint: action.tint, title: action.title
        )
        button.target = self
        button.action = #selector(toolbarActionInvoked(_:))
        item.view = button
        item.isBordered = false
        return item
    }
}
