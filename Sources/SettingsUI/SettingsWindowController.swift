// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The settings window — 7zFM's Tools ▸ Options, on a Mac.
//
// Upstream is a modal `PROPSHEET` with OK / Cancel / Apply: nothing takes effect until you
// press a button, and Cancel discards the lot. macOS settings windows are non-modal and
// apply immediately, and that is the one structural change everything else follows from —
// there is no OK button here, so `SettingsStore` writes through on every edit and posts the
// notifications that stand in for upstream's post-OK `SetListSettings()` + `RefreshAllPanels()`
// chain (docs/FIDELITY.md OPT-02).
//
// The tabs are upstream's six with two replaced and one added:
//
//   System   → File Types    Windows registry file associations have no counterpart; macOS
//                            file ownership is LaunchServices' (docs/DIVERGENCES.md D-06).
//   7-Zip    → Integration   An in-process Explorer shell-extension DLL has no counterpart
//                            either; Finder surfaces stand in for it (D-11).
//   Folders,                 kept as they are — a temp folder is a temp folder and a viewer
//   Editor,                  path is a viewer path.
//   Settings
//   Language                 kept, but macOS apps follow the system language (D-26).
//   Shortcuts                new: the keymap preset (docs/SHORTCUTS.md, FIDELITY PST-16).
//
// `Settings` keeps its upstream name even though a tab called Settings inside a window called
// Settings reads oddly, because the fidelity ledger audits it by that name.
//
// Panes are SwiftUI in `NSHostingController`. That is the right call *here* and nowhere near
// the file list: a settings pane is tens of controls that change once a month, not tens of
// thousands of rows that scroll at 120 Hz.

import AppKit
import SwiftUI

@MainActor
public final class SettingsWindowController: NSWindowController {
    /// The one settings window. `Settings…` is a singleton command on macOS; a second copy
    /// would be two views onto one store with no way to tell them apart.
    public static let shared = SettingsWindowController()

    private let store = SettingsStore.shared
    private let tabController = PaneTabViewController()
    private var hasPositionedWindow = false

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PaneMetrics.width, height: PaneMetrics.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        // .preference is the large, centred, label-under-icon toolbar every Mac settings
        // window has had since Big Sur.
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("ArcSevenSettingsWindow")
        // The panes are fixed-size and the window is not resizable, so closing it must not
        // deallocate it — `shared` outlives the close and is reused.
        window.isReleasedWhenClosed = false
        super.init(window: window)

        tabController.tabStyle = .toolbar
        for pane in Pane.allCases {
            tabController.addTabViewItem(makeTabViewItem(for: pane))
        }
        // Capture the store, not `self`: the callback outlives this initialiser and has no
        // business holding the controller alive. Which pane was open last is window state, but
        // it goes through the store because that is the only type that talks to the defaults
        // domain.
        tabController.onSelectionChange = { [store = self.store] index in
            store.selectedPaneIndex = index
        }
        window.contentViewController = tabController

        let stored = store.selectedPaneIndex
        if let stored, tabController.tabViewItems.indices.contains(stored) {
            tabController.selectedTabViewItemIndex = stored
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not loaded from a nib")
    }

    // MARK: Presentation

    /// Show the settings window, bringing an already-open one forward.
    public func show() {
        if let window, !hasPositionedWindow {
            hasPositionedWindow = true
            // `setFrameAutosaveName` records the frame but does not restore it; centre only
            // when there is nothing recorded, so a window the user moved stays where they put it.
            if !window.setFrameUsingName(window.frameAutosaveName) {
                window.center()
            }
        }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Panes

    private enum Pane: Int, CaseIterable {
        case fileTypes, integration, folders, editor, settings, language, shortcuts

        var label: String {
            switch self {
            case .fileTypes: "File Types"
            case .integration: "Integration"
            case .folders: "Folders"
            case .editor: "Editor"
            case .settings: "Settings"
            case .language: "Language"
            case .shortcuts: "Shortcuts"
            }
        }

        /// Preferred symbol first, then fallbacks. An `NSTabViewItem` with no image in toolbar
        /// style renders as a bare label, which looks broken next to six icons.
        var symbolCandidates: [String] {
            switch self {
            case .fileTypes: ["doc.badge.gearshape", "doc.text", "doc"]
            case .integration: ["puzzlepiece.extension", "puzzlepiece", "square.grid.2x2"]
            case .folders: ["folder"]
            case .editor: ["square.and.pencil", "pencil"]
            case .settings: ["list.bullet.rectangle", "list.bullet"]
            case .language: ["globe"]
            case .shortcuts: ["keyboard"]
            }
        }
    }

    private func makeTabViewItem(for pane: Pane) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: makeHostingController(for: pane))
        item.label = pane.label
        item.image = Self.symbol(pane.symbolCandidates, describedAs: pane.label)
        return item
    }

    private func makeHostingController(for pane: Pane) -> NSViewController {
        switch pane {
        case .fileTypes: host(FileTypesPane())
        case .integration: host(IntegrationPane(store: store))
        case .folders: host(FoldersPane(store: store))
        case .editor: host(EditorPane(store: store))
        case .settings: host(SettingsPane(store: store))
        case .language: host(LanguagePane(store: store))
        case .shortcuts: host(ShortcutsPane(store: store))
        }
    }

    /// Wrap a pane. Every pane roots in `.settingsPaneFrame()`, so all seven report the same
    /// preferred size and the window never resizes when the toolbar selection changes.
    private func host<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        controller.preferredContentSize = NSSize(width: PaneMetrics.width, height: PaneMetrics.height)
        return controller
    }

    private static func symbol(_ names: [String], describedAs description: String) -> NSImage? {
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Tab controller

/// `NSTabViewController` is its own tab view's delegate and does real work in those callbacks,
/// so the selected-pane hook is a subclass rather than a stolen delegate.
private final class PaneTabViewController: NSTabViewController {
    /// `@MainActor` because the only thing it does is write main-actor-isolated state, and
    /// `tabView(_:didSelect:)` — its one caller — is main-actor isolated already.
    var onSelectionChange: (@MainActor (Int) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onSelectionChange?(selectedTabViewItemIndex)
    }
}
