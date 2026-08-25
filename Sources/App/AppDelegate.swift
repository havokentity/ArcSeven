// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte

import AppKit
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
#if canImport(FMKit)   // module-guard
import FMKit
#endif
#if canImport(FMUI)   // module-guard
import FMUI
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var engine: (any ArchiveEngine)?

    /// URLs delivered before the window existed.
    ///
    /// `application(_:open:)` can fire BEFORE `applicationDidFinishLaunching` — which
    /// is exactly what happens when the app is launched by double-clicking a `.7z` in
    /// Finder, the most important way anyone will ever open this app. Dropping the URL
    /// there means the archive silently does not open, so it is queued and replayed
    /// once the window is up.
    private var pendingURLs: [URL] = []

    /// Serves the right-click ▸ Services entries declared in Info.plist.
    ///
    /// Held for the process lifetime: AppKit keeps only an unowned reference through
    /// `NSApp.servicesProvider`, so letting this deallocate silently breaks every
    /// Services menu item.
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainMenuBuilder.install()

        servicesProvider.delegate = self
        NSApp.servicesProvider = servicesProvider
        // Without this the Services menu keeps a stale cache and newly declared items
        // do not appear until the next login.
        NSUpdateDynamicServices()

        // Anything the Finder extension queued while we were not running.
        FinderRequestStore.pruneStale()

        guard let located = EngineLocator.makeEngine() else {
            presentMissingEngine()
            return
        }
        engine = located.engine

        let start = URL(fileURLWithPath: NSHomeDirectory())
        let controller = MainWindowController(startingAt: start, engine: located.engine)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Replay anything Finder handed us before the window existed.
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { controller.openDocument(at: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Opening an archive from Finder, the Dock, or `open -a`.
    ///
    /// Also the delivery point for `arcseven://finder-request?id=…`, which is how the
    /// sandboxed Finder extension hands work back: it cannot run the bundled 7zz
    /// itself, so it writes a request to the shared container and opens this scheme.
    func application(_ application: NSApplication, open urls: [URL]) {
        let requestURLs = urls.filter { $0.scheme == "arcseven" }
        if !requestURLs.isEmpty {
            for url in requestURLs { handleFinderRequest(url) }
            return
        }
        guard let url = urls.first else { return }
        guard let windowController else {
            pendingURLs.append(url)
            return
        }
        windowController.openDocument(at: url)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Finder hand-off

    /// Consume a request the Finder extension left in the shared container.
    private func handleFinderRequest(_ url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == "finder-request",
            let raw = components.queryItems?.first(where: { $0.name == "id" })?.value,
            let id = UUID(uuidString: raw)
        else { return }

        do {
            let request = try FinderRequestStore.read(id: id)
            // Consume exactly once, even if the action below fails: a request that
            // cannot be satisfied must not be retried forever on every launch.
            FinderRequestStore.remove(id: id)
            perform(request.action, on: request.urls)
        } catch {
            NSLog("ArcSeven: could not read Finder request \(id): \(error.localizedDescription)")
        }
    }

    /// Route a Finder or Services action into the window controller.
    private func perform(_ action: FinderRequestAction, on urls: [URL]) {
        guard let controller = windowController, let first = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch action {
        case .open:
            controller.openDocument(at: first)
        case .extract:
            controller.extractFromFinder(urls)
        case .compress:
            controller.compressFromFinder(urls)
        }
    }

    /// A missing helper is a build problem, not a user error, so say exactly what to do.
    private func presentMissingEngine() {
        let alert = NSAlert()
        alert.messageText = "The 7-Zip helper is missing"
        alert.informativeText = """
            ArcSeven drives an unmodified upstream 7-Zip binary, which was not found \
            in this build.

            Build it with:
                ./vendor/build-7zz.sh

            It is produced from the pinned vendor/7zip submodule and installed into \
            vendor/bin/7zz, then copied into the app bundle at Contents/Helpers/7zz.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

// MARK: - Services

extension AppDelegate: ServicesProviderDelegate {
    func servicesProvider(
        _ provider: ServicesProvider,
        didRequest action: FinderRequestAction,
        for urls: [URL]
    ) {
        perform(action, on: urls)
    }
}
