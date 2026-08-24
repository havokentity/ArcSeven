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

@MainActor
public final class MainWindowController: NSWindowController {

    private let engine: any ArchiveEngine
    private let splitViewController = NSSplitViewController()

    /// The panels, left to right. One entry until the second panel is toggled on.
    private var panels: [PanelViewController] = []

    /// The panel that has focus. Operations act on this one.
    private var activePanelIndex = 0

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
        case .extract:
            extractSelection(from: panel)
        case .info:
            showInfo(for: panel)
        case .add, .test, .copy, .move, .delete:
            // The dialogs these open are the next milestone. Say so plainly rather
            // than failing silently, which reads as a bug.
            presentNotImplemented(action.title)
        }
    }

    private func presentNotImplemented(_ name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "\(name) is not implemented yet"
        alert.informativeText =
            "ArcSeven is at milestone M2: browsing archives and extracting them works. "
            + "The \(name) dialog arrives in a later milestone."
        alert.alertStyle = .informational
        alert.beginSheetModal(for: window)
    }

    // MARK: Operations

    /// Extract the selection, or the whole archive when nothing is selected.
    private func extractSelection(from panel: PanelViewController) {
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage(
                "Not an archive",
                "Open an archive first — Extract works on the contents of an archive."
            )
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Extract"
        openPanel.message = "Choose where to extract \(archive.archiveURL.lastPathComponent)"
        openPanel.directoryURL = archive.archiveURL.deletingLastPathComponent()

        guard let window else { return }
        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = openPanel.url, let self else { return }
            self.runExtraction(
                archiveURL: archive.archiveURL,
                entries: panel.selectedItems.map(\.path),
                destination: destination
            )
        }
    }

    private func runExtraction(archiveURL: URL, entries: [String], destination: URL) {
        let progress = ProgressSheetController(
            title: "Extracting \(archiveURL.lastPathComponent)"
        )
        guard let window else { return }
        progress.present(in: window)

        Task { [engine] in
            var request = ExtractRequest(archiveURL: archiveURL, destinationURL: destination)
            // An empty selection means "everything", which is what 7zFM does when the
            // user presses Extract with no rows highlighted.
            request.selectedEntries = entries.isEmpty ? nil : entries
            request.overwriteMode = .autoRename

            do {
                for try await event in engine.extract(request) {
                    switch event {
                    case .progress(let tick):
                        progress.update(
                            fraction: tick.fractionCompleted,
                            detail: tick.currentItemPath ?? ""
                        )
                    case .finished(let result):
                        progress.finish()
                        self.presentExtractionResult(result, destination: destination)
                    default:
                        break
                    }
                }
            } catch {
                progress.finish()
                self.presentMessage("Extraction failed", error.localizedDescription)
            }
        }
    }

    private func presentExtractionResult(_ result: ArchiveOperationResult, destination: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Extraction complete"
        var text = "Extracted to \(destination.path)."
        if result.hasWarnings {
            // Exit code 1 is success-with-warnings; surface them without calling the
            // operation a failure.
            text += "\n\n\(result.warnings.count) warning(s):\n"
                + result.warnings.prefix(5).map(\.message).joined(separator: "\n")
        }
        alert.informativeText = text
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private func showInfo(for panel: PanelViewController) {
        guard let archive = panel.provider as? ArchiveFolderProvider else {
            presentMessage("No archive open", "Open an archive to see its properties.")
            return
        }
        let listing = archive.listing
        var lines: [String] = []
        lines.append("Path: \(archive.archiveURL.path)")
        if let format = listing.format { lines.append("Type: \(format.rawValue)") }
        lines.append("Files: \(listing.fileCount)")
        lines.append("Folders: \(listing.directoryCount)")
        lines.append("Size: \(ColumnModel.groupedByteCount(listing.totalSize)) bytes")
        if let physical = listing.physicalSize {
            lines.append("Physical size: \(ColumnModel.groupedByteCount(physical)) bytes")
        }
        if let ratio = listing.compressionRatio {
            lines.append(String(format: "Ratio: %.1f%%", ratio * 100))
        }
        lines.append("Solid: \(listing.isSolid ? "Yes" : "No")")
        lines.append("Encrypted: \(listing.isEncrypted ? "Yes" : "No")")
        presentMessage(archive.archiveURL.lastPathComponent, lines.joined(separator: "\n"))
    }

    private func presentMessage(_ title: String, _ body: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.beginSheetModal(for: window)
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
                do {
                    let provider = try await ArchiveFolderProvider.open(archiveURL: url, engine: engine)
                    panel.go(to: provider)
                } catch {
                    self.presentMessage(
                        "Could not open \(url.lastPathComponent)",
                        error.localizedDescription
                    )
                }
            } else {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
                panel.go(to: FileSystemFolderProvider(directoryURL: directory, engine: engine))
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
        presentMessage("Could not open this location", error.localizedDescription)
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
