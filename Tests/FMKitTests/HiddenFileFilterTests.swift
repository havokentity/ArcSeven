// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Hidden items in a disk panel.
//
// Through 0.1.5 `loadChildren` asked the filesystem for `.isHiddenKey`, never read the
// answer, and carried a comment saying the filtering happened "below". It did not, so
// `.DS_Store`, `.git`, `.localized` and `~/Library` were in every listing. The comment
// was the only implementation.
//
// The assertions here are on the listing the panel would actually show, not on the
// setting: a flag that is stored and never consulted is exactly the bug being fixed.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

/// `.serialized` because two of these tests write the same `UserDefaults` key. Run in
/// parallel they race, and the failure looks like an inverted filter rather than like a
/// test-isolation problem — which cost half an hour the first time.
@Suite("Hidden file filtering", .serialized)
final class HiddenFileFilterTests: Sendable {
    private let root: URL
    private let engine: any ArchiveEngine = InertEngine()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenHiddenTests-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        try Data("x".utf8).write(to: root.appendingPathComponent("visible.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try manager.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: root.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(
            to: root.appendingPathComponent("sub/.hidden-below")
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/visible-below.txt"))

        // No leading dot, hidden by the `UF_HIDDEN` flag instead — the way `~/Library`
        // and `/Volumes/.timemachine` are hidden. A name test would list this one.
        var flagged = root.appendingPathComponent("Flagged")
        try Data("x".utf8).write(to: flagged)
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func names(showingHidden: Bool?) async throws -> Set<String> {
        let provider = FileSystemFolderProvider(
            directoryURL: root, engine: engine, showsHiddenFiles: showingHidden
        )
        return Set(try await provider.loadChildren().map(\.name))
    }

    @Test("Hidden items are left out of the listing")
    func hiddenItemsAreFiltered() async throws {
        let listed = try await names(showingHidden: false)
        #expect(listed == ["visible.txt", "sub"])
        #expect(!listed.contains(".DS_Store"))
        #expect(!listed.contains(".git"))
        #expect(!listed.contains("Flagged"), "the UF_HIDDEN flag hides an undotted name too")
    }

    @Test("Turning the setting on lists them again")
    func hiddenItemsCanBeShown() async throws {
        let listed = try await names(showingHidden: true)
        #expect(listed == ["visible.txt", "sub", ".DS_Store", ".git", "Flagged"])
    }

    /// The default is Finder's, not `ls`'s: a fresh install with nothing stored hides
    /// them. `bool(forKey:)` answers `false` for an absent key, which is what makes this
    /// work without registering a default.
    @Test("With nothing stored, hidden items are hidden")
    func defaultIsToHide() async throws {
        let defaults = UserDefaults.standard
        let key = FileSystemFolderProvider.showHiddenFilesKey
        let saved = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        let provider = FileSystemFolderProvider(directoryURL: root, engine: engine)
        #expect(!provider.showsHiddenFiles)
        #expect(Set(try await provider.loadChildren().map(\.name)) == ["visible.txt", "sub"])
    }

    /// The wiring the Settings pane needs: a provider built with no explicit answer reads
    /// the key on every load, so flipping the switch and calling `panel.reload()` is the
    /// whole reload path.
    @Test("The listing follows the FM.ShowHiddenFiles default without rebuilding the provider")
    func settingDrivesTheListing() async throws {
        let defaults = UserDefaults.standard
        let key = FileSystemFolderProvider.showHiddenFilesKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        // One provider, read twice, with the setting changed in between.
        let provider = FileSystemFolderProvider(directoryURL: root, engine: engine)

        defaults.set(true, forKey: key)
        #expect(provider.showsHiddenFiles)
        #expect(Set(try await provider.loadChildren().map(\.name)).contains(".git"))

        defaults.set(false, forKey: key)
        #expect(!provider.showsHiddenFiles)
        #expect(!Set(try await provider.loadChildren().map(\.name)).contains(".git"))
    }

    /// A pinned answer is meant for the whole walk. Losing it one level down would show
    /// dot-files inside every folder the user opened.
    @Test("The answer travels with navigation, down and up")
    func filteringSurvivesNavigation() async throws {
        let provider = FileSystemFolderProvider(
            directoryURL: root, engine: engine, showsHiddenFiles: false
        )
        let sub = try #require(
            try await provider.loadChildren().first { $0.name == "sub" }
        )
        let child = try #require(try await provider.child(at: sub))
        #expect(Set(try await child.loadChildren().map(\.name)) == ["visible-below.txt"])

        let back = try #require(try await child.parent())
        #expect(Set(try await back.loadChildren().map(\.name)) == ["visible.txt", "sub"])
    }
}
