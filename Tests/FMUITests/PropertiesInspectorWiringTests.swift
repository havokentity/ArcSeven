// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The Properties inspector, exercised through the window that owns it.
//
// Two defects lived here at once, and neither is visible from the inspector's own code:
//
//  * `update(listing:entry:)` was correct, documented itself as the hook a panel owner
//    calls from its selection-changed handler, and had ZERO call sites. The panel showed
//    whatever was selected at the moment ⌘I was pressed, forever, while
//    `docs/DIVERGENCES.md` D-27 and `docs/FIDELITY.md` PRP-01 both said it followed the
//    selection live.
//  * `showInfo` built a NEW controller every time. The old one kept itself alive through
//    its own `selfRetain` and stayed attached as a child window at the same origin, so
//    ⌘I twice gave two stacked panels and nothing ever closed the one underneath.
//
// So the assertions here are on the OWNER's behaviour: how many child windows the
// document window is carrying, and what the one inspector is rendering after the panel's
// selection changes. Asserting anything on a controller built by the test would have
// passed against both bugs.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import Dialogs
@testable import FMKit
@testable import FMUI

@MainActor
@Suite("Properties inspector wiring")
struct PropertiesInspectorWiringTests {
    private static let archiveURL = URL(fileURLWithPath: "/Users/x/Downloads/demo.7z")

    private func listing() -> ArchiveListing {
        ArchiveListing(
            url: Self.archiveURL,
            entries: [
                ArchiveEntry(path: "alpha.txt", isDirectory: false),
                ArchiveEntry(path: "beta.txt", isDirectory: false),
            ]
        )
    }

    /// A window whose single panel is already showing the interior of an archive.
    private func makeWindow() async -> (MainWindowController, PanelViewController) {
        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        let controller = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()), engine: engine
        )
        let panel = controller.panels[0]
        panel.go(to: ArchiveFolderProvider(
            archiveURL: Self.archiveURL, listing: listing(), subPath: "", engine: engine
        ))
        await waitForRows(in: panel)
        return (controller, panel)
    }

    /// `reload()` loads on a task; the rows appear a hop later.
    private func waitForRows(in panel: PanelViewController) async {
        for _ in 0..<500 {
            if !panel.rows.isEmpty { return }
            await Task.yield()
        }
    }

    private func row(named name: String, in panel: PanelViewController) throws -> Int {
        try #require(panel.rows.firstIndex { $0.name == name }, "no row named \(name)")
    }

    // MARK: Reuse

    @Test("A second ⌘I reuses the inspector instead of stacking another one")
    func infoDoesNotStack() async throws {
        let (controller, panel) = await makeWindow()
        let window = try #require(controller.window)

        controller.showInfo(for: panel)
        let first = try #require(controller.propertiesInspector)
        #expect(window.childWindows?.count == 1)

        controller.showInfo(for: panel)
        #expect(controller.propertiesInspector === first, "a second inspector was built")
        #expect(window.childWindows?.count == 1, "the panels are stacking")

        controller.showInfo(for: panel)
        #expect(window.childWindows?.count == 1)
    }

    /// Reopening must not bring back a stale snapshot either: the reused instance is
    /// re-rendered on the way in.
    @Test("Reopening renders the selection as it is now")
    func reopeningIsNotStale() async throws {
        let (controller, panel) = await makeWindow()

        panel.selectRows(IndexSet(integer: try row(named: "alpha.txt", in: panel)))
        controller.showInfo(for: panel)
        let inspector = try #require(controller.propertiesInspector)
        #expect(inspector.inspectedEntryPath == "alpha.txt")

        // Selection moves while the inspector is closed, so the selection hook cannot be
        // what carries it — `showInfo` has to.
        panel.selectRows(IndexSet(integer: try row(named: "beta.txt", in: panel)))
        controller.showInfo(for: panel)
        #expect(inspector.inspectedEntryPath == "beta.txt")
    }

    // MARK: Following the selection

    @Test("The inspector follows the panel selection")
    func inspectorFollowsSelection() async throws {
        let (controller, panel) = await makeWindow()

        panel.selectRows(IndexSet(integer: try row(named: "alpha.txt", in: panel)))
        controller.showInfo(for: panel)
        let inspector = try #require(controller.propertiesInspector)
        #expect(inspector.inspectedEntryPath == "alpha.txt")
        #expect(inspector.inspectedTitle.contains("alpha.txt"))
        let alphaRows = inspector.inspectedRowCount
        #expect(alphaRows > 0, "the table never rendered")

        // The real hook, called the way `PanelViewController.tableViewSelectionDidChange`
        // calls it.
        panel.selectRows(IndexSet(integer: try row(named: "beta.txt", in: panel)))
        controller.panelDidChangeSelection(panel)

        #expect(inspector.inspectedEntryPath == "beta.txt", "the panel is frozen")
        #expect(inspector.inspectedTitle.contains("beta.txt"))
        // Asked of the table, not of the row array: a state change that never reached
        // `reloadData` would leave the user looking at the old rows.
        #expect(inspector.inspectedRowCount == alphaRows)
    }

    /// Clearing the selection puts the panel back on the archive itself, which is what
    /// ⌘I with nothing selected shows.
    @Test("Deselecting everything falls back to the archive")
    func emptySelectionShowsTheArchive() async throws {
        let (controller, panel) = await makeWindow()

        panel.selectRows(IndexSet(integer: try row(named: "alpha.txt", in: panel)))
        controller.showInfo(for: panel)
        let inspector = try #require(controller.propertiesInspector)
        #expect(inspector.inspectedEntryPath == "alpha.txt")

        panel.selectRows(IndexSet())
        controller.panelDidChangeSelection(panel)
        #expect(inspector.inspectedEntryPath == nil)
        #expect(inspector.inspectedTitle.contains("demo.7z"))
    }

    /// The hook fires for every panel, including ones showing a directory on disk. An
    /// inspector describing an archive must not be handed a listing that does not exist.
    @Test("A disk panel's selection leaves the inspector alone")
    func diskPanelDoesNotDisturbTheInspector() async throws {
        let (controller, panel) = await makeWindow()
        panel.selectRows(IndexSet(integer: try row(named: "alpha.txt", in: panel)))
        controller.showInfo(for: panel)
        let inspector = try #require(controller.propertiesInspector)

        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        let diskPanel = PanelViewController(
            provider: FileSystemFolderProvider(
                directoryURL: URL(fileURLWithPath: NSTemporaryDirectory()), engine: engine
            ),
            engine: engine
        )
        controller.panelDidChangeSelection(diskPanel)

        #expect(inspector.inspectedEntryPath == "alpha.txt")
        #expect(inspector.inspectedArchiveURL == Self.archiveURL)
    }
}
