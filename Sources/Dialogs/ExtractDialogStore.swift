// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// What the Extract dialog remembers between runs.
//
// 7zFM keeps this under `HKCU\Software\7-Zip\FM\Extract` and re-reads it every time the
// dialog opens (EXT-02, EXT-07, EXT-08, PST-05). Here it is a handful of `UserDefaults`
// keys, reached through this type rather than inline in the controller for the reason
// every store in the project exists: the key strings are the persistence contract, and a
// contract spread across a view controller drifts. `Sources/FMKit/Stores/` holds the same
// shape for the panel's own state — an injected domain, typed accessors, nothing else.
//
// One of these keys is not ours. `Options.ElimDup` belongs to Settings ▸ 7-Zip and is
// read here on purpose (EXT-08): the checkbox in this dialog and the one in the settings
// window are the same setting, and SettingsUI documents its key names as API precisely so
// leaf modules can read them without linking it.

import Foundation
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif

/// The Extract dialog's persisted state.
///
/// A value type over an injected `UserDefaults`: there is no cached state to keep
/// coherent, so every accessor reads or writes the domain directly, and a test can hand
/// in a scratch suite instead of the standard one.
struct ExtractDialogStore {
    /// `kHistorySize` in `ExtractDialog.cpp` — the cap on the destination MRU.
    static let historyLimit = 16

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Destination history

    /// The destination MRU, most recent first, already capped at ``historyLimit``.
    var destinationHistory: [String] {
        let stored = (defaults.array(forKey: Key.history) as? [String]) ?? []
        return Array(stored.prefix(Self.historyLimit))
    }

    /// Move `path` to the top of the MRU, de-duplicated and capped.
    func recordDestination(_ path: String) {
        var history = (defaults.array(forKey: Key.history) as? [String]) ?? []
        history.removeAll { $0 == path }
        history.insert(path, at: 0)
        defaults.set(Array(history.prefix(Self.historyLimit)), forKey: Key.history)
    }

    // MARK: Modes

    /// The last path mode, or `nil` when none is stored or the stored one is unreadable.
    var pathMode: ExtractPathMode? {
        defaults.string(forKey: Key.pathMode).flatMap(ExtractPathMode.init(rawValue:))
    }

    func setPathMode(_ mode: ExtractPathMode) {
        defaults.set(mode.rawValue, forKey: Key.pathMode)
    }

    /// The last overwrite mode, or `nil` when none is stored or it is unreadable.
    var overwriteMode: OverwriteMode? {
        defaults.string(forKey: Key.overwriteMode).flatMap(OverwriteMode.init(rawValue:))
    }

    func setOverwriteMode(_ mode: OverwriteMode) {
        defaults.set(mode.rawValue, forKey: Key.overwriteMode)
    }

    // MARK: Checkboxes

    /// EXT-08: Settings ▸ 7-Zip's setting, not this dialog's. Deliberately a plain
    /// `bool(forKey:)` with no local fallback — the registration domain belongs to
    /// SettingsUI, so if the shipped default ever changes there, this follows without a
    /// second edit.
    var eliminatesRootDuplication: Bool {
        defaults.bool(forKey: Key.eliminateRoot)
    }

    func setEliminatesRootDuplication(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.eliminateRoot)
    }

    /// Defaults to `true`: an absent key means the user has never had an opinion, and
    /// restoring the permission bits an archive carries is the behaviour that loses
    /// nothing.
    var restoresPOSIXPermissions: Bool {
        guard defaults.object(forKey: Key.restorePermissions) != nil else { return true }
        return defaults.bool(forKey: Key.restorePermissions)
    }

    func setRestoresPOSIXPermissions(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.restorePermissions)
    }

    /// Shared with the Password dialog (PWD-02), which persists the same toggle.
    var showsPassword: Bool {
        defaults.bool(forKey: Key.showPassword)
    }

    func setShowsPassword(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.showPassword)
    }

    // MARK: Keys

    /// The persisted names, mirroring the Windows value names under `FM\Extract`.
    private enum Key {
        static let history = "FM.Extract.PathHistory"
        static let pathMode = "FM.Extract.PathMode"
        static let overwriteMode = "FM.Extract.OverwriteMode"
        /// Same string as `SettingsKey.elimDup`, which SettingsUI documents as API
        /// precisely so leaf modules do not have to link it.
        static let eliminateRoot = "Options.ElimDup"
        static let restorePermissions = "FM.Extract.RestorePOSIXPermissions"
        static let showPassword = "FM.ShowPassword"
    }
}
