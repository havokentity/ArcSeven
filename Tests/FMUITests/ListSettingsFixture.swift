// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Shared setup for the two suites that exercise Settings ▸ File List.
//
// The panel is built over an `ArchiveFolderProvider` carrying a hand-written listing, so
// nothing here touches the disk, spawns `7zz` or depends on what is in the temp directory —
// and `child(at:)` and `parent()` both work, which is what the navigation assertions need.
//
// Every panel gets its own `UserDefaults` suite rather than the standard domain. Two reasons,
// and the second is not obvious: writing `FM.ShowDots` into the standard domain would change
// the appearance of the tester's own installed copy of ArcSeven, and `arcSevenListSettingsDidChange`
// is broadcast to every observer in the process, so a panel left pointing at the standard
// domain would silently re-read someone else's state the moment another test posted.

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import FMKit
@testable import FMUI
@testable import Support

/// A panel over an in-memory archive, plus the scratch defaults domain behind it.
@MainActor
struct ListSettingsFixture {
    /// `docs/` is a directory to descend into; the two `.txt` files are leaves.
    static let archiveURL = URL(fileURLWithPath: "/Users/x/Downloads/demo.7z")

    let panel: PanelViewController
    let defaults: UserDefaults
    private let suiteName: String

    init(_ settings: PanelListSettings = .init(), subPath: String = "") {
        suiteName = "ArcSevenListSettingsTests-\(UUID().uuidString)"
        // A named suite that has never been written cannot fail to open, so the fallback
        // is unreachable; it exists so the fixture is not an optional at every use site.
        defaults = UserDefaults(suiteName: suiteName) ?? .standard

        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        panel = PanelViewController(
            provider: ArchiveFolderProvider(
                archiveURL: Self.archiveURL,
                listing: Self.listing(),
                subPath: subPath,
                engine: engine
            ),
            engine: engine
        )
        // The panel reads its switches through, so the domain IS the setting — there is no
        // second copy on the panel to keep in step.
        write(settings)
        panel.listSettingsStore = defaults
        _ = panel.view              // loadView → configureTable → applyListSettings
        panel.go(to: panel.provider)   // the idiom MainWindowController uses to bring a
                                       // freshly built panel up: it is what builds the
                                       // columns, and without them there is no Name cell
                                       // to inspect.
    }

    func tearDown() {
        Defaults.store.removePersistentDomain(forName: suiteName)
    }

    /// Put a set of switches into the scratch domain, as the settings window would.
    func write(_ settings: PanelListSettings) {
        defaults.set(settings.showDots, forKey: Defaults.showDotsKey)
        defaults.set(settings.showRealFileIcons, forKey: Defaults.showRealFileIconsKey)
        defaults.set(settings.showGrid, forKey: Defaults.showGridKey)
        defaults.set(settings.singleClick, forKey: Defaults.singleClickKey)
        defaults.set(settings.alternativeSelection, forKey: Defaults.alternativeSelectionKey)
    }

    /// Move one switch and tell the panel, exactly as the settings window does.
    func apply(_ settings: PanelListSettings) {
        write(settings)
        panel.listSettingsDidChange()
    }

    static func listing() -> ArchiveListing {
        ArchiveListing(
            url: archiveURL,
            entries: [
                ArchiveEntry(path: "readme.txt", isDirectory: false),
                ArchiveEntry(path: "notes.txt", isDirectory: false),
                ArchiveEntry(path: "docs", isDirectory: true),
                ArchiveEntry(path: "docs/guide.txt", isDirectory: false),
            ]
        )
    }

    // MARK: Waiting

    /// `reload()` loads on a task; the rows appear a hop later.
    func load() async {
        panel.reload()
        for _ in 0..<500 {
            if !panel.isLoading { return }
            await Task.yield()
        }
    }

    /// Give any pending navigation the same number of hops a successful one would need.
    ///
    /// Used to prove a negative: after this many yields a descent that was going to happen
    /// has happened, so a panel still sitting where it started really did stay put.
    func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }

    func waitForPath(toEndWith fragment: String) async -> Bool {
        for _ in 0..<500 {
            if panel.provider.displayPath.hasSuffix(fragment) { return true }
            await Task.yield()
        }
        return false
    }

    // MARK: Reading the list back

    func row(named name: String) throws -> Int {
        try #require(panel.rows.firstIndex { $0.name == name }, "no row named \(name)")
    }

    /// The Name cell the delegate actually builds for a row — the drawn result, not the model.
    func nameCell(row index: Int) throws -> NSTableCellView {
        let column = try #require(
            panel.tableView.tableColumns.first { $0.identifier.rawValue == PropID.name.rawValue },
            "the panel has no Name column"
        )
        let view = panel.tableView(panel.tableView, viewFor: column, row: index)
        return try #require(view as? NSTableCellView, "Name column produced no cell view")
    }
}

/// `Sequence.contains(where:)` is `rethrows`, which `#expect` cannot express — the macro
/// wraps its argument in a non-throwing closure. So the question is asked out here, where
/// it is also more readable than the key-path spelling.
extension PanelViewController {
    var showsParentRow: Bool { rows.contains { $0.isParentRow } }
}
