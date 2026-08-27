// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Settings ▸ File List, exercised through the list it is supposed to change.
//
// Every one of these switches persisted a value that no module read. The settings window
// was honest about it — the controls were disabled under a notice naming FMUI as the module
// that had to grow the read — but "honest" is not "working", and FIDELITY.md rated all six
// **1:1** against the Windows original the whole time.
//
// So none of these tests asserts that a preference round-trips. A round-trip test passes
// against the bug: the value was always stored correctly and always ignored. They assert the
// observable instead — which rows exist, which icon API was asked, what `gridStyleMask`
// holds, where the panel ended up after a click — because that is the part that was missing.
//
// OPT-23 has a suite of its own in AlternativeSelectionTests.swift.

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import ArchiveCore
@testable import FMKit
@testable import FMUI
@testable import SettingsUI
@testable import Support

@MainActor
@Suite("File list settings", .serialized)
struct PanelListSettingsTests {
    // MARK: - OPT-18 / DOT-01 — Show ".." item

    @Test("Show “..” item off keeps the parent row out of the list")
    func dotsOffHidesParentRow() async throws {
        let fixture = ListSettingsFixture(.init(showDots: false))
        defer { fixture.tearDown() }
        await fixture.load()

        #expect(!fixture.panel.showsParentRow)
        #expect(fixture.panel.rows.map(\.name) == ["docs", "notes.txt", "readme.txt"])
    }

    @Test("Show “..” item on puts the parent row first")
    func dotsOnShowsParentRow() async throws {
        let fixture = ListSettingsFixture(.init(showDots: true))
        defer { fixture.tearDown() }
        await fixture.load()

        #expect(fixture.panel.rows.first?.isParentRow == true)
        #expect(fixture.panel.rows.map(\.name) == ["..", "docs", "notes.txt", "readme.txt"])
    }

    /// DOT-01: "never in the root folder", whatever the switch says. The archive root is the
    /// only level in this fixture that still has a parent, so the check uses a real one: `/`.
    @Test("The root folder shows no parent row even with the switch on")
    func dotsNeverAtRoot() async throws {
        let engine = SevenZipCLIEngine(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz"), timeZone: .gmt
        )
        let panel = PanelViewController(
            provider: FileSystemFolderProvider(directoryURL: URL(fileURLWithPath: "/"), engine: engine),
            engine: engine
        )
        let suite = "ArcSevenRootRowTest-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { Defaults.store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: Defaults.showDotsKey)
        panel.listSettingsStore = store
        _ = panel.view
        panel.reload()
        for _ in 0..<500 where panel.isLoading { await Task.yield() }

        let rootParent = try await FileSystemFolderProvider(
            directoryURL: URL(fileURLWithPath: "/"), engine: engine
        ).parent()
        try #require(rootParent == nil, "“/” is expected to have no parent")
        try #require(!panel.rows.isEmpty, "“/” listed nothing, so this proves nothing")
        #expect(!panel.showsParentRow)
    }

    // MARK: - OPT-19 — Show real file icons

