// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import AppKit
import Foundation
import Testing
@testable import ArchiveCore
@testable import FMUI

/// "Extract Here" decides where to put things by looking at the archive.
///
/// Until 0.1.4 it did not decide anything: "Extract Here" and "Extract to Subfolder" were
/// two Services menu items calling the same code, and both wrapped. "Extract Here" was
/// therefore the one that lied.
@MainActor
@Suite("Finder extraction destination")
struct FinderExtractionTests {
    private let archive = URL(fileURLWithPath: "/Users/x/Downloads/project-1.0.zip")

    private func listing(_ paths: [(String, Bool)]) -> ArchiveListing {
        ArchiveListing(
            url: archive,
            entries: paths.map { path, isDirectory in
                ArchiveEntry(path: path, isDirectory: isDirectory)
            }
        )
    }

    @Test("A single root folder extracts loose, avoiding Foo/Foo")
    func singleRootFolderExtractsLoose() {
        let single = listing([
            ("project-1.0", true),
            ("project-1.0/README.md", false),
            ("project-1.0/src/main.swift", false),
        ])
        #expect(MainWindowController.rootEntryCount(of: single) == 1)
        let destination = MainWindowController.extractionDestination(
            forArchive: archive, rootEntryCount: 1
        )
        #expect(destination.path == "/Users/x/Downloads")
    }

    @Test("A single root file extracts loose")
    func singleRootFileExtractsLoose() {
        let single = listing([("report.pdf", false)])
        #expect(MainWindowController.rootEntryCount(of: single) == 1)
        #expect(
            MainWindowController.extractionDestination(forArchive: archive, rootEntryCount: 1).path
                == "/Users/x/Downloads"
        )
    }

    /// The case the whole feature exists for.
    @Test("Many loose root items are wrapped instead of scattered")
    func scatteringArchiveIsWrapped() {
        let bomb = listing((0..<40).map { ("file-\($0).txt", false) })
        #expect(MainWindowController.rootEntryCount(of: bomb) == 40)
        let destination = MainWindowController.extractionDestination(
            forArchive: archive, rootEntryCount: 40
        )
        #expect(destination.path == "/Users/x/Downloads/project-1.0")
    }

    /// `zip -D` and most tar streams omit directory entries entirely. Counting only entries
    /// that carry no separator would see no roots at all and scatter the archive.
    @Test("Implicit directories still count as roots")
    func implicitDirectoriesCount() {
        let implicit = listing([
            ("src/main.swift", false),
            ("src/util.swift", false),
            ("docs/readme.md", false),
        ])
        #expect(MainWindowController.rootEntryCount(of: implicit) == 2, "src and docs")
        #expect(
            MainWindowController.extractionDestination(forArchive: archive, rootEntryCount: 2).path
                == "/Users/x/Downloads/project-1.0"
        )
    }

    @Test("A single implicit root folder still extracts loose")
    func singleImplicitRoot() {
        let implicit = listing([
            ("project-1.0/a.txt", false),
            ("project-1.0/b/c.txt", false),
        ])
        #expect(MainWindowController.rootEntryCount(of: implicit) == 1)
    }

    /// An unreadable listing must not be read as "no roots, so extract loose".
    @Test("An empty listing wraps rather than scattering")
    func emptyListingWraps() {
        #expect(MainWindowController.rootEntryCount(of: listing([])) == 0)
        #expect(
            MainWindowController.extractionDestination(forArchive: archive, rootEntryCount: 0).path
                == "/Users/x/Downloads/project-1.0"
        )
    }

    @Test("Extract to Subfolder always wraps, whatever the archive holds")
    func subfolderAlwaysWraps() {
        #expect(
            MainWindowController.subfolderDestination(for: archive).path
                == "/Users/x/Downloads/project-1.0"
        )
    }

    /// A multi-part extension keeps only the last component removed, matching what Finder
    /// shows: `a.tar.gz` wraps into `a.tar`, not `a`.
    @Test("The wrapper is named from the archive without its final extension")
    func wrapperNaming() {
        let tarball = URL(fileURLWithPath: "/tmp/backup.tar.gz")
        #expect(MainWindowController.subfolderDestination(for: tarball).path == "/tmp/backup.tar")
    }
}
