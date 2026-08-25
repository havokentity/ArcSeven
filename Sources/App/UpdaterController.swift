// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// Sparkle 2 auto-update, wrapped so that nothing else in the app ever imports Sparkle.
//
// Two things about this file are unusual and both are deliberate.
//
// 1. EVERYTHING IS BEHIND `#if canImport(Sparkle)`, with a no-op twin in the `#else`
//    branch. Sparkle is an optional SPM dependency of the Xcode project only; it is not
//    in Package.swift (see the "NO EXTERNAL DEPENDENCIES" note there), so `swift build`
//    never sees it, and CI builds unsigned without any guarantee that the package graph
//    has resolved. A missing optional dependency must not be able to break the build of
//    a file manager. The fallback compiles on its own, reports `canCheckForUpdates ==
//    false`, and therefore greys the menu item out through `validateMenuItem(_:)`.
//
// 2. AUTOMATIC CHECKING DEFAULTS TO OFF AND STAYS OFF UNTIL THE USER IS ASKED. A check
//    is an HTTPS request to a server we control carrying the app version and the OS
//    version; doing that on first launch, unasked, is phoning home. In a GPL tool whose
//    whole pitch is that you can read what it does, that is not acceptable. So the
//    updater is *started* at launch — starting is inert — but `automaticallyChecksFor-
//    Updates` is forced to false until `presentAutomaticUpdateConsentIfNeeded()` has put
//    the question to the user exactly once. "Check for Updates…" in the menu is always
//    available: that one is the user asking us, which is consent by definition.
//
// The delegate hooks that are implemented are commented with *why they exist here*, not
// with what Sparkle does with them; the API is documented upstream and repeating it
// would go stale. Every hook is `nonisolated` because `SPUUpdaterDelegate` is a plain
// Objective-C protocol with no actor annotation, and a `@MainActor` witness cannot
// satisfy a non-isolated requirement under Swift 6. A `nonisolated` witness satisfies
// the requirement whichever way Sparkle annotates the protocol in a future release.
//
// Operator's guide, including the exact project.yml and Info.plist additions:
// docs/SPARKLE-INTEGRATION.md.

import AppKit
import Foundation
import os

#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - Preferences

/// The updater's stored preferences.
///
/// Deliberately outside the `#if`: it names no Sparkle type, both branches of this file
/// use it, and a future Settings ▸ Updates pane can read it without caring whether the
/// dependency is present. Accessors are `nonisolated` because the delegate callbacks
/// that consult them are.
///
/// Key names take an `Updates.` prefix rather than one of the `FM.` / `Options.` names in
/// `SettingsKey`: those mirror 7-Zip's registry values one for one, and auto-update has
/// no counterpart upstream, so inventing an `FM.` key would corrupt that audit trail.
public enum UpdaterPreferences {
    /// Persisted names. Raw values are API — they survive upgrades.
    public enum Key: String, CaseIterable, Sendable {
        /// Our record of the answer. Seeded into Sparkle, then kept in step with it.
        case automaticChecks = "Updates.AutomaticallyChecks"
        /// Whether the consent question has been put to the user at all.
        case hasAskedForConsent = "Updates.HasAskedForConsent"
        /// Opt-in to the `beta` appcast channel; release.yml tags prereleases already.
        case includesPrereleases = "Updates.IncludesPrereleases"
        /// How many times the app has launched, used only to keep the consent prompt off
        /// the very first run.
        case launchCount = "Updates.LaunchCount"
    }

    /// The defaults domain these live in.
    ///
    /// A function rather than a stored static: a shared static of a non-`Sendable` type
    /// is precisely what Swift 6 strict concurrency exists to reject, and this is read
    /// from `nonisolated` context.
    private static func store() -> UserDefaults { .standard }

    /// Absent means false. That is the whole point — no key, no checking.
    public static var automaticallyChecks: Bool {
        get { store().bool(forKey: Key.automaticChecks.rawValue) }
        set { store().set(newValue, forKey: Key.automaticChecks.rawValue) }
    }

    public static var hasAskedForConsent: Bool {
        get { store().bool(forKey: Key.hasAskedForConsent.rawValue) }
        set { store().set(newValue, forKey: Key.hasAskedForConsent.rawValue) }
    }

    public static var includesPrereleases: Bool {
        get { store().bool(forKey: Key.includesPrereleases.rawValue) }
        set { store().set(newValue, forKey: Key.includesPrereleases.rawValue) }
    }

    public static var launchCount: Int {
        get { store().integer(forKey: Key.launchCount.rawValue) }
        set { store().set(newValue, forKey: Key.launchCount.rawValue) }
    }
}

/// Shared by both branches so Console filtering works the same either way.
private let updaterLog = Logger(subsystem: "com.havokentity.ArcSeven", category: "updater")

