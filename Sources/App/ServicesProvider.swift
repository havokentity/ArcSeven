// SPDX-License-Identifier: Apache-2.0
// Copyright (C) 2026 Rajesh D'Monte
//
// The Services menu: the Finder integration that always works.
//
// The Windows original injects a DLL into explorer.exe and its context menu is simply
// there. macOS has no equivalent, and the nearest thing — a Finder Sync extension — must
// be ENABLED by the user in a System Settings pane that Apple moved in macOS 13, renamed
// in 14 and removed outright in 15.0/15.1 (docs/DIVERGENCES.md D-11). A menu a
// meaningful share of users never sees is not integration.
//
// Services need no enabling whatsoever. Declare NSServices in Info.plist, install a
// provider object, and the verbs appear under Finder's right-click ▸ Services with zero
// setup, on every Mac, forever. That is why this file exists and why it is the surface
// the other two (Quick Actions, Finder Sync) are allowed to be flaky around.
//
// ## What this object does, and what it must never do
//
// It reads file URLs off a pasteboard and calls its delegate. That is all. No 7zz spawn,
// no dialog, no file writes. A Services method runs on the main thread inside the app and
// blocks the Services machinery while it does; doing work here would freeze the menu.
// Everything real is the app's job, reached through ``ServicesProviderDelegate``.
//
// ## Wiring, which lives in the app and not here
//
//     let provider = ServicesProvider()
//     provider.delegate = self
//     NSApp.servicesProvider = provider
//     NSUpdateDynamicServices()          // development only; the installed app is scanned
//
// Install it EARLY — before `run()`, or in `applicationWillFinishLaunching(_:)`. A
// Services invocation is what launched the app in the first place, and its message can
// arrive before `applicationDidFinishLaunching(_:)` returns; this is the same bug class
// the queued `pendingURLs` in AppDelegate exists to close. If the delegate genuinely is
// not attached yet, the request is held here and replayed the moment one is set, so a
// slow launch loses nothing.
//
// ## Selector names are a contract with Info.plist
//
// Each `NSMessage` value in the NSServices array must equal the first part of one of the
// selectors below, verbatim. A mismatch is silent: the menu item appears and does
// nothing. The `@objc(...)` spellings are pinned rather than inferred so that renaming a
// Swift parameter cannot quietly break the menu.

import AppKit

/// Told what the user picked in Finder's Services menu.
///
/// The app decides everything else — destination, format, whether to show the Compress
/// or Extract dialog, how to queue two requests that arrive together.
@MainActor
public protocol ServicesProviderDelegate: AnyObject {
    func servicesProvider(_ provider: ServicesProvider, didRequest action: FinderRequestAction, for urls: [URL])
}

/// The object handed to `NSApplication.servicesProvider`.
///
/// `@MainActor` because AppKit delivers service messages on the main thread and because
/// the delegate on the other side is window-owning UI. The `@objc` entry points are not
/// isolation-checked at the ObjC boundary — nothing else may call them.
@MainActor
public final class ServicesProvider: NSObject {
    /// Where the work actually happens. Weak: the app owns both ends.
    public weak var delegate: (any ServicesProviderDelegate)? {
        didSet { flushPending() }
    }

    /// A request that arrived before the delegate was attached.
    private struct PendingRequest {
        let action: FinderRequestAction
        let urls: [URL]
    }

    private var pending: [PendingRequest] = []

    /// Cap on the replay queue. Sixteen is far more than a launch race can produce, and
    /// bounding it means a delegate that never arrives cannot grow the queue forever.
    private static let pendingLimit = 16

    // MARK: - Services