    /// The fidelity row is specific about the two APIs: off → `NSWorkspace.icon(for: UTType)`,
    /// on → `NSWorkspace.icon(forFile:)`. Asserting the source names which one was asked;
    /// comparing bitmaps alone would only prove the switch does *something*.
    @Test("Real file icons off asks by type, on asks for the file’s own icon")
    func iconSourceFollowsTheSwitch() throws {
        let url = try #require(Self.anApplicationBundle(), "no .app found to test with")
        let item = FolderItem(
            path: url.path, name: url.lastPathComponent,
            isNavigable: false, isDirectory: false, url: url
        )
        #expect(
            PanelViewController.iconSource(for: item, showRealFileIcons: false)
                == .type(Self.appType)
        )
        #expect(
            PanelViewController.iconSource(for: item, showRealFileIcons: true) == .file(url)
        )
    }

    @Test("The two switch positions really do produce different icons")
    func iconsDifferBetweenPositions() throws {
        let url = try #require(Self.anApplicationBundle(), "no .app found to test with")
        let item = FolderItem(
            path: url.path, name: url.lastPathComponent,
            isNavigable: false, isDirectory: false, url: url
        )

        let byType = try #require(Self.pixels(
            PanelViewController.icon(for: item, showRealFileIcons: false)
        ))
        let byFile = try #require(Self.pixels(
            PanelViewController.icon(for: item, showRealFileIcons: true)
        ))

        #expect(
            byType != byFile,
            "\(url.lastPathComponent) draws the same icon either way, so this proves nothing"
        )
        #expect(byFile == Self.pixels(NSWorkspace.shared.icon(forFile: url.path)))
        // Deliberately not `.applicationBundle`: `UTType(filenameExtension: "app")` is
        // `com.apple.application-file`, a different type with a different icon, and it is the
        // one the switched-off path derives. A reference built from the tidier-looking
        // constant would fail against correct code.
        #expect(byType == Self.pixels(NSWorkspace.shared.icon(for: Self.appType)))
    }

    /// Inside an archive there is no file on disk to extract an icon from, so the switch has
    /// nothing to switch to. This is the one place the old unconditional behaviour was right.
    @Test("Inside an archive both positions ask by type")
    func archiveRowsAlwaysAskByType() throws {
        let item = FolderItem(
            path: "docs/guide.txt", name: "guide.txt", isNavigable: false, isDirectory: false
        )
        let text = try #require(UTType(filenameExtension: "txt"))
        for position in [true, false] {
            #expect(
                PanelViewController.iconSource(for: item, showRealFileIcons: position)
                    == .type(text),
                "showRealFileIcons: \(position)"
            )
        }
    }

    @Test("A directory keeps the folder icon on either position")
    func directoriesAreUnaffected() {
        let item = FolderItem(path: "docs", name: "docs", isNavigable: true, isDirectory: true)
        for position in [true, false] {
            #expect(
                PanelViewController.iconSource(for: item, showRealFileIcons: position) == .folder,
                "showRealFileIcons: \(position)"
            )
        }
    }

    // MARK: - OPT-21 — Show grid lines

    @Test("Show grid lines drives the table’s grid style mask")
    func gridLinesFollowTheSwitch() {
        let lined = ListSettingsFixture(.init(showGrid: true))
        defer { lined.tearDown() }
        // LVS_EX_GRIDLINES draws both axes, so both masks move together.
        #expect(lined.panel.tableView.gridStyleMask.contains(.solidHorizontalGridLineMask))
        #expect(lined.panel.tableView.gridStyleMask.contains(.solidVerticalGridLineMask))

        let plain = ListSettingsFixture(.init(showGrid: false))
        defer { plain.tearDown() }
        #expect(plain.panel.tableView.gridStyleMask.isEmpty)
    }

    // MARK: - OPT-22 — Single-click to open an item

    @Test("Single-click off leaves a click on a folder inert")
    func singleClickOffDoesNotOpen() async throws {
        let fixture = ListSettingsFixture(.init(singleClick: false))
        defer { fixture.tearDown() }
        await fixture.load()
        let start = fixture.panel.provider.displayPath

        fixture.panel.openIfSingleClick(rowAt: try fixture.row(named: "docs"))
        await fixture.settle()

        #expect(fixture.panel.provider.displayPath == start)
    }

    @Test("Single-click on opens the clicked row")
    func singleClickOnOpens() async throws {
        let fixture = ListSettingsFixture(.init(singleClick: true))
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.panel.openIfSingleClick(rowAt: try fixture.row(named: "docs"))

        #expect(await fixture.waitForPath(toEndWith: "demo.7z/docs"))
    }

    /// `openIfSingleClick(rowAt:)` is only reachable from a real click if the table has an
    /// action wired at all — which it did not, so a click could never have opened anything.
    @Test("The table has a single-click action wired to the panel")
    func clickActionIsWired() {
        let fixture = ListSettingsFixture()
        defer { fixture.tearDown() }
        #expect(fixture.panel.tableView.action == #selector(PanelViewController.rowClicked(_:)))
        #expect(fixture.panel.tableView.target === fixture.panel)
    }

    /// A double-click delivers the single-click action first, so in single-click mode the
    /// row is already open by the time the double action arrives. Acting on it again
    /// descends two levels for one gesture.
    @Test("The double action stands down in single-click mode")
    func doubleClickDoesNotDescendTwice() async throws {
        let fixture = ListSettingsFixture(.init(singleClick: true))
        defer { fixture.tearDown() }
        await fixture.load()
        let docs = try fixture.row(named: "docs")

        fixture.panel.openIfSingleClick(rowAt: docs)              // the first click opens
        #expect(await fixture.waitForPath(toEndWith: "demo.7z/docs"))

        fixture.panel.openIfDoubleClick(rowAt: 0)                 // the pair completes
        await fixture.settle()
        #expect(fixture.panel.provider.displayPath.hasSuffix("demo.7z/docs"))
    }

    @Test("The double action still opens when single-click is off")
    func doubleClickOpensNormally() async throws {
        let fixture = ListSettingsFixture(.init(singleClick: false))
        defer { fixture.tearDown() }
        await fixture.load()

        fixture.panel.openIfDoubleClick(rowAt: try fixture.row(named: "docs"))

        #expect(await fixture.waitForPath(toEndWith: "demo.7z/docs"))
    }

    // MARK: - The contract with the settings window

    /// FMUI reads these off the standard domain by name rather than linking SettingsUI, so
    /// the two spellings can drift apart with nothing to catch it. This is that something.
    @Test("The keys FMUI reads are the keys the settings window writes")
    func keyNamesMatchSettingsUI() {
        #expect(Defaults.showDotsKey == SettingsKey.showDots.rawValue)
        #expect(Defaults.showRealFileIconsKey == SettingsKey.showRealFileIcons.rawValue)
        #expect(Defaults.showGridKey == SettingsKey.showGrid.rawValue)
        #expect(Defaults.singleClickKey == SettingsKey.singleClick.rawValue)
        #expect(Defaults.alternativeSelectionKey == SettingsKey.alternativeSelection.rawValue)
    }

    @Test("FMUI listens on the name the settings window posts")
    func notificationNameMatchesSettingsUI() {
        #expect(PanelListSettings.didChange == .arcSevenListSettingsDidChange)
    }

    /// The whole chain, in the order it happens for a user: the switch is written, the window
    /// posts, the open panel re-reads and redraws. Nothing here reaches into `listSettings`.
    @Test("Moving a switch in the settings window reaches an open panel")
    func aChangeReachesAnOpenPanel() async throws {
        let fixture = ListSettingsFixture(.init(showDots: false, showGrid: false))
        defer { fixture.tearDown() }
        await fixture.load()
        try #require(!fixture.panel.showsParentRow)
        try #require(fixture.panel.tableView.gridStyleMask.isEmpty)

        fixture.write(.init(showDots: true, showGrid: true))
        NotificationCenter.default.post(name: .arcSevenListSettingsDidChange, object: nil)

        for _ in 0..<500 where !fixture.panel.showsParentRow {
            await Task.yield()
        }
        #expect(fixture.panel.rows.first?.isParentRow == true)
        #expect(fixture.panel.tableView.gridStyleMask.contains(.solidHorizontalGridLineMask))
    }

    // MARK: - Helpers

    /// What OPT-19-off derives for a name ending in `.app`. Resolved once, from the extension,
    /// for the reason spelled out at its use site above.
    private static let appType = UTType(filenameExtension: "app") ?? .data

    /// An installed `.app`, whose own icon differs from the generic one for its type.
    ///
    /// Discovered rather than hard-coded: any single app can be missing from a given install,
    /// and a test that silently skips is a test that stops testing.
    private static func anApplicationBundle() -> URL? {
        let roots = ["/System/Applications", "/Applications", "/System/Library/CoreServices"]
        let generic = pixels(NSWorkspace.shared.icon(for: appType))
        for root in roots {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil
            )) ?? []
            for url in contents.sorted(by: { $0.path < $1.path }) where url.pathExtension == "app" {
                if pixels(NSWorkspace.shared.icon(forFile: url.path)) != generic { return url }
            }
        }
        return nil
    }

    /// The pixels a row's icon actually puts on screen: 16pt, drawn, encoded.
    ///
    /// Not `tiffRepresentation`. A system icon carries a dozen representations at different
    /// sizes and depths, and its TIFF encoding is not stable byte-for-byte between two
    /// fetches of the same icon — two 36 MB blobs of identical length that compare unequal.
    ///
    /// The 16pt resize is not incidental either: it is what
    /// `PanelViewController.icon(for:showRealFileIcons:)` does, and it decides which
    /// representation `draw(in:)` picks. Both sides of every comparison go through this one
    /// function so neither can differ for a reason that has nothing to do with the switch.
    private static func pixels(_ image: NSImage) -> Data? {
        let side = 16
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: side, height: side)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        copy.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        return rep.representation(using: .png, properties: [:])
    }
}