#if canImport(Sparkle)

// MARK: - Sparkle present

@MainActor
public final class UpdaterController: NSObject {
    /// The one updater.
    ///
    /// Sparkle keeps process-wide state — a scheduler, a downloader, an installer
    /// hand-off — so a second `SPUStandardUpdaterController` means two schedulers racing
    /// for the same appcast and, worse, two installers for one bundle.
    public static let shared = UpdaterController()

    /// Posted immediately before the app is replaced and relaunched by Sparkle.
    ///
    /// Deliberately a notification rather than a delegate of our own: whoever ends up
    /// owning "cancel the running job" should not have to be reachable from here.
    /// `nonisolated` because the delegate callback that posts it is.
    nonisolated public static let willRelaunchNotification =
        Notification.Name("ArcSevenUpdaterWillRelaunch")

    /// Nil until `start()`. Created lazily rather than in `init` so that `self` can be
    /// handed over as the delegate: `SPUUpdater.delegate` is read-only after
    /// construction, so there is no second chance to set it.
    private var controller: SPUStandardUpdaterController?

    override private init() { super.init() }

    // MARK: Lifecycle

    /// Create the updater, apply the consent policy, and start it. Idempotent.
    ///
    /// Starting is not checking. With `automaticallyChecksForUpdates` false, a started
    /// updater schedules nothing and opens no connection; it only makes the menu item
    /// live. Call this from `applicationDidFinishLaunching`.
    public func start() {
        UpdaterPreferences.launchCount += 1

        guard controller == nil else { return }

        let created = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        applyConsentPolicy(to: created.updater)
        // Started only after the policy is applied: `startUpdater()` is what schedules
        // the first check, and it must never see a stale `true`.
        created.startUpdater()
        controller = created
    }

    /// Force checking off until the user has been asked; afterwards, follow the user.
    ///
    /// After consent has been given or refused once, Sparkle's own stored answer is
    /// authoritative, because the user can flip "Automatically check for updates" inside
    /// Sparkle's update window and we must not silently undo that on the next launch.
    /// Our key is then mirrored *from* Sparkle so the two never disagree.
    private func applyConsentPolicy(to updater: SPUUpdater) {
        guard UpdaterPreferences.hasAskedForConsent else {
            updater.automaticallyChecksForUpdates = false
            // Downloading a 30 MB disk image unasked is worse than checking unasked.
            updater.automaticallyDownloadsUpdates = false
            UpdaterPreferences.automaticallyChecks = false
            return
        }
        UpdaterPreferences.automaticallyChecks = updater.automaticallyChecksForUpdates
    }

    // MARK: Menu

    /// Menu action for "Check for Updates…". Explicit, user-initiated, always allowed.
    @objc
    public func checkForUpdates(_ sender: Any?) {
        // `start()` first so the item works even if the app delegate never called it —
        // a disabled-forever update command is the kind of bug nobody reports.
        start()
        controller?.checkForUpdates(sender)
    }

