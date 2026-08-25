// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The Folders History MRU.
//
// This is the list behind three separate pieces of 7zFM UI that all read the same
// store: the path-bar combo's dropdown, the `Folders History...` dialog (MV-14,
// `Alt+F12` upstream / `⌥⌘Y` here), and the Back/Forward walk. On Windows it lives in
// the `FM\FolderHistory` registry value; here it is the `FM.FolderHistory` default,
// keeping the upstream name so the persistence model stays auditable against the
// original (FIDELITY.md PST-06).
//
// Two behaviours are worth stating because they are easy to get subtly wrong:
//
//   * Re-visiting a folder does not append a second row — it MOVES the existing row
//     to the top. A history that grows a duplicate for every visit is useless after
//     ten minutes of browsing, and 7zFM's dropdown never shows one.
//   * The list is bounded. Upstream caps its MRU lists at a small constant
//     (`kHistorySize` = 16 or 20 depending on the dialog); the folder history gets
//     the same treatment here, defaulting to 32 and injectable for tests.
//
// Entries are plain display paths, not URLs, because an entry may name the interior
// of an archive — `/Users/me/src.7z/docs` — which has no file URL. That is exactly
// what `FolderProvider.displayPath` produces, and it is what the path bar shows.

import Foundation

/// The most-recently-visited folder paths, newest first.
///
/// ## Concurrency
///
/// `@unchecked Sendable` with an explicit `NSLock` rather than an actor. `UserDefaults`
/// is already thread-safe for individual reads and writes, so an actor would buy
/// nothing there — but `record(_:)` is a read-modify-write (load, de-duplicate,
/// prepend, truncate, store) and two concurrent calls interleaving inside that
/// sequence would lose an entry. The lock makes the composite operation atomic. It is
/// `@unchecked` because the compiler cannot see that the lock guards the mutation;
/// the class itself holds no mutable state beyond the immutable configuration.
///
/// Making it an actor instead would force `await` on every call site, including the
/// synchronous `NSComboBox` data-source path that has to answer *now*.
public final class FolderHistoryStore: @unchecked Sendable {
    /// The `UserDefaults` key. Mirrors the Windows value name `FM\FolderHistory`.
    public static let defaultsKey = "FM.FolderHistory"

    /// How many paths the list keeps.
    ///
    /// Upstream's MRU constants are 16 (Extract destination) and 20 (Add archive
    /// path). 32 is a deliberate, documented step up: the folder history is browsed
    /// far more often than either dialog's combo, and a Mac's `defaults` domain has
    /// none of the registry's size anxiety.
    public static let defaultLimit = 32

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = FolderHistoryStore.defaultsKey,
        limit: Int = FolderHistoryStore.defaultLimit
    ) {
        self.defaults = defaults
        self.key = key
        // A zero or negative cap would mean "history disabled", which no UI offers;
        // clamp so a bad injection cannot silently swallow every entry.
        self.limit = max(1, limit)
    }

    // MARK: Reading

    /// The stored paths, most recent first.
    ///
    /// - Parameter limit: how many to return; `nil` means the whole list.
    public func recent(limit: Int? = nil) -> [String] {
        let stored = lock.withLock { loadLocked() }
        guard let limit else { return stored }
        guard limit > 0 else { return [] }
        return Array(stored.prefix(limit))
    }

    /// `true` when the history holds a path equal to this one under the
    /// same folding rules `record(_:)` uses.
    public func contains(_ path: String) -> Bool {
        let identity = Self.identity(of: path)
        guard !identity.isEmpty else { return false }
        return lock.withLock { loadLocked() }.contains { Self.identity(of: $0) == identity }
    }

    // MARK: Writing

    /// Push a folder to the top of the history.
    ///
    /// Re-visiting an existing folder moves it up rather than duplicating it, and the
    /// spelling you just navigated with replaces the one stored earlier — on a
    /// case-insensitive, case-preserving volume (APFS's default) `/Users/Me/Docs` and
    /// `/users/me/docs` are the same folder, and the dropdown should show the casing
    /// the user last saw in the path bar.
    public func record(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = Self.identity(of: trimmed)
        // An empty path is what a failed navigation or a not-yet-loaded panel hands
        // us; it is not a place anyone can go back to.
        guard !identity.isEmpty else { return }

        lock.withLock {
            var list = loadLocked()
            list.removeAll { Self.identity(of: $0) == identity }
            list.insert(trimmed, at: 0)
            if list.count > limit { list.removeLast(list.count - limit) }
            defaults.set(list, forKey: key)
        }
    }

    /// Forget every entry — the `Folders History...` dialog's Clear button.
    ///
    /// Removes the key outright instead of storing an empty array so the domain goes
    /// back to its pristine shape and `defaults read` shows nothing at all.
    public func clear() {
        lock.withLock { defaults.removeObject(forKey: key) }
    }

    // MARK: Internals

    /// Read the raw list, discarding anything that is not a string.
    ///
    /// The array can be edited by hand with `defaults write`, and a stray number in
    /// it must not take out the path bar, so this filters rather than trusts.
    private func loadLocked() -> [String] {
        guard let raw = defaults.array(forKey: key) else { return [] }
        return raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// The comparison key two paths are de-duplicated on.
    ///
    /// Three normalisations, each for a concrete reason on macOS:
    ///
    ///   * **Unicode composition.** HFS+ hands back decomposed names (NFD) while text
    ///     typed into the path bar is composed (NFC). Without `precomposed…`, a folder
    ///     called `Café` reached by typing and by clicking would occupy two rows.
    ///   * **Case.** APFS and HFS+ are case-insensitive by default, as NTFS is, so
    ///     `Downloads` and `downloads` are one folder. This uses the invariant
    ///     lowercasing, not the locale's — a Turkish locale must not decide that `I`
    ///     and `i` name different directories.
    ///   * **Trailing separator.** `FolderProvider.displayPath` never emits one, but a
    ///     path pasted into the path bar often carries one, and `/tmp/` is `/tmp`.
    ///     A lone `/` is the root and keeps its slash.
    static func identity(of path: String) -> String {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value.precomposedStringWithCanonicalMapping.lowercased()
    }
}
