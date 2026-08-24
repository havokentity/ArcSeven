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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        MainMenuBuilder.install()

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
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let windowController else {
            pendingURLs.append(url)
            return
        }
        windowController.openDocument(at: url)
        NSApp.activate(ignoringOtherApps: true)
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
