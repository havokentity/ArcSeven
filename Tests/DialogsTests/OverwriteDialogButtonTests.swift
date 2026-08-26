// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import AppKit
import Foundation
import Testing
@testable import Dialogs

/// The subprocess engine cannot be answered mid-run: a decision becomes one `-ao*` switch
/// for the whole extraction. So a per-file `Yes` is a button that does not mean what it
/// says — through 0.1.5 it was offered against a sheet naming one file and overwrote every
/// collision in the run.
@MainActor
@Suite("Overwrite dialog buttons")
struct OverwriteDialogButtonTests {
    private func makeDialog() -> OverwriteDialogController {
        OverwriteDialogController(
            existing: FileInfo(path: "/tmp/out/keep.txt", size: 10),
            incoming: FileInfo(path: "keep.txt", size: 20)
        )
    }

    private func visibleTitles(_ dialog: OverwriteDialogController) -> Set<String> {
        var found: Set<String> = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.isHidden, !button.title.isEmpty {
                found.insert(button.title)
            }
            view.subviews.forEach(walk)
        }
        if let root = dialog.panelContentViewForTesting { walk(root) }
        return found
    }

    @Test("One collision offers the per-file answers and no bulk answers")
    func singleConflict() {
        let dialog = makeDialog()
        dialog.showsExtraButtons = false
        dialog.showsPerFileButtons = true

        let titles = visibleTitles(dialog)
        #expect(titles.contains("Yes"))
        #expect(titles.contains("No"))
        #expect(!titles.contains("Yes to All"), "nothing to apply to all with one collision")
        #expect(!titles.contains("No to All"))
    }

    /// The regression that matters: a sheet naming one file must not offer a button that
    /// silently acts on every other collision too.
    @Test("Many collisions withdraw the per-file answers")
    func manyConflicts() {
        let dialog = makeDialog()
        dialog.showsExtraButtons = true
        dialog.showsPerFileButtons = false

        let titles = visibleTitles(dialog)
        #expect(!titles.contains("Yes"), "a per-file Yes would overwrite every collision")
        #expect(!titles.contains("No"))
        #expect(titles.contains("Yes to All"))
        #expect(titles.contains("No to All"))
        #expect(titles.contains("Auto Rename"))
    }

    @Test("Return is never the destructive answer when defaultsToNo is set")
    func safeDefault() {
        let dialog = makeDialog()
        dialog.defaultsToNo = true
        #expect(dialog.destructiveButtonHasReturnKeyForTesting == false)
    }
}
