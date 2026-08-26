// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Dialogs are built imperatively from arrays of views, which is a shape that fails at
// RUNTIME and compiles perfectly: an out-of-range spacer index, a row never added to its
// parent, a label whose row was forgotten. Nothing in the type system catches those, and
// nothing did catch them — this target exists because adding one row to the Compress
// sheet indexed a fourth element of a three-element array, which would have trapped the
// moment a user opened it.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import Dialogs

@MainActor
@Suite("Compress dialog construction")
struct CompressDialogConstructionTests {
    private func makeDialog() -> CompressDialogController {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        return CompressDialogController(
            defaultArchiveURL: base.appendingPathComponent("out.7z"),
            inputs: [base.appendingPathComponent("input.txt")]
        )
    }

    /// Constructing it runs `buildInterface()` and `refresh()`, which is where an index
    /// error would trap.
    @Test("The sheet builds without trapping")
    func buildsCleanly() {
        let dialog = makeDialog()
        #expect(dialog.passwordErrorRow != nil)
        #expect(dialog.passwordExposureRow != nil)
    }

    /// Existing is not the same as being on screen.
    ///
    /// The exposure row shipped in 0.1.3 built, styled, stored and updated — and never
    /// added to the Encryption section, so it had no superview and was invisible. The test
    /// that was supposed to cover it asserted `isHidden` and `stringValue`, which a
    /// detached view answers perfectly well. Reaching the content view is the property that
    /// actually matters.
    @Test("Every stored row is attached to the sheet")
    func rowsAreInTheViewHierarchy() {
        let dialog = makeDialog()
        let root = dialog.contentRoot
        #expect(root != nil, "no content view was built")

        func reachesRoot(_ view: NSView?) -> Bool {
            var node = view
            while let current = node {
                if current === root { return true }
                node = current.superview
            }
            return false
        }

        let rows: [(String, NSView?)] = [
            ("passwordErrorRow", dialog.passwordErrorRow),
            ("passwordExposureRow", dialog.passwordExposureRow),
            ("secureRow", dialog.secureRow),
            ("verifyRow", dialog.verifyRow),
            ("encryptNamesRow", dialog.encryptNamesRow),
        ]
        for (name, view) in rows {
            #expect(reachesRoot(view), "\(name) is not attached to the sheet")
        }
        #expect(reachesRoot(dialog.passwordExposureLabel),
                "the exposure label itself never reaches the sheet")
    }

    /// The passphrase-exposure note is real: `7zz a` takes the password on argv, where
    /// other local users can see it. It must appear exactly when a password will be used.
    @Test("The exposure note appears only when a password is set")
    func exposureNoteTracksPassword() {
        let dialog = makeDialog()
        #expect(dialog.passwordExposureRow?.isHidden == true, "hidden with no password")
        #expect(dialog.passwordExposureLabel.stringValue.isEmpty)

        dialog.model.password = "correct horse"
        dialog.refresh()
        #expect(dialog.passwordExposureRow?.isHidden == false, "shown once a password is set")
        #expect(dialog.passwordExposureLabel.stringValue.contains("visible"))

        dialog.model.password = ""
        dialog.refresh()
        #expect(dialog.passwordExposureRow?.isHidden == true, "hidden again when cleared")
        #expect(dialog.passwordExposureLabel.stringValue.isEmpty)
    }
}
