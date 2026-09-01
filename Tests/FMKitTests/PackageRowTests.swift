// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// Packages — `.app`, `.rtfd`, `.photoslibrary` — are directories that Finder presents as
// single opaque items. Through 0.1.5 the provider described one as BOTH navigable and
// not-a-directory, which is a contradiction no branch of `child(at:)` matches: it
// returned `nil`, and because the row still claimed to be navigable the panel never
// reached its Launch Services fallback. Double-clicking a `.app` in ArcSeven did
// nothing whatsoever.
//
// These assertions are on the two flags together, because either one alone looks fine.

import Foundation
import Testing
import ArchiveCore
@testable import FMKit

@Suite("Package rows")
final class PackageRowTests: Sendable {
    private let root: URL
    private let engine: any ArchiveEngine = InertEngine()

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ArcSevenPackageTests-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default

        // A bare directory with a `.app` extension is enough: `isPackage` is answered
        // from the extension's UTI conformance to `com.apple.package`, not from whether
        // the bundle is well formed.
        try manager.createDirectory(
            at: root.appendingPathComponent("Demo.app/Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: root.appendingPathComponent("Notes.rtfd", isDirectory: true),
            withIntermediateDirectories: true
        )
        try manager.createDirectory(
            at: root.appendingPathComponent("plain", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("readme.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("bundle.7z"))
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private var provider: FileSystemFolderProvider {
        FileSystemFolderProvider(directoryURL: root, engine: engine)
    }

    private func item(_ name: String, in items: [FolderItem]) throws -> FolderItem {
        try #require(items.first { $0.name == name }, "no row named \(name)")
    }

    /// The bug, stated as an invariant: a row the panel is told to descend into must have
    /// something to descend into. `isNavigable` without `isDirectory` and without an
    /// archive extension is a dead end.
    @Test("Every navigable disk row can actually be descended into")
    func navigableRowsHaveAChild() async throws {
        let items = try await provider.loadChildren()
        #expect(!items.isEmpty)

        for row in items where row.isNavigable {
            let child = try await provider.child(at: row)
            #expect(child != nil, "\(row.name) claims to be navigable but child(at:) is nil")
        }
    }

    @Test("A package is a leaf, not a folder and not navigable")
    func packagesAreLeaves() async throws {
        let items = try await provider.loadChildren()

        for name in ["Demo.app", "Notes.rtfd"] {
            let package = try item(name, in: items)
            #expect(!package.isNavigable, "\(name) must not be descended into")
            #expect(!package.isDirectory, "\(name) is one item, not a folder")
            // The URL is what the launch fallback needs; without it the row does nothing.
            #expect(package.url != nil, "\(name) has no URL to hand to Launch Services")
        }
    }

    /// Nothing else may be caught by the change: a real folder still descends, and a file
    /// with an archive extension still opens as an archive.
    @Test("Ordinary folders and archives are unaffected")
    func ordinaryRowsUnchanged() async throws {
        let items = try await provider.loadChildren()

        let folder = try item("plain", in: items)
        #expect(folder.isNavigable)
        #expect(folder.isDirectory)

        let archive = try item("bundle.7z", in: items)
        #expect(archive.isNavigable)
        #expect(!archive.isDirectory)
        #expect(try await provider.child(at: archive)?.kind == .archive)

        let file = try item("readme.txt", in: items)
        #expect(!file.isNavigable)
        #expect(!file.isDirectory)
    }
}
