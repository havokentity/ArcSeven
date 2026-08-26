// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// ArcSeven's Finder context menu.
//
// This is the macOS stand-in for 7-Zip's Explorer shell extension (docs/DIVERGENCES.md
// D-11, FIDELITY SHL-01). Windows injects a DLL into `explorer.exe`; macOS offers a
// sandboxed app extension that Finder talks to over XPC, and that difference in trust level
// is the whole design below.
//
// ---------------------------------------------------------------------------------------
// The flow, end to end
// ---------------------------------------------------------------------------------------
//   1. The user Control-clicks a selection in Finder.
//   2. Finder asks this extension for a menu. `menu(for:)` reads the selection from
//      `FIFinderSyncController`, looks at *nothing but path extensions*, and returns up to
//      three items. No submenu: "Compress with ArcSeven" sits in the context menu itself,
//      one click away, exactly as Keka's item does.
//   3. The user picks one. Finder sends the item's action back to this object.
//   4. The action re-reads the selection, builds a `FinderRequest`, and writes it as JSON
//      into the App Group container at `Requests/<uuid>.json`.
//   5. It then opens `arcseven://finder-request?id=<uuid>`, which launches or activates
//      ArcSeven.app.
//   6. The app consumes the request file and does the actual work.
//
// ---------------------------------------------------------------------------------------
// Why the extension does no work of its own
// ---------------------------------------------------------------------------------------
// It cannot, and it should not want to. An appex is sandboxed — the system refuses to load
// one that is not — so it has no right to spawn the app's bundled `Contents/Helpers/7zz`; a
// child inherits only the *static* entitlements of its parent and none of the dynamic
// PowerBox grants, so even a spawn that started could not read the files it was asked
// about. Finder Sync extensions are also long-lived and multiply-instantiated — the system
// makes extra copies for Open and Save panels — so a half-hour compression running inside
// one is a process that can be killed at any moment with a half-written archive on disk.
// docs/ENGINE-PROTOCOL.md §1.6 makes this a rule: the app is the only process that spawns
// `7zz`.
//
// ---------------------------------------------------------------------------------------
// Security-scoped access: not needed here, deliberately not taken
// ---------------------------------------------------------------------------------------
// `selectedItemURLs()` hands an appex URLs it would otherwise have no right to touch, and
// the usual ritual is `startAccessingSecurityScopedResource()` / `stopAccessing…` around
// every access. That ritual buys access to file *contents*, and this extension never opens,
// stats, reads or writes one of those files. It looks at `pathExtension` and copies out
// `path` — both string arithmetic on a URL already in memory, both legal on a URL you have
// no permission for at all.
//
// So the calls are omitted on purpose, and their absence is not an oversight:
//
//   * These URLs are not security-scoped in the first place.
//     `startAccessingSecurityScopedResource()` returns `false` for them, and code that
//     treats that `false` as an error refuses to do work it was always allowed to do.
//   * Every unbalanced successful call leaks a sandbox extension token for the life of the
//     process, and this process lives as long as Finder does.
//
// The paths then travel to the app as plain strings, and the app — which is *not* sandboxed
// (project.yml, docs/ARCHITECTURE.md) — opens them under its own TCC grants. Handing over
// strings rather than bookmarks is what keeps the appex out of the permission story.
//
// ---------------------------------------------------------------------------------------
// Two things that must be right, or none of this ever runs
// ---------------------------------------------------------------------------------------
//   * **The user must enable the extension.** Finder Sync extensions ship disabled. The
//     switch is System Settings ▸ General ▸ Login Items & Extensions ▸ Finder Extensions on
//     macOS 15.2 and later (Privacy & Security ▸ Extensions on macOS 14; the pane was
//     missing entirely in 15.0/15.1 — see D-11). The app cannot flip it: macOS does not let
//     an application enable its own extension. Settings ▸ Integration reports the state via
//     `FIFinderSyncController.isExtensionEnabled` and links to the pane. The containing app
//     must also have been launched at least once, from a stable location, before macOS
//     registers the extension at all.
//   * **`directoryURLs` must be set, and must cover where the user actually is.** Finder
//     never consults an extension outside the directories it claims. `init()` below claims
//     `/` and `/Volumes`: claiming `/` alone is not enough, because a mounted volume is a
//     separate filesystem and Finder does not carry the claim across the mount point, so
//     without the second entry the menu vanishes on every external disk, disk image and
//     network share. Some locations (`/Applications`, notably) never work no matter what is
//     claimed — one of the three reasons ArcSeven also ships Services and Quick Actions.
//
// Deliberately not here yet: the Settings ▸ Integration verb checklist and the "Cascaded
// context menu" / "Icons in context menu" toggles. Honouring those means reading
// `UserDefaults(suiteName:)` from inside `menu(for:)`, and that is Finder's UI path — see
// the note on `menu(for:)`. It wants a cheap in-memory snapshot refreshed by notification,
// which is a separate change.