    /// Whether "Check for Updates…" should be enabled.
    ///
    /// False while a check or an install is already in flight, which is why it is read
    /// per validation pass rather than cached.
    public var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    /// The user's answer, for a Settings ▸ Updates toggle. Writes through to Sparkle so
    /// the change takes effect without a relaunch.
    public var automaticallyChecksForUpdates: Bool {
        get { UpdaterPreferences.automaticallyChecks }
        set {
            UpdaterPreferences.automaticallyChecks = newValue
            UpdaterPreferences.hasAskedForConsent = true
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    // MARK: Consent

    /// Ask, once, whether ArcSeven may check for updates on its own.
    ///
    /// Skipped on the first launch: the first thing a new user sees should be their
    /// files, not a dialog about network policy. From the second launch on, the question
    /// is asked exactly once and the answer is remembered either way.
    public func presentAutomaticUpdateConsentIfNeeded() {
        guard !UpdaterPreferences.hasAskedForConsent else { return }
        guard UpdaterPreferences.launchCount > 1 else { return }

        let alert = NSAlert()
        alert.messageText = "Check for updates automatically?"
        alert.informativeText = """
            ArcSeven can check https://github.com/havokentity/ArcSeven for new versions \
            once a day and tell you when one is available.

            A check sends only the app version, the macOS version and the CPU \
            architecture, and it never runs unless you allow it here. You can change \
            this at any time, and you can always check by hand from the ArcSeven menu.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Check Automatically")
        alert.addButton(withTitle: "Don't Check")

        let allowed = alert.runModal() == .alertFirstButtonReturn
        automaticallyChecksForUpdates = allowed
        updaterLog.notice("Automatic update checks \(allowed ? "enabled" : "declined", privacy: .public)")
    }
}

// MARK: - Menu validation

extension UpdaterController: NSMenuItemValidation {
    /// AppKit revalidates on every menu open, so this is the whole enable/disable story
    /// for the item — the menu builder sets `target` and nothing else.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return canCheckForUpdates
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterController: SPUUpdaterDelegate {
    /// No system profile, ever.
    ///
    /// Sparkle can append CPU count, RAM, model identifier and more to the feed request
    /// as query parameters. Returning an empty list keeps a check down to "which version
    /// am I, which macOS am I", which is the minimum needed to answer the question. It
    /// also means the feed URL never carries anything that could identify a machine.
    nonisolated public func feedParameters(
        for updater: SPUUpdater,
        sendingSystemProfile sendingProfile: Bool
    ) -> [[String: String]] {
        []
    }

    /// Keep prereleases out of the stable channel.
    ///
    /// `release.yml` publishes any tag with a semver prerelease identifier as a GitHub
    /// prerelease, and `Scripts/appcast.sh` puts those entries in the `beta` channel.
    /// An empty set means "unchannelled entries only", which is what a stable user wants.
    nonisolated public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdaterPreferences.includesPrereleases ? ["beta"] : []
    }

    /// Never let Sparkle put up its own "check automatically?" dialog.
    ///
    /// Belt and braces: `SUEnableAutomaticChecks` in Info.plist already suppresses it.
    /// But that key can be overridden by a stale value in the defaults domain, and the
    /// one outcome we will not tolerate is a network-permission prompt appearing before
    /// the app has drawn a window. Consent is asked for in
    /// `presentAutomaticUpdateConsentIfNeeded()`, on our schedule and in our words.
    nonisolated public func updaterShouldPromptForPermissionToCheckForUpdates(
        _ updater: SPUUpdater
    ) -> Bool {
        false
    }

    /// A broken feed is otherwise completely silent.
    ///
    /// Bad signature, moved appcast, expired certificate: Sparkle's default is to fail
    /// quietly on a scheduled check so the user is not nagged. That is right for the
    /// user and useless for us, so the reason goes to Console where a bug report can
    /// quote it.
    nonisolated public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        updaterLog.error("Update cycle aborted: \(error.localizedDescription, privacy: .public)")
    }

    /// Same reasoning, one layer down: a download that fails mid-flight.
    nonisolated public func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: any Error
    ) {
        updaterLog.error("""
            Download of \(item.displayVersionString, privacy: .public) failed: \
            \(error.localizedDescription, privacy: .public)
            """)
    }

    /// The last point at which this process is still ours.
    ///
    /// ArcSeven declares `NSSupportsSuddenTermination: false` because a running compress
    /// or extract must never be killed silently, and an update relaunch is exactly that
    /// kill. Posting the notification gives the window controller a place to hang
    /// cancellation off later; today it is a breadcrumb in Console, which is honest
    /// about what is and is not wired up.
    nonisolated public func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        updaterLog.notice("Relaunching to install an update")
        NotificationCenter.default.post(name: Self.willRelaunchNotification, object: nil)
    }
}

#else

// MARK: - Sparkle absent

/// The no-op twin.
///
/// Same public surface, no behaviour. This is what `swift build`, a bare checkout and an
/// unsigned CI build compile. `canCheckForUpdates` is false, so the menu item validates
/// to disabled and the user is never offered a command that cannot work.
@MainActor
public final class UpdaterController: NSObject {
    public static let shared = UpdaterController()

    /// Posted immediately before an update relaunch. Never posted in this build; declared
    /// so that observers compile either way.
    nonisolated public static let willRelaunchNotification =
        Notification.Name("ArcSevenUpdaterWillRelaunch")

    override private init() { super.init() }

    /// Nothing to start. Kept so the app delegate's call site is identical either way.
    public func start() {
        updaterLog.debug("Built without Sparkle; auto-update is disabled")
    }

    /// Never true here, which is the contract the menu item validates against.
    public var canCheckForUpdates: Bool { false }

    /// Stored, but inert: a Settings toggle can still round-trip the preference so the
    /// answer survives a rebuild that does include Sparkle.
    public var automaticallyChecksForUpdates: Bool {
        get { UpdaterPreferences.automaticallyChecks }
        set { UpdaterPreferences.automaticallyChecks = newValue }
    }

    @objc
    public func checkForUpdates(_ sender: Any?) {
        updaterLog.notice("Check for Updates requested, but this build has no updater")
    }

    /// No update mechanism, so nothing to consent to. Asking anyway would be a dialog
    /// about a feature that does not exist.
    public func presentAutomaticUpdateConsentIfNeeded() {}
}

extension UpdaterController: NSMenuItemValidation {
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return canCheckForUpdates
    }
}

#endif
