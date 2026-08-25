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
    func run(
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

    func reportSuccess(
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

    // MARK: Finder entry points

    /// Extract archives handed over by Finder (extension or Services).
    ///
    /// Extracts each into a sibling folder named after the archive, which is the
    /// "Extract Here"-with-a-folder behaviour people expect from a context menu — no
    /// dialog, because someone who right-clicked and chose Extract has already made
    /// the decision the dialog would ask about.
    public func extractFromFinder(_ urls: [URL]) {
        let archives = urls.filter { FileSystemFolderProvider.isArchive($0) }
        guard let first = archives.first else {
            presentMessage(
                "Nothing to extract",
                "None of the selected items look like an archive ArcSeven can read."
            )
            return
        }
        if archives.count > 1 {
            // Batch extraction needs the operation queue from a later milestone; say so
            // rather than silently doing one of them.
            presentMessage(
                "One at a time for now",
                "\(archives.count) archives were selected. ArcSeven will extract "
                    + "\(first.lastPathComponent); extracting several at once arrives with the "
                    + "operation queue."
            )
        }
        let destination = first
            .deletingLastPathComponent()
            .appendingPathComponent(first.deletingPathExtension().lastPathComponent)
        var request = ExtractRequest(archiveURL: first, destinationURL: destination)
        request.overwriteMode = .autoRename
        startExtraction(request)
    }

    /// Compress items handed over by Finder, opening the Add dialog pre-filled.
    ///
    /// The dialog IS shown here, unlike extraction: compressing has real choices
    /// (format, level, password) and picking silently would be presumptuous.
    public func compressFromFinder(_ urls: [URL]) {
        guard let window, let first = urls.first else { return }

        let base = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        let defaultURL = first
            .deletingLastPathComponent()
            .appendingPathComponent(base.isEmpty ? "Archive" : base)
            .appendingPathExtension("7z")

        let dialog = CompressDialogController(defaultArchiveURL: defaultURL, inputs: urls)
        dialog.present(in: window) { [weak self] request in
            guard let self, var request else { return }
            let destination = request.archiveURL.standardizedFileURL
            request.inputs = request.inputs.filter { $0.standardizedFileURL != destination }
            guard !request.inputs.isEmpty else { return }
            run(
                operation: engine.compress(request),
                title: "Creating \(request.archiveURL.lastPathComponent)"
            ) { result in
                self.reportSuccess(
                    result,
                    title: "Archive created",
                    detail: request.archiveURL.path,
                    reveal: request.archiveURL
                )
            }
        }
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

// MARK: - Toolbar

/// The rebar, and the seven buttons on it. In an extension so the controller body
/// stays inside its size budget; `ToolbarAction` stays file-private because the
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
    private enum ToolbarAction: String, CaseIterable {
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

    @objc private func toolbarActionInvoked(_ sender: NSToolbarItem) {
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
}

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
