// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Quick Look preview extension: press Space on an archive in the Finder and see what
// is inside it.
//
// This exists because macOS has no answer to that question. Space on a .zip gets a large
// icon and a byte count; Space on a .7z gets nothing at all. The one thing a person wants
// to know before double-clicking an archive - what is in it - is the one thing the system
// will not tell them.
//
// WHAT THIS EXTENSION MAY NOT DO, and why the parsing lives in this bundle rather than
// being asked of the app:
//
//   * It may not run `7zz`. The helper is inside the container app's bundle, and a
//     sandboxed app extension has no right to execute it. This is not a policy choice that
//     could be relaxed with an entitlement; it is what the appex sandbox is.
//   * It may not take its time. quicklookd spawns this process for a file the user is
//     merely hovering over, gives it a small memory allowance, and kills it shortly after
//     the panel closes. Everything here is bounded: bytes read, entries walked, rows built.
//   * It may not hold the file open. `QLPreviewingController`'s own documentation asks
//     that the descriptor be closed before the preview is presented, and an extension
//     sitting on a descriptor keeps a volume from ejecting. The reader closes it before
//     this method returns.
//
// So the archive's directory is parsed here, in Swift, read-only, header-only, with every
// field bounds-checked. See ArchiveDirectoryReader.swift for the dispatch and
// ZIPDirectoryReader.swift / SevenZipSignatureReader.swift for the two formats.

import AppKit
import QuickLookUI

/// The principal class named by `NSExtensionPrincipalClass` in Info.plist.
///
/// `@preconcurrency` on the conformance is required and correct. `QLPreviewingController`
/// is an Objective-C protocol carrying no concurrency annotations, so its requirements are
/// nominally non-isolated, while `NSViewController` - and therefore this class - is
/// `@MainActor`. The header states that the system calls the prepare methods on the main
/// thread, which is exactly the guarantee `@preconcurrency` records: keep the main-actor
/// isolation, check it at runtime, and stop the compiler from demanding a `nonisolated`
/// implementation that would then have to hop back to touch the view anyway.
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {

    private let listingView = ArchiveListingView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 420)
    )

    override func loadView() {
        view = listingView
        view.setAccessibilityLabel("Archive contents")
        preferredContentSize = NSSize(width: 620, height: 420)
    }

    /// Read the archive's directory and render it.
    ///
    /// Never throws, on purpose. Throwing here replaces the whole preview with Quick Look's
    /// generic "no preview available" slab, which tells the user strictly less than we
    /// already know - "the ZIP directory points past the end of the file" is a useful
    /// sentence, and a malformed archive is a thing to *report*, not an exception to
    /// propagate. `ArchiveDirectoryReader.read(fileAt:)` therefore returns a directory
    /// whose body is that sentence, and it always returns one.
    ///
    /// The `await` is the point of the method: `read(fileAt:)` is a non-isolated async
    /// function, so it runs on the concurrent pool rather than on this main-actor method's
    /// executor, and the panel stays responsive while a large central directory is walked.
    func preparePreviewOfFile(at url: URL) async throws {
        let directory = await ArchiveDirectoryReader.read(fileAt: url)
        listingView.apply(directory)

        // Sized to the content now that there is content: a three-file archive should not
        // open a half-empty 620x420 panel.
        preferredContentSize = listingView.preferredSize
    }
}
