// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The dialog end of "Remember in Keychain".
//
// The checkbox is styled, targeted and given a tooltip that promises the archive will
// open without asking again. Two separate things have to be true for that promise to
// hold, and neither is visible from the checkbox itself: it has to be IN the sheet — a
// control with no superview answers `state` and `title` perfectly well while being
// invisible, which is a bug this project has already shipped once — and what it is set
// to has to reach the caller. What the caller then DOES with the flag is asserted in
// `Tests/FMUITests/KeychainPasswordWiringTests.swift`.

import AppKit
import Foundation
import Testing
@testable import Dialogs

@MainActor
@Suite("Password dialog keychain checkbox")
struct PasswordDialogKeychainTests {
    private func makeDialog() -> PasswordDialogController {
        PasswordDialogController(mode: .unlock, archiveName: "secret.7z")
    }

    private func makeHost() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
    }

    private func reaches(_ view: NSView?, _ root: NSView?) -> Bool {
        var node = view
        while let current = node {
            if current === root { return true }
            node = current.superview
        }
        return false
    }

    /// Existing is not the same as being on screen.
    @Test("The checkbox is attached to the sheet")
    func checkboxIsInTheHierarchy() {
        let dialog = makeDialog()
        #expect(reaches(dialog.keychainButton, dialog.panel.contentView),
                "the checkbox never reaches the sheet's content view")
        #expect(dialog.keychainButton.target != nil, "no target: an inert control")
        #expect(dialog.keychainButton.action != nil)
    }

    /// The tooltip is a promise made to the user; it should not survive a change that
    /// takes the storage away again.
    @Test("The checkbox still says what it does")
    func tooltipIsPresent() {
        let dialog = makeDialog()
        let tooltip = dialog.keychainButton.toolTip ?? ""
        #expect(tooltip.contains("keychain") || tooltip.contains("Keychain"))
    }

    @Test("Ticking it is reported to the caller")
    func tickedBoxIsReported() throws {
        let dialog = makeDialog()
        let host = makeHost()

        var answer: PasswordPromptResult?
        dialog.present(in: host) { answer = $0 }
        dialog.keychainButton.state = .on
        dialog.okButton.performClick(nil)

        let result = try #require(answer, "the sheet never called back")
        #expect(result.storeInKeychain, "the checkbox was ticked and the caller was not told")
    }

    @Test("Leaving it alone is reported too")
    func untickedBoxIsReported() throws {
        let dialog = makeDialog()
        let host = makeHost()

        var answer: PasswordPromptResult?
        dialog.present(in: host) { answer = $0 }
        dialog.okButton.performClick(nil)

        let result = try #require(answer)
        #expect(!result.storeInKeychain)
        #expect(dialog.keychainButton.state == .off, "the box starts unticked")
    }
}
