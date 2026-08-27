// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Everything Finder hands over: the three extract verbs, Test, and Compress.
//
// Split out of MainWindowController.swift for size; this is the same type. It is a coherent
// seam rather than an arbitrary cut — every entry point here is reached from a Services verb
// or the Finder Sync extension, never from the app's own UI, and each one has to decide a
// destination without a panel to ask.

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(Dialogs)   // module-guard
import Dialogs
#endif

extension MainWindowController {
    /// Extract an archive handed over by Finder.
    public func extractFromFinder(_ urls: [URL], mode: FinderExtractionMode = .smart) {
        let archives = urls.filter { FileSystemFolderProvider.isArchive($0) }
        guard let first = archives.first else {
            presentMessage(
                "Nothing to extract",
                "None of the selected items look like an archive ArcSeven can read."
            )
            return
        }
        if archives.count > 1 {
            // Batch extraction needs the operation queue from a later milestone; say so
            // rather than silently doing one of them.
            presentMessage(
                "One at a time for now",
                "\(archives.count) archives were selected. ArcSeven will extract "
                    + "\(first.lastPathComponent); extracting several at once arrives with the "
                    + "operation queue."
            )
        }

        switch mode {
        case .subfolder:
            startFinderExtraction(of: first, into: Self.subfolderDestination(for: first))
            return
        case .loose:
            // No listing needed: the answer does not depend on what is inside.
            startFinderExtraction(of: first, into: Self.looseDestination(for: first))
            return
        case .smart:
            break
        }

        // Deciding needs the listing, and listing is a subprocess round trip, so this is
        // the one path that has to reach the engine before it can build the request.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let destination: URL
            var listing: ArchiveListing?
            do {
                let fetched = try await engine.list(ListRequest(archiveURL: first))
                listing = fetched
                destination = Self.extractionDestination(
                    forArchive: first, rootEntryCount: Self.rootEntryCount(of: fetched)
                )
            } catch {
                // Encrypted headers, a corrupt archive, a format 7zz declines: we cannot
                // see inside, so we cannot rule out a scatter. Wrap, which is the choice
                // that is merely mildly annoying when wrong.
                destination = Self.subfolderDestination(for: first)
            }
            startFinderExtraction(of: first, into: destination, listing: listing)
        }
    }

    /// Test an archive handed over by Finder, without opening it in a panel.
    public func testArchiveFromFinder(_ urls: [URL]) {
        let archives = urls.filter { FileSystemFolderProvider.isArchive($0) }
        guard let first = archives.first else {
            presentMessage(
                "Nothing to test",
                "None of the selected items look like an archive ArcSeven can read."
            )
            return
        }
        let request = TestRequest(archiveURL: first)
        run(
            operation: engine.test(request),
            title: "Testing \(first.lastPathComponent)"
        ) { [weak self] result in
            self?.reportSuccess(
                result,
                title: "Test complete",
                detail: "\(first.lastPathComponent) passed its integrity check.",
                reveal: nil
            )
        }
    }

    private func startFinderExtraction(
        of archive: URL, into destination: URL, listing: ArchiveListing? = nil
    ) {
        var request = ExtractRequest(archiveURL: archive, destinationURL: destination)
        // Never destroys anything already on disk, which matters most for the loose case:
        // the destination there is a directory full of the user's own files.
        request.overwriteMode = .autoRename
        startExtraction(request, listing: listing)
    }

    /// The folder the archive itself sits in — no wrapper, whatever it contains.
    ///
    /// Only ever the *wrapper* question. The archive's own directory structure is preserved
    /// either way; flattening that is `ExtractPathMode.noPaths`, a different setting with a
    /// confusingly similar name in 7-Zip's own vocabulary ("extract without folder
    /// structure"), which is why this command is not called "Extract Without Folder".
    static func looseDestination(for archive: URL) -> URL {
        archive.deletingLastPathComponent()
    }

    /// `<enclosing folder>/<archive name without extension>/`.
    static func subfolderDestination(for archive: URL) -> URL {
        archive
            .deletingLastPathComponent()
            .appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
    }

    /// How many distinct items the archive has at its top level.
    ///
    /// Counted over every entry's first path component rather than over entries whose path
    /// has no separator: an archive can describe `src/main.swift` without carrying an entry
    /// for `src` at all — `zip -D` omits directory entries, and most tar streams do too —
    /// and counting only explicit roots would read that as "no roots" and scatter it.
    static func rootEntryCount(of listing: ArchiveListing) -> Int {
        var roots: Set<String> = []
        for entry in listing.entries {
            let first = entry.path.split(separator: "/", omittingEmptySubsequences: true).first
            if let first { roots.insert(String(first)) }
        }
        return roots.count
    }

    /// Where "Extract Here" should put things.
    ///
    /// One root item means the archive already contains its own folder — or is a single
    /// file — so wrapping it produces `project-1.0/project-1.0/…`, which is the papercut
    /// this avoids. Several root items means extracting loose would scatter them across
    /// the enclosing folder, mixed in with whatever is already there and with no way to
    /// tell afterwards which files just arrived. That is unrecoverable by hand; an
    /// unwanted folder is one drag to fix. The asymmetry is what decides the default.
    ///
    /// Zero roots — an empty or unreadable listing — wraps, for the same reason.
    static func extractionDestination(forArchive archive: URL, rootEntryCount: Int) -> URL {
        rootEntryCount == 1
            ? archive.deletingLastPathComponent()
            : subfolderDestination(for: archive)
    }

    /// Compress items handed over by Finder, opening the Add dialog pre-filled.
    ///
    /// The dialog IS shown here, unlike extraction: compressing has real choices
    /// (format, level, password) and picking silently would be presumptuous.
    public func compressFromFinder(_ urls: [URL]) {
        guard let window, let first = urls.first else { return }

        let base = urls.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : first.deletingLastPathComponent().lastPathComponent
        let defaultURL = first
            .deletingLastPathComponent()
            .appendingPathComponent(base.isEmpty ? "Archive" : base)
            .appendingPathExtension("7z")

        let dialog = CompressDialogController(defaultArchiveURL: defaultURL, inputs: urls)
        dialog.present(in: window) { [weak self] request in
            guard let self, var request else { return }
            let destination = request.archiveURL.standardizedFileURL
            request.inputs = request.inputs.filter { $0.standardizedFileURL != destination }
            guard !request.inputs.isEmpty else { return }
            run(
                operation: engine.compress(request),
                title: "Creating \(request.archiveURL.lastPathComponent)"
            ) { result in
                self.reportSuccess(
                    result,
                    title: "Archive created",
                    detail: request.archiveURL.path,
                    reveal: request.archiveURL
                )
            }
        }
    }
}