    /// `Services ▸ ArcSeven ▸ Add to Archive…`
    @objc(compressWithArcSeven:userData:error:)
    func compressWithArcSeven(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.compress, pasteboard: pasteboard, error: error)
    }

    /// `Services ▸ ArcSeven ▸ Extract`
    @objc(extractWithArcSeven:userData:error:)
    func extractWithArcSeven(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.extract, pasteboard: pasteboard, error: error)
    }

    /// `Services ▸ ArcSeven ▸ Open Archive`
    @objc(openWithArcSeven:userData:error:)
    func openWithArcSeven(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.open, pasteboard: pasteboard, error: error)
    }

    // MARK: - Info.plist NSMessage aliases

    // project.yml declares nine NSServices entries whose NSMessage values predate the
    // three-verb contract above (`openArchiveService`, `extractHereService`, …). Rather
    // than leave seven menu items pointing at selectors that do not exist — which reads
    // to the user as "the app is broken", not "the plist is stale" — each one that maps
    // onto a verb is forwarded here.
    //
    // The mapping is deliberately lossy and the destination distinctions (Here vs
    // Subfolder vs …) and the format distinctions (7z vs Zip vs the dialog) do NOT
    // survive it: `FinderRequestAction` has three cases, the Finder Sync extension is
    // written against exactly those three, and widening it to carry a destination is a
    // contract change, not a patch. The app applies its own defaults for now.
    //
    // Two declared entries have no verb at all and are deliberately NOT implemented,
    // because forwarding `Test Archive` as `open` would be a lie told in a menu:
    //
    //     testArchiveService   needs a `test` action
    //     checksumService      needs a `hash` action
    //
    // Fixing this properly means one owner reconciling project.yml's NSServices list
    // with `FinderRequestAction`. See the report accompanying this file.

    @objc(testArchiveService:userData:error:)
    func testArchiveService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.test, pasteboard: pasteboard, error: error)
    }

    @objc(openArchiveService:userData:error:)
    func openArchiveService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.open, pasteboard: pasteboard, error: error)
    }

    @objc(extractHereService:userData:error:)
    func extractHereService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.extract, pasteboard: pasteboard, error: error)
    }

    @objc(extractLooseService:userData:error:)
    func extractLooseService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.extractLoose, pasteboard: pasteboard, error: error)
    }

    @objc(extractToSubfolderService:userData:error:)
    func extractToSubfolderService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        // Distinct from `.extract`, which decides for itself. Until 0.1.4 both verbs sent
        // `.extract`, so the two menu items were the same command with two names — and
        // "Extract Here" was the one that lied.
        handle(.extractToSubfolder, pasteboard: pasteboard, error: error)
    }

    @objc(extractFilesService:userData:error:)
    func extractFilesService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.extract, pasteboard: pasteboard, error: error)
    }

    @objc(addToArchiveService:userData:error:)
    func addToArchiveService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.compress, pasteboard: pasteboard, error: error)
    }

    @objc(addTo7zService:userData:error:)
    func addTo7zService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.compress, pasteboard: pasteboard, error: error)
    }

    @objc(addToZipService:userData:error:)
    func addToZipService(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        handle(.compress, pasteboard: pasteboard, error: error)
    }

    // MARK: - Dispatch

    private func handle(
        _ action: FinderRequestAction,
        pasteboard: NSPasteboard,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = Self.fileURLs(on: pasteboard)
        guard !urls.isEmpty else {
            // The one string the user is guaranteed to read, so it says what to do next
            // rather than what went wrong internally.
            error.pointee = Self.emptySelectionMessage(for: action) as NSString
            return
        }
        guard let delegate else {
            enqueue(PendingRequest(action: action, urls: urls))
            return
        }
        delegate.servicesProvider(self, didRequest: action, for: urls)
    }

    private func enqueue(_ request: PendingRequest) {
        pending.append(request)
        if pending.count > Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit)
        }
    }

    private func flushPending() {
        guard let delegate, !pending.isEmpty else { return }
        let queued = pending
        pending.removeAll()
        for request in queued {
            delegate.servicesProvider(self, didRequest: request.action, for: request.urls)
        }
    }

    // MARK: - Pasteboard

    /// Every file URL on the pasteboard, in the order Finder put them there.
    ///
    /// `readObjects(forClasses:)` is the modern read and handles the `public.file-url`
    /// items current Finder writes. The legacy fallback is not superstition: the
    /// NSServices declarations ask for `NSFilenamesPboardType`, and a sender that honours
    /// that literally — an older app, a script driving the Services machinery — puts a
    /// property list of paths on the pasteboard and no URL objects at all. Reading only
    /// the modern form would show that user an empty-selection error for a selection they
    /// can plainly see.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let urls = objects.isEmpty ? legacyFilenames(on: pasteboard) : objects
        return urls.filter(\.isFileURL)
    }

    private static func legacyFilenames(on pasteboard: NSPasteboard) -> [URL] {
        let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        guard let paths = pasteboard.propertyList(forType: type) as? [String] else { return [] }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Strings

    private static func emptySelectionMessage(for action: FinderRequestAction) -> String {
        """
        ArcSeven could not \(verb(for: action)) the selection because Finder did not \
        provide any files. Select one or more files or folders and try again.
        """
    }

    private static func verb(for action: FinderRequestAction) -> String {
        switch action {
        case .compress:           "compress"
        case .extract:            "extract"
        case .test:               "test"
        case .extractLoose:       "extract"
        case .extractToSubfolder: "extract"
        case .open:               "open"
        }
    }
}
