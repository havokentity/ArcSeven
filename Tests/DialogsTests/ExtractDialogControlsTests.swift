// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Every control on the Extract sheet has to end up somewhere.
//
// Through 0.1.5 one of them did not. `Restore POSIX permissions` was built, styled, laid
// out, persisted to `FM.Extract.RestorePOSIXPermissions`, and exposed as
// `restoresPOSIXPermissions` with the doc comment "read this after
// `present(in:completion:)` calls back". Nothing read it —
// `MainWindowController.extractSelection` never touches the dialog inside its completion
// — and nothing could have: `ExtractRequest` has no field for it and `7zz` has no switch
// for it. The box persisted its own state and changed nothing else in the world.
//
// So the sweep below is over the sheet's REAL view hierarchy and is exhaustive rather
// than a check for one known string: a new inert control fails it too.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import Dialogs

@MainActor
@Suite("Extract dialog controls")
struct ExtractDialogControlsTests {
    private static let archive = URL(fileURLWithPath: "/Users/x/Downloads/demo.7z")

    private func makeDialog() -> ExtractDialogController {
        ExtractDialogController(archiveURL: Self.archive, selectedEntries: [])
    }

    private func makeHost() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    /// Every button actually IN the sheet, by title.
    ///
    /// Walked from the panel's content view rather than read off the controller: a
    /// control the sheet never adopted answers `title` and `state` perfectly well while
    /// being invisible, which is a mistake this project has shipped before.
    /// `NSPopUpButton` is excluded — it is an `NSButton` subclass whose title is whatever
    /// item happens to be selected.
    private func sheetButtonTitles(_ dialog: ExtractDialogController) -> Set<String> {
        var titles: Set<String> = []
        var stack = dialog.panel.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let button = view as? NSButton, !(button is NSPopUpButton) {
                titles.insert(button.title)
            }
            stack.append(contentsOf: view.subviews)
        }
        return titles
    }

    /// The whole control set, pinned. Adding a toggle that goes nowhere breaks this, which
    /// is the point: the failure is meant to prompt the question "and where does its value
    /// end up?".
    @Test("The sheet offers exactly the controls whose answers the request can carry")
    func controlSetIsHonest() {
        let titles = sheetButtonTitles(makeDialog())
        #expect(
            titles == ["", "Browse…", "Show password",
                       "Eliminate duplication of root folder", "Extract", "Cancel"],
            "unexpected control set: \(titles.sorted())"
        )
    }

    /// Named as well as swept, because this is the one that was there.
    @Test("The dead POSIX-permissions toggle is gone")
    func posixPermissionsToggleIsGone() {
        let titles = sheetButtonTitles(makeDialog())
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("permission") })
    }

    /// The positive control. `Eliminate duplication of root folder` is the other check box
    /// on the sheet and it DOES reach the request — which is the property the removed one
    /// could not have had.
    @Test("Eliminate duplication of root folder is carried into the request")
    func eliminateRootReachesTheRequest() throws {
        for ticked in [true, false] {
            let dialog = makeDialog()
            var request: ExtractRequest?
            dialog.present(in: makeHost()) { request = $0 }
            dialog.eliminateRootCheck.state = ticked ? .on : .off
            dialog.extractButton.performClick(nil)

            let answered = try #require(request, "the sheet never called back")
            #expect(answered.eliminateRootDuplication == ticked)
        }
    }

    /// Removing a grid row is exactly the edit that produces an out-of-range index in an
    /// imperatively built sheet, and construction is where it would trap.
    @Test("The sheet still builds, with the surviving check box in place")
    func sheetStillBuilds() {
        let dialog = makeDialog()
        #expect(dialog.panel.contentView != nil)
        #expect(dialog.eliminateRootCheck.superview != nil,
                "the surviving check box lost its place in the grid")
    }
}
