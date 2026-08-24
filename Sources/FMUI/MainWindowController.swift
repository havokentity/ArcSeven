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

    private let engine: any ArchiveEngine
    private let splitViewController = NSSplitViewController()

    /// The panels, left to right. One entry until the second panel is toggled on.
    private var panels: [PanelViewController] = []

    /// The panel that has focus. Operations act on this one.
    private var activePanelIndex = 0

    /// Held while the Properties inspector is on screen; it is a sheet, not a child
    /// view controller, so nothing else retains it.
    private var propertiesInspector: PropertiesInspectorController?

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

    // MARK: Toolbar

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
    fileprivate enum ToolbarAction: String, CaseIterable {
        case add, extract, test, copy, move, delete, info

        var title: String {
            switch self {
            case .add: "Add"
            case .extract: "Extract"
            case .test: "Test"
            case .copy: "Copy"
            case .move: "Move"
            case .delete: "Delete"
            case .info: "Info"
            }
        }

        /// SF Symbols standing in for 7-Zip's bitmaps.
        var symbolName: String {
            switch self {
            case .add: "plus.rectangle.on.folder"
            case .extract: "arrow.down.doc"
            case .test: "checkmark.seal"
            case .copy: "doc.on.doc"
            case .move: "arrow.right.doc.on.clipboard"
            case .delete: "trash"
            case .info: "info.circle"
            }
        }

        var itemIdentifier: NSToolbarItem.Identifier { .init("ArcSeven." + rawValue) }
    }

    @objc fileprivate func toolbarActionInvoked(_ sender: NSToolbarItem) {
        guard let action = ToolbarAction.allCases.first(
            where: { $0.itemIdentifier == sender.itemIdentifier }
        ) else { return }
        perform(action)
    }

    private func perform(_ action: ToolbarAction) {
        guard let panel = activePanel else { return }
        switch action {
        case .add:     addToArchive(from: panel)
        case .extract: extractSelection(from: panel)
        case .test:    testArchive(from: panel)
        case .delete:  deleteSelection(from: panel)
        case .copy:    transferSelection(from: panel, move: false)
        case .move:    transferSelection(from: panel, move: true)
        case .info:    showInfo(for: panel)
        }
    }

    // MARK: Operations

    /// Add to archive — 7zFM's Add button.
    ///
    /// Operates on the selection, or on everything in the folder when nothing is
    /// selected, which is what 7zFM does. Only meaningful for rows that exist on disk:
    /// re-compressing members of an archive in place is a later milestone.
    private func addToArchive(from panel: PanelViewController) {
        guard let window else { return }

        let selected = panel.selectedItems.compactMap(\.url)
        let inputs: [URL]
        if !selected.isEmpty {
            inputs = selected
        } else if let directory = (panel.provider as? FileSystemFolderProvider)?.directoryURL {
            inputs = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        } else {
            inputs = []
        }

        guard !inputs.isEmpty else {
            presentMessage(
                "Nothing to add",
                "Select files on disk to compress. Adding to an archive from inside "
                    + "another archive is not supported yet."
            )
            return
        }

        // Default the archive name to the selection when it is a single item, or to
        // the enclosing folder otherwise — 7zFM's naming rule.
        let base = inputs.count == 1
            ? inputs[0].deletingPathExtension().lastPathComponent
            : inputs[0].deletingLastPathComponent().lastPathComponent
        let defaultURL = inputs[0]
            .deletingLastPathComponent()
            .appendingPathComponent(base.isEmpty ? "Archive" : base)
            .appendingPathExtension("7z")

        let dialog = CompressDialogController(defaultArchiveURL: defaultURL, inputs: inputs)
        dialog.present(in: window) { [weak self] request in
            guard let self, let request else { return }
            self.run(
                operation: self.engine.compress(request),
                title: "Creating \(request.archiveURL.lastPathComponent)",
                completion: { result in
                    self.reportSuccess(
                        result,
                        title: "Archive created",
                        detail: request.archiveURL.path,
                        reveal: request.archiveURL
                    )
                    self.refreshPanelsShowing(request.archiveURL.deletingLastPathComponent())
                }
            )
        }
    }

    /// Extract — 7zFM's Extract button.
    private func extractSelection(from panel: PanelViewController) {
        guard let window else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage(
                "Not an archive",
                "Open an archive first — Extract works on the contents of an archive."
            )
            return
        }

        let entries = panel.selectedItems.map(\.path)
        let dialog = ExtractDialogController(
            archiveURL: archive.archiveURL,
            selectedEntries: entries
        )
        dialog.present(in: window) { [weak self] request in
            guard let self, var request else { return }

            // "Ask before overwrite" cannot be answered mid-stream: the child process
            // has no interactive channel once it is running. Resolve conflicts up
            // front, then hand the engine a concrete, non-interactive mode.
            if request.overwriteMode == .ask {
                self.resolveOverwrite(for: request, in: archive.listing) { resolved in
                    guard let resolved else { return }
                    request = resolved
                    self.startExtraction(request)
                }
            } else {
                self.startExtraction(request)
            }
        }
    }

    private func startExtraction(_ request: ExtractRequest) {
        run(
            operation: engine.extract(request),
            title: "Extracting \(request.archiveURL.lastPathComponent)"
        ) { [weak self] result in
            self?.reportSuccess(
                result,
                title: "Extraction complete",
                detail: "Extracted to \(request.destinationURL.path).",
                reveal: request.destinationURL
            )
        }
    }

    /// Ask about the first conflicting file, then apply the answer to the whole run.
    ///
    /// 7zFM prompts per file. The subprocess engine cannot, so ArcSeven asks once and
    /// maps the answer onto an `-ao*` switch. `docs/DIVERGENCES.md` records this; a
    /// true per-file prompt arrives with the in-process engine.
    private func resolveOverwrite(
        for request: ExtractRequest,
        in listing: ArchiveListing,
        completion: @escaping @MainActor (ExtractRequest?) -> Void
    ) {
        let candidates = request.selectedEntries ?? listing.entries.map(\.path)
        let manager = FileManager.default

        var conflict: (existing: URL, entry: ArchiveEntry)?
        for path in candidates {
            guard let entry = listing.entry(atPath: path), !entry.isDirectory else { continue }
            // Resolve through the zip-slip guard rather than joining paths naively.
            guard let destination = try? PathSafety.resolvedDestination(
                root: request.destinationURL, entryPath: path
            ) else { continue }
            if manager.fileExists(atPath: destination.path) {
                conflict = (destination, entry)
                break
            }
        }

        guard let conflict, let window else {
            completion(request)
            return
        }

        let attributes = try? manager.attributesOfItem(atPath: conflict.existing.path)
        let dialog = OverwriteDialogController(
            existing: FileInfo(
                path: conflict.existing.path,
                size: (attributes?[.size] as? NSNumber)?.uint64Value,
                modified: attributes?[.modificationDate] as? Date
            ),
            incoming: FileInfo(
                path: conflict.entry.path,
                size: conflict.entry.size,
                modified: conflict.entry.modified
            )
        )
        dialog.present(in: window) { decision in
            var resolved = request
            switch decision {
            case .yes, .yesToAll: resolved.overwriteMode = .overwrite
            case .no, .noToAll:   resolved.overwriteMode = .skip
            case .autoRename:     resolved.overwriteMode = .autoRename
            case .cancel:         completion(nil); return
            }
            completion(resolved)
        }
    }

    /// Test — verify every member's CRC without writing anything.
    private func testArchive(from panel: PanelViewController) {
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("Not an archive", "Open an archive to test it.")
            return
        }
        let entries = panel.selectedItems.map(\.path)
        var request = TestRequest(archiveURL: archive.archiveURL)
        request.selectedEntries = entries.isEmpty ? nil : entries

        run(
            operation: engine.test(request),
            title: "Testing \(archive.archiveURL.lastPathComponent)"
        ) { [weak self] result in
            self?.reportSuccess(
                result,
                title: result.hasWarnings ? "Tested with warnings" : "No errors found",
                detail: "\(result.itemsProcessed) item(s) verified.",
                reveal: nil
            )
        }
    }

    /// Delete — Trash on disk, remove-from-archive inside one.
    private func deleteSelection(from panel: PanelViewController) {
        let items = panel.selectedItems
        guard !items.isEmpty else {
            presentMessage("Nothing selected", "Select the items you want to delete.")
            return
        }

        if let archive = panel.provider as? ArchiveFolderProvider {
            confirmDestructive(
                "Delete \(items.count) item(s) from \(archive.archiveURL.lastPathComponent)?",
                "This rewrites the archive and cannot be undone."
            ) { [weak self] in
                guard let self else { return }
                let request = DeleteRequest(
                    archiveURL: archive.archiveURL,
                    entryPaths: items.map(\.path)
                )
                self.run(
                    operation: self.engine.delete(request),
                    title: "Updating \(archive.archiveURL.lastPathComponent)"
                ) { _ in
                    // The listing is now stale; reopen the archive at the same level.
                    self.reopenArchive(archive, in: panel)
                }
            }
            return
        }

        // On disk, Delete means "move to Trash" — the Mac meaning, and recoverable.
        let urls = items.compactMap(\.url)
        var trashed = 0
        var failures: [String] = []
        for url in urls {
            do { _ = try TrashService.trash(url); trashed += 1 }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        panel.reload()
        if !failures.isEmpty {
            presentMessage(
                "Moved \(trashed) of \(urls.count) to the Trash",
                failures.prefix(5).joined(separator: "\n")
            )
        }
    }

    /// Copy / Move — to the other panel when there is one, else to a chosen folder.
    ///
    /// This is 7zFM's F5/F6: with two panels open, the other panel IS the destination,
    /// which is the whole reason the two-pane layout exists.
    private func transferSelection(from panel: PanelViewController, move: Bool) {
        let items = panel.selectedItems
        guard !items.isEmpty else {
            presentMessage("Nothing selected", "Select the items you want to \(move ? "move" : "copy").")
            return
        }

        // Extracting out of an archive is a copy by definition; a move would mean
        // deleting from the archive afterwards, which is a separate confirmation.
        if let archive = panel.provider as? ArchiveFolderProvider {
            guard let destination = otherPanelDirectory(besides: panel) else {
                presentMessage(
                    "No destination",
                    "Open a second panel (View ▸ Toggle Two Panels) on a folder, then "
                        + "Copy extracts the selection into it."
                )
                return
            }
            var request = ExtractRequest(archiveURL: archive.archiveURL, destinationURL: destination)
            request.selectedEntries = items.map(\.path)
            request.overwriteMode = .autoRename
            startExtraction(request)
            return
        }

        guard let destination = otherPanelDirectory(besides: panel) else {
            presentMessage(
                "No destination",
                "Open a second panel (View ▸ Toggle Two Panels) to \(move ? "move" : "copy") into."
            )
            return
        }

        let manager = FileManager.default
        var failures: [String] = []
        for url in items.compactMap(\.url) {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            do {
                if move { try manager.moveItem(at: url, to: target) }
                else { try manager.copyItem(at: url, to: target) }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        for other in panels { other.reload() }
        if !failures.isEmpty {
            presentMessage("Some items could not be \(move ? "moved" : "copied")",
                           failures.prefix(5).joined(separator: "\n"))
        }
    }

    private func otherPanelDirectory(besides panel: PanelViewController) -> URL? {
        for candidate in panels where candidate !== panel {
            if let directory = (candidate.provider as? FileSystemFolderProvider)?.directoryURL {
                return directory
            }
        }
        return nil
    }

    /// Info — the Properties inspector.
    private func showInfo(for panel: PanelViewController) {
        guard let window else { return }
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("No archive open", "Open an archive to see its properties.")
            return
        }
        let inspector = PropertiesInspectorController(
            listing: archive.listing,
            entry: panel.selectedItems.first?.entry
        )
        inspector.present(in: window)
        propertiesInspector = inspector      // held so it is not deallocated while shown
    }

    // MARK: Running an operation

    /// Drive an operation stream against the progress sheet.
    ///
    /// One place for the pattern so every action gets cancellation, warning reporting
    /// and error handling identically. Cancelling the task tears down the child
    /// process group; `7zz` unwinds and removes a partial archive.
    private func run(
        operation: ArchiveOperationStream,
        title: String,
        completion: @escaping @MainActor (ArchiveOperationResult) -> Void
    ) {
        guard let window else { return }
        let progress = ProgressSheetController(title: title)
        progress.present(in: window)

        let task = Task { @MainActor in
            do {
                for try await event in operation {
                    switch event {
                    case .progress(let tick):
                        progress.update(
                            fraction: tick.fractionCompleted,
                            detail: tick.currentItemPath ?? ""
                        )
                    case .finished(let result):
                        progress.finish()
                        completion(result)
                    default:
                        break
                    }
                }
            } catch is CancellationError {
                progress.finish()
            } catch {
                progress.finish()
                self.reportFailure(error)
            }
        }
        progress.onCancel = { task.cancel() }
    }

    private func reportSuccess(
        _ result: ArchiveOperationResult,
        title: String,
        detail: String,
        reveal: URL?
    ) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        var text = detail
        if result.hasWarnings {
            // Exit code 1 is success-with-warnings. Show them; do not call it a failure.
            text += "\n\n\(result.warnings.count) warning(s):\n"
                + result.warnings.prefix(5).map(\.message).joined(separator: "\n")
        }
        alert.informativeText = text
        if reveal != nil { alert.addButton(withTitle: "Reveal in Finder") }
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            if let reveal, response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            }
        }
    }

    /// Report a failure, naming a password problem specifically when that is the cause.
    ///
    /// Named `reportFailure` rather than `presentError`: `NSResponder` already declares
    /// `presentError(_:) -> Bool`, and overloading it here is ambiguous at every call site.
    private func reportFailure(_ error: any Error) {
        if let archiveError = error as? ArchiveError, archiveError.needsPassword {
            presentMessage(
                "Wrong password",
                "That password did not open the archive. Try opening it again."
            )
            return
        }
        presentMessage("The operation failed", error.localizedDescription)
    }

    private func confirmDestructive(
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

    private func presentMessage(_ title: String, _ body: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.beginSheetModal(for: window)
    }

    /// Reopen an archive whose contents changed underneath us.
    private func reopenArchive(_ archive: ArchiveFolderProvider, in panel: PanelViewController) {
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
    private func refreshPanelsShowing(_ directory: URL) {
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

    /// Open an archive, prompting for a passphrase when its headers are encrypted.
    ///
    /// An archive with encrypted headers cannot even be LISTED without the password —
    /// `7zz` fails with "Cannot open encrypted archive. Wrong password?" — so the
    /// prompt has to happen here, on the open path, not at extraction time.
    /// `ArchiveError.needsPassword` covers both the wrong-password case and the
    /// prompt-was-required case, which is exactly the retry condition.
    private func openArchive(
        at url: URL,
        in panel: PanelViewController,
        password: String?
    ) async {
        do {
            let provider = try await ArchiveFolderProvider.open(
                archiveURL: url, engine: engine, password: password
            )
            panel.go(to: provider)
        } catch let error as ArchiveError where error.needsPassword {
            promptForPassword(archiveName: url.lastPathComponent) { [weak self] result in
                guard let self, let result else { return }
                Task { await self.openArchive(at: url, in: panel, password: result.password) }
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
    }

    public func panelDidChangeSelection(_ panel: PanelViewController) {
        if let index = panels.firstIndex(where: { $0 === panel }) { activePanelIndex = index }
    }

    public func panel(_ panel: PanelViewController, didFailWith error: any Error) {
        // Routed through reportFailure so an encrypted nested archive says "wrong
        // password" rather than dumping a raw engine message.
        reportFailure(error)
    }
}

// MARK: - Window delegate

extension MainWindowController: NSWindowDelegate {}

// MARK: - Toolbar delegate

extension MainWindowController: NSToolbarDelegate {

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []
        for action in ToolbarAction.allCases {
            identifiers.append(action.itemIdentifier)
            if action == .test { identifiers.append(.space) }
        }
        return identifiers
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarAction.allCases.map(\.itemIdentifier) + [.space, .flexibleSpace]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let action = ToolbarAction.allCases.first(where: { $0.itemIdentifier == itemIdentifier })
        else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = action.title
        item.paletteLabel = action.title
        item.toolTip = action.title
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.title)
        item.target = self
        item.action = #selector(toolbarActionInvoked(_:))
        item.isBordered = true
        return item
    }
}
