// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// OPT-23 — Alternative selection mode, the Norton-style scheme.
//
// The distinguishing property is that marks are kept SEPARATELY from the system selection,
// and that operations act on the marks. A test that only checked "the row looks different"
// would miss the half that matters: mark two rows, click a third, and Extract must still
// extract the two that are marked. That is asserted here through `selectedItems`, which is
// the property `MainWindowController+Operations` already reads for every command, so the
// coverage reaches the real callers rather than a parallel API invented for the mode.
//
// Not covered here: KEY-29's `Shift`+arrow range marking, whose polarity is decided by the
// first item touched and then applied across the sweep. That is its own fidelity row and its
// own keyboard work; this file is the model underneath it.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import FMKit
@testable import FMUI
@testable import Support

@MainActor
@Suite("Alternative selection mode", .serialized)
struct AlternativeSelectionTests {
    /// Rows sort to `docs`, `notes.txt`, `readme.txt` — folders first, then names.
    private func fixture(
        mode enabled: Bool = true, showDots: Bool = false
    ) -> ListSettingsFixture {
        ListSettingsFixture(.init(showDots: showDots, alternativeSelection: enabled))
    }

    // MARK: The mode is a mode

    @Test("Insert does nothing at all when the mode is off")
    func marksNeedTheMode() async throws {
        let fixture = self.fixture(mode: false)
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "docs")))
        fixture.panel.toggleMark()

        #expect(fixture.panel.markedPaths.isEmpty)
        #expect(fixture.panel.markedItems.isEmpty)
        #expect(fixture.panel.selectedItems.map(\.name) == ["docs"], "still the OS selection")
    }

    @Test("A mark set while the mode was on is ignored once it is off")
    func marksAreInertWhenTheModeIsOff() async throws {
        let fixture = self.fixture(mode: true)
        defer { fixture.tearDown() }
        await fixture.load()
        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "docs")))
        fixture.panel.toggleMark()
        try #require(fixture.panel.markedItems.map(\.name) == ["docs"])

        fixture.apply(.init(alternativeSelection: false))

        // The selection advanced to notes.txt when the mark was set, and that is what a
        // panel with the mode off must act on.
        #expect(fixture.panel.selectedItems.map(\.name) == ["notes.txt"])
    }

    // MARK: Marking

    @Test("Insert marks the focused row and moves down")
    func insertMarksAndAdvances() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let docs = try fixture.row(named: "docs")

        fixture.panel.selectRows(IndexSet(integer: docs))
        fixture.panel.toggleMark()

        #expect(fixture.panel.markedItems.map(\.name) == ["docs"])
        #expect(
            fixture.panel.tableView.selectedRow == docs + 1,
            "Insert advances one row, so holding it marks a run"
        )
    }

    @Test("Insert on a marked row takes the mark off again")
    func insertTogglesOff() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let docs = try fixture.row(named: "docs")

        fixture.panel.selectRows(IndexSet(integer: docs))
        fixture.panel.toggleMark()
        try #require(fixture.panel.markedItems.map(\.name) == ["docs"])

        fixture.panel.selectRows(IndexSet(integer: docs))
        fixture.panel.toggleMark()

        #expect(fixture.panel.markedItems.isEmpty)
    }

    @Test("Marking stops at the last row rather than wrapping to the top")
    func advanceDoesNotWrap() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let last = fixture.panel.rows.count - 1

        fixture.panel.selectRows(IndexSet(integer: last))
        fixture.panel.toggleMark()

        #expect(fixture.panel.tableView.selectedRow == last)
        #expect(fixture.panel.markedItems.count == 1)
    }

    @Test("The “..” row cannot be marked")
    func parentRowIsNotMarkable() async throws {
        let fixture = self.fixture(mode: true, showDots: true)
        defer { fixture.tearDown() }
        await fixture.load()
        try #require(fixture.panel.rows.first?.isParentRow == true)

        fixture.panel.selectRows(IndexSet(integer: 0))
        fixture.panel.toggleMark()

        #expect(fixture.panel.markedPaths.isEmpty)
        #expect(fixture.panel.tableView.selectedRow == 1, "but the cursor still moves past it")
    }

    // MARK: What the operations act on

    /// The point of the mode, and the assertion that would have caught its absence: the
    /// marks and the system selection disagree, and the marks win.
    @Test("Operations act on the marks, not on the system selection")
    func marksBeatTheSystemSelection() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()

        for name in ["docs", "readme.txt"] {
            fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: name)))
            fixture.panel.toggleMark()
        }
        // Now click something else entirely.
        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "notes.txt")))

        #expect(fixture.panel.selectedItems.map(\.name).sorted() == ["docs", "readme.txt"])
    }

    @Test("With nothing marked, operations still act on the system selection")
    func emptyMarksFallBackToTheSelection() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "notes.txt")))

        #expect(fixture.panel.markedItems.isEmpty)
        #expect(fixture.panel.selectedItems.map(\.name) == ["notes.txt"])
    }

    // MARK: Drawing

    @Test("A marked row is drawn differently from an unmarked one")
    func marksAreVisible() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        let docs = try fixture.row(named: "docs")
        let notes = try fixture.row(named: "notes.txt")

        fixture.panel.selectRows(IndexSet(integer: docs))
        fixture.panel.toggleMark()

        let marked = try fixture.nameCell(row: docs)
        let plain = try fixture.nameCell(row: notes)
        #expect(marked.textField?.textColor == .controlAccentColor)
        #expect(plain.textField?.textColor == .labelColor)
    }

    @Test("Nothing is drawn as marked when the mode is off")
    func nothingIsMarkedWithTheModeOff() async throws {
        let fixture = self.fixture(mode: false)
        defer { fixture.tearDown() }
        await fixture.load()
        let docs = try fixture.row(named: "docs")

        // Reach past `toggleMark`, which refuses outright, and plant the mark directly:
        // even so, the row must draw plain.
        fixture.panel.markedPaths.insert(fixture.panel.rows[docs].path)

        #expect(!fixture.panel.isMarked(rowAt: docs))
        #expect(try fixture.nameCell(row: docs).textField?.textColor == .labelColor)
    }

    // MARK: Lifetime

    @Test("Navigating to another folder drops the marks")
    func navigationClearsMarks() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "docs")))
        fixture.panel.toggleMark()
        try #require(!fixture.panel.markedPaths.isEmpty)

        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        fixture.panel.go(to: ArchiveFolderProvider(
            archiveURL: ListSettingsFixture.archiveURL,
            listing: ListSettingsFixture.listing(),
            subPath: "docs",
            engine: engine
        ))

        #expect(fixture.panel.markedPaths.isEmpty)
    }

    // MARK: Reaching it from the menu

    /// A mode nothing can put a mark into is a mode that does nothing. `Mark Item` is the
    /// only way to make one — Apple keyboards have no `Insert` key — so the command has to
    /// reach the focused panel, and it has to be greyed out when the mode is off.
    @Test("Mark Item marks the focused row of the active panel")
    func markCommandReachesThePanel() async throws {
        let window = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()),
            engine: SevenZipCLIEngine(
                executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
            )
        )
        let panel = window.panels[0]
        let suite = "ArcSevenMarkCommandTest-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { Defaults.store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: Defaults.alternativeSelectionKey)
        panel.listSettingsStore = store

        panel.go(to: ArchiveFolderProvider(
            archiveURL: ListSettingsFixture.archiveURL,
            listing: ListSettingsFixture.listing(),
            subPath: "",
            engine: SevenZipCLIEngine(
                executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
            )
        ))
        for _ in 0..<500 where panel.rows.isEmpty { await Task.yield() }
        panel.selectRows(IndexSet(integer: 0))

        window.markAction(nil)

        #expect(panel.markedItems.map(\.name) == ["docs"])
        #expect(panel.selectedItems.map(\.name) == ["docs"], "and that is what a command acts on")
    }

    @Test("Mark Item is greyed out unless the mode is on")
    func markCommandIsValidated() throws {
        let window = MainWindowController(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory()),
            engine: SevenZipCLIEngine(
                executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
            )
        )
        let item = NSMenuItem(
            title: "Mark Item", action: #selector(MainWindowController.markAction(_:)),
            keyEquivalent: " "
        )
        let suite = "ArcSevenMarkValidationTest-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { Defaults.store.removePersistentDomain(forName: suite) }
        window.panels[0].listSettingsStore = store

        #expect(!window.validateMenuItem(item), "the mode is off")

        store.set(true, forKey: Defaults.alternativeSelectionKey)
        #expect(window.validateMenuItem(item), "the mode is on")

        let other = NSMenuItem(
            title: "Extract…", action: Selector(("extractAction:")), keyEquivalent: ""
        )
        #expect(window.validateMenuItem(other), "everything else keeps AppKit's default")
    }

    /// Refresh is not navigation. ⌘R re-reads the folder; losing a carefully built set of
    /// marks to it would be the same class of bug as losing a selection.
    @Test("Refreshing the same folder keeps the marks")
    func refreshKeepsMarks() async throws {
        let fixture = self.fixture()
        defer { fixture.tearDown() }
        await fixture.load()
        fixture.panel.selectRows(IndexSet(integer: try fixture.row(named: "docs")))
        fixture.panel.toggleMark()
        try #require(fixture.panel.markedItems.map(\.name) == ["docs"])

        await fixture.load()      // reload(), as ⌘R does

        #expect(fixture.panel.markedItems.map(\.name) == ["docs"])
    }
}
