// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The one place a runtime setting is read from.
//
// `.swiftlint.yml` has forbidden `UserDefaults.standard` outside this file since the project
// started — and this file did not exist, so the rule pointed at nothing and the first module
// that needed a setting reached past it. The rule was right; the file was simply never
// written.
//
// # Why a single map matters here
//
// The key names are 7-Zip's, deliberately: `SettingsUI` mirrors `HKCU\Software\7-Zip\FM`
// name for name so the fidelity ledger can be audited one row at a time. That makes the
// names easy to mistype and impossible to typo-check — `FM.ShowDots` and a hypothetical
// `FM.ShowHidden` differ by more than spelling but not by much. Naming each key once, here,
// is what keeps the writer in `SettingsUI` and the reader in `FMKit` talking about the same
// thing.
//
// # Reading live, not snapshotting
//
// Every accessor reads through on each call. A snapshot would need every holder to be
// rebuilt when a setting changed, and `panel.reload()` alone would then show the stale
// answer — the bug this shape exists to avoid.

import Foundation

/// Runtime reads of user settings, by name, in one place.
public enum Defaults {
    /// The store everything reads from.
    ///
    /// A computed property rather than a `static let`: `UserDefaults` is not `Sendable`, so
    /// a stored global trips Swift 6's concurrency checking. `.standard` is itself a
    /// thread-safe singleton, so reaching for it per call costs nothing.
    public static var store: UserDefaults { .standard }

    // MARK: Keys

    /// Show items the file system marks hidden — dotfiles and anything carrying `UF_HIDDEN`.
    ///
    /// Distinct from 7-Zip's `FM.ShowDots`, which is its `Show ".." item` toggle for the
    /// parent row. The two are one character apart in intent and completely different in
    /// effect; routing hidden-file filtering through `ShowDots` would silently break the
    /// parent row instead.
    public static let showHiddenFilesKey = "FM.ShowHiddenFiles"

    // MARK: Reads

    /// Absent means `false`: a fresh install hides hidden files, matching Finder.
    public static func showsHiddenFiles(in store: UserDefaults? = nil) -> Bool {
        (store ?? Self.store).bool(forKey: showHiddenFilesKey)
    }
}