import AppKit
import FinderSync
import os

/// The extension's principal object.
///
/// - Important: The name is load-bearing in two directions and neither is checked at build
///   time. `project.yml` generates this bundle's `Info.plist` with
///   `NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).FinderSyncExtension`, so the Swift
///   class must keep this exact name and must **not** carry an `@objc(…)` rename — a renamed
///   class registers under the bare name only, `NSClassFromString("<Module>.FinderSyncExtension")`
///   then returns nil, and Finder silently never loads the extension.
///
///   The other direction is the module name. `PRODUCT_MODULE_NAME` must not be `FinderSync`,
///   because a Swift module cannot import a framework that shares its own name: `import
///   FinderSync` below is dropped with a warning and every `FI…` symbol goes undefined. See
///   the integration note at the end of this file.
final class FinderSyncExtension: FIFinderSync {
    private static let log = Logger(
        subsystem: "com.havokentity.ArcSeven.FinderSync",
        category: "handoff"
    )

    /// Extensions matched by "Extract with ArcSeven".
    ///
    /// Deliberately a *short* list of the formats a user recognises on sight, not the
    /// hundred-odd things `7zz` can open. This test runs on Finder's menu path, where the
    /// only affordable question is "does the name end in one of these", and a false positive
    /// costs the user a failed extraction. Everything not listed is still reachable through
    /// "Open with ArcSeven", the Services submenu and Quick Actions.
    ///
    /// Compared lower-cased, so `.ZIP` and `.Zip` match. Multi-part extensions need no
    /// special case: `URL.pathExtension` of `archive.tar.gz` is `gz`.
    private static let archiveExtensions: Set<String> = [
        "7z", "zip", "rar", "tar", "gz", "tgz", "bz2", "xz", "iso",
        "cab", "arj", "lzh", "cpio", "rpm", "deb", "dmg", "wim", "zst",
    ]

    /// Every directory this extension claims.
    ///
    /// **A claim does not cross a mount point.** Claiming `/` covers the boot volume and
    /// nothing else; claiming `/Volumes` covers that directory but NOT the separate
    /// filesystems mounted inside it. Reported from real use: the menu appeared
    /// everywhere except on an external drive under `/Volumes/…`, which is exactly the
    /// case a naive `["/", "/Volumes"]` claim misses.
    ///
    /// So every mounted volume is claimed individually, and the set is refreshed when
    /// volumes come and go — a drive plugged in after launch would otherwise stay
    /// unclaimed for the lifetime of the extension.
    ///
    /// `skipHiddenVolumes` keeps the system's own firmlinked volumes
    /// (`/System/Volumes/VM`, `Preboot`, `Update`, …) out of the set. Claiming those
    /// buys nothing — the user never browses them — and each claim costs Finder work.
    private static func currentClaimedDirectoryURLs() -> Set<URL> {
        var claimed: Set<URL> = [
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in mounted {
            // A non-browsable volume is one Finder itself will not show.
            let browsable = (try? volume.resourceValues(forKeys: [.volumeIsBrowsableKey]))?
                .volumeIsBrowsable ?? true
            if browsable { claimed.insert(volume) }
        }
        return claimed
    }

    /// Tokens for the mount/unmount observers, so `deinit` can actually remove them.
    private var volumeObservers: [any NSObjectProtocol] = []

    // MARK: Lifecycle

    override init() {
        super.init()
        refreshClaimedDirectories()

        // Volumes mounted after launch must be claimed too, or plugging in a drive
        // silently loses the menu until the extension is restarted.
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            // Keep the token. `addObserver(forName:object:queue:using:)` returns an opaque
            // observer that is NOT `self`, and `removeObserver(self)` therefore does not
            // remove it — the block outlives this object and fires on a deallocated
            // instance. Storing the tokens and removing them individually is the only
            // thing that actually unregisters a block-based observer.
            volumeObservers.append(
                notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.refreshClaimedDirectories()
                }
            )
        }

