// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// What a double-click DOES. `open(rowAt:)` either starts an async descent or calls
// `NSWorkspace`, neither of which a test can observe, so the decision itself is a
// function — and this is the suite that pins it down.
//
// The case that shipped broken: a `.app` row arrived with `isNavigable == true` and
// `isDirectory == false`, so the descent branch ran, the provider had no branch that
// matched, and the launch fallback was never even considered. The row was inert.

import AppKit
import Foundation
import Testing
@testable import FMKit
@testable import FMUI

@MainActor
@Suite("Row activation")
struct PanelActivationTests {
    private let base = URL(fileURLWithPath: "/Users/x/Documents")

    private func diskRow(
        _ name: String, isNavigable: Bool, isDirectory: Bool
    ) -> FolderItem {
        let url = base.appendingPathComponent(name)
        return FolderItem(
            path: url.path,
            name: name,
            isNavigable: isNavigable,
            isDirectory: isDirectory,
            url: url
        )
    }

    /// The regression. A package carries the flags `FileSystemFolderProvider` now gives
    /// it, and the panel must route it to Launch Services rather than to `child(at:)`.
    @Test("A package row is launched, not descended into")
    func packageLaunches() {
        let app = diskRow("Demo.app", isNavigable: false, isDirectory: false)
        #expect(
            PanelViewController.activation(for: app) == .launch(base.appendingPathComponent("Demo.app"))
        )
    }

    @Test("A document row is launched")
    func documentLaunches() {
        let file = diskRow("readme.txt", isNavigable: false, isDirectory: false)
        #expect(
            PanelViewController.activation(for: file) == .launch(base.appendingPathComponent("readme.txt"))
        )
    }

    @Test("A folder and an archive both descend")
    func navigableRowsDescend() {
        #expect(PanelViewController.activation(
            for: diskRow("sub", isNavigable: true, isDirectory: true)
        ) == .descend)
        #expect(PanelViewController.activation(
            for: diskRow("bundle.7z", isNavigable: true, isDirectory: false)
        ) == .descend)
    }

    @Test("The .. row ascends")
    func parentRowAscends() {
        let up = FolderItem(path: "..", name: "..", isNavigable: true, isDirectory: true)
        #expect(up.isParentRow)
        #expect(PanelViewController.activation(for: up) == .ascend)
    }

    /// A member of an archive that is neither a folder nor a nested archive has no file
    /// on disk behind it, so there is nothing to hand Launch Services. That is the one
    /// case where doing nothing is correct.
    @Test("An archive member with no URL does nothing")
    func urllessRowDoesNothing() {
        let member = FolderItem(path: "docs/manual.txt", name: "manual.txt",
                                isNavigable: false, isDirectory: false)
        #expect(PanelViewController.activation(for: member) == .nothing)
    }
}