        Self.log.debug(
            "ArcSeven Finder extension loaded from \(Bundle.main.bundlePath, privacy: .public)"
        )
    }

    deinit {
        let notifications = NSWorkspace.shared.notificationCenter
        for observer in volumeObservers { notifications.removeObserver(observer) }
    }

    /// Recompute and apply the claim set.
    private func refreshClaimedDirectories() {
        let claimed = Self.currentClaimedDirectoryURLs()
        FIFinderSyncController.default().directoryURLs = claimed
        Self.log.debug("claiming \(claimed.count, privacy: .public) directories")
    }

    // Badging is not implemented, on purpose. ArcSeven syncs nothing, so
    // `requestBadgeIdentifier(for:)` stays unimplemented: badging every file in the user's
    // home directory to advertise an archiver would be obnoxious, and it is the single most
    // expensive thing a Finder Sync extension can do. Same for the toolbar item — no
    // `toolbarItemName`, so Finder shows no button for us.

    // MARK: Menu

    /// Build the context menu.
    ///
    /// - Important: This runs on Finder's UI path, synchronously, while the user is holding
    ///   the mouse down. **Nothing in here may block.** No `stat`, no directory read, no
    ///   resource-value lookup, no `UserDefaults`, no XPC, no `FileManager` at all — a
    ///   stalled network mount would turn a right-click into a beachball in the Finder, not
    ///   in us. The only inspection performed is `pathExtension`, a substring search on a
    ///   string already in memory.
    ///
    ///   That is also why "does this archive contain anything" and "is this `foo.zip`
    ///   actually a folder named `foo.zip`" are not asked: both need I/O. The app answers
    ///   them when it opens the request.
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let urls: [URL]
        switch menuKind {
        case .contextualMenuForItems:
            urls = FIFinderSyncController.default().selectedItemURLs() ?? []

        case .contextualMenuForContainer:
            // Right-click on a Finder window's background: the "selection" is the folder
            // being browsed, so Compress compresses that folder. The Windows original
            // behaves the same way for a background click.
            urls = FIFinderSyncController.default().targetedURL().map { [$0] } ?? []

        default:
            // Sidebar and toolbar menus are not claimed. Returning nil leaves them alone
            // rather than adding a third place for the same three commands.
            return nil
        }

        guard !urls.isEmpty else { return nil }

        // ONE top-level item with a submenu, not three siblings.
        //
        // Three separate entries is what Apple's template does, and it is what we shipped
        // first, but it costs three lines of a menu that every other app is also competing
        // for — and the user asked for the shape Keka uses. A single branded item also
        // means the icon appears once instead of three times.
        let menu = NSMenu(title: "ArcSeven")

        // Automatic enabling would ask Finder's responder chain whether it responds to our
        // selectors. It does not — the actions are routed back to this object by the
        // extension host — so leaving it on greys out every item.
        menu.autoenablesItems = false

        let root = NSMenuItem(title: "ArcSeven", action: nil, keyEquivalent: "")
        root.isEnabled = true
        root.image = Self.menuIcon

        let submenu = NSMenu(title: "ArcSeven")
        submenu.autoenablesItems = false

        addItem(to: submenu, title: "Compress…", action: #selector(compressWithArcSeven(_:)))

        if Self.everyItemLooksLikeAnArchive(urls) {
            // Three, not one. "Extract Here" decides for itself, which is right as a default
            // but wrong as the only option: someone who knows what is in the archive should
            // not have to accept a guess. The two explicit commands sit beneath it.
            addItem(to: submenu, title: "Extract Here", action: #selector(extractWithArcSeven(_:)))
            addItem(to: submenu, title: "Extract Loose", action: #selector(extractLoose(_:)))
            addItem(
                to: submenu,
                title: "Extract to Subfolder",
                action: #selector(extractToSubfolder(_:))
            )
        }

        addItem(to: submenu, title: "Open in ArcSeven", action: #selector(openWithArcSeven(_:)))

        root.submenu = submenu
        menu.addItem(root)
        return menu
    }

    /// The containing app's icon, at menu size.
    ///
    /// Computed once. `menu(for:)` runs on Finder's UI path while the mouse is held down,
    /// and reading an icon off disk there is exactly the kind of I/O that turns a
    /// right-click into a beachball — so it is resolved at load and reused.
    ///
    /// `Bundle.main` inside an appex is the APPEX, not the app, so the icon has to be
    /// fetched from the containing bundle three levels up
    /// (`ArcSeven.app/Contents/PlugIns/ArcSevenFinder.appex`). `NSWorkspace.icon(forFile:)`
    /// returns the composited app icon rather than a raw asset, which is what Finder's
    /// own menus show.
    private static let menuIcon: NSImage? = {
        let appexURL = Bundle.main.bundleURL
        let containerURL = appexURL
            .deletingLastPathComponent()   // PlugIns
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // ArcSeven.app
        guard containerURL.pathExtension == "app" else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: containerURL.path)
        // 16pt is the size Finder draws a context-menu image at; handing it a 512pt
        // icon makes it downscale on every menu build.
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    /// Append one submenu item.
    ///
    /// The item's `target` is left `nil` on purpose. This menu is serialised across to
    /// Finder's process, where an object reference to `self` means nothing; a nil-targeted
    /// item is routed back to the extension's principal object by the host, which is what
    /// the `FIFinderSync` documentation promises and what Apple's own template relies on.
    /// Setting `target = self` looks tidier and breaks the round trip.
    private func addItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.isEnabled = true
        menu.addItem(item)
    }

    /// `true` when every selected item's extension is in ``archiveExtensions``.
    ///
    /// *Every* item, not any: a mixed selection of one `.zip` and one `.txt` has no sensible
    /// extraction, and offering the command anyway would half-work, which is worse than not
    /// offering it.
    private static func everyItemLooksLikeAnArchive(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { archiveExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: Actions

    // `@objc` because these are dispatched by selector from the extension host. `private` is
    // fine alongside it: Swift access control does not hide a method from the Objective-C
    // runtime.

    @objc private func compressWithArcSeven(_ sender: AnyObject?) { handOff(.compress) }

    @objc private func extractWithArcSeven(_ sender: AnyObject?) { handOff(.extract) }

    @objc private func extractLoose(_ sender: AnyObject?) { handOff(.extractLoose) }

    @objc private func extractToSubfolder(_ sender: AnyObject?) { handOff(.extractToSubfolder) }

    @objc private func openWithArcSeven(_ sender: AnyObject?) { handOff(.open) }

    // MARK: Handoff

    /// Capture the selection, then hand it to the app.
    ///
    /// The capture must happen **here, synchronously**. `selectedItemURLs()` and
    /// `targetedURL()` are documented to return meaningful values only from `menu(for:)` or
    /// from a menu action; read them one runloop turn later and they are nil. Everything
    /// after the capture — the sweep, the file write, the launch — is I/O and goes off the
    /// calling thread.
    private func handOff(_ action: FinderRequestAction) {
        let controller = FIFinderSyncController.default()

        // For an item click this is the selection; for a container click it is empty or nil
        // and the target is the folder the user clicked into.
        let selected = controller.selectedItemURLs() ?? []
        let urls = selected.isEmpty ? (controller.targetedURL().map { [$0] } ?? []) : selected

        guard !urls.isEmpty else {
            Self.log.error("\(action.rawValue, privacy: .public) invoked with an empty selection")
            return
        }

        let request = FinderRequest(action: action, urls: urls)
        Self.log.debug(
            """
            \(action.rawValue, privacy: .public) for \(urls.count) item(s) \
            as \(request.id.uuidString, privacy: .public)
            """
        )

        // `FinderRequest` is `Sendable`, so this crosses cleanly under strict concurrency.
        DispatchQueue.global(qos: .userInitiated).async {
            Self.deliver(request)
        }
    }

    /// Write the request, then ring the doorbell.
    private static func deliver(_ request: FinderRequest) {
        // Opportunistic housekeeping, before the write rather than after: pruning first
        // means the sweep can never see the file we are about to create, so no clock skew or
        // coarse timestamp can delete a request on its way out.
        FinderRequestStore.pruneStale()

        do {
            try FinderRequestStore.write(request)
        } catch {
            // There is nothing useful to show from inside an appex and nothing the user
            // could do: reaching here means the App Group entitlement is missing or the
            // container is unwritable, both build or signing faults. Log where
            // `log stream --predicate 'subsystem == "com.havokentity.ArcSeven.FinderSync"'`
            // will find it, and give up quietly.
            log.error("Could not write Finder request: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let launchURL = request.launchURL else {
            log.error("Could not build a launch URL for \(request.id.uuidString, privacy: .public)")
            FinderRequestStore.remove(id: request.id)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        // Bring ArcSeven forward: the user clicked a menu item and expects a window.
        // Without this, an already-running app would handle the request behind Finder.
        configuration.activates = true
        // Never start a second copy. The request must land in the instance that owns the
        // window the user is about to look at.
        configuration.createsNewApplicationInstance = false

        // Only `id` is captured, so the completion handler stays Sendable-clean whichever
        // queue it is called back on.
        let id = request.id
        NSWorkspace.shared.open(launchURL, configuration: configuration) { _, error in
            if let error {
                // Most likely cause by far: nothing on this machine handles `arcseven://`,
                // because ArcSeven has been moved or deleted. Do not leave the orphan behind.
                log.error("Could not launch ArcSeven: \(error.localizedDescription, privacy: .public)")
                FinderRequestStore.remove(id: id)
            }
        }
    }
}

// ---------------------------------------------------------------------------------------
// INTEGRATION NOTES — what this code depends on outside this directory
// ---------------------------------------------------------------------------------------
//
// Two of the three notes that used to live here described problems that have since been
// fixed. They are kept, marked, because the reasoning is what stops each one recurring.
//
// 1. RESOLVED — the module-name collision. This target used to be called `FinderSync`,
//    which made the Swift module name `FinderSync` too: the same name as Apple's
//    framework. A module cannot import itself, so `import FinderSync` above was discarded
//    ("file is part of module 'FinderSync'; ignoring import") and the target failed with
//    `cannot find type 'FIFinderSync' in scope`. The target is now `ArcSevenFinder`, with
//    `PRODUCT_NAME: ArcSevenFinder`, so no `PRODUCT_MODULE_NAME` override is needed.
//    `NSExtensionPrincipalClass` is `$(PRODUCT_MODULE_NAME).FinderSyncExtension`, which
//    resolves through the same name. Do not rename this target back.
//
// 2. RESOLVED — the app handles `arcseven://`. `Sources/App/AppDelegate.swift`'s
//    `application(_:open:)` filters `scheme == "arcseven"` before anything reaches
//    `openDocument(at:)`, and `handleFinderRequest(_:)` reads the request, removes it, and
//    routes the action. Two differences from what this note originally prescribed, both
//    deliberate on the app's side: it uses `FinderRequestStore.read(id:)` followed by
//    `remove(id:)` rather than `consume(id:)` — removing even when the action then fails,
//    so an unsatisfiable request is not retried on every launch — and staleness is handled
//    by `FinderRequestStore.pruneStale()` at launch rather than by an `isStale()` check at
//    the point of use.
//
// 3. STILL TRUE — there are two copies of the request contract.
//    `Sources/App/FinderRequest.swift` is compiled into the app; this directory's
//    `FinderRequest.swift` is compiled into the appex. They agree on the wire, and this one
//    is a source-compatible superset (it additionally carries `ArcSevenURLScheme` and
//    `isStale(asOf:maximumAge:)`), so consolidating means adding
//    `Extensions/ArcSevenFinder/FinderRequest.swift` to the app target's `sources:` and
//    deleting the other file — not a merge. Until someone does, every edit to either must
//    be mirrored. Note the path: it is `Extensions/ArcSevenFinder/`, not
//    `Extensions/FinderSync/`, which has not existed since the target was renamed.
