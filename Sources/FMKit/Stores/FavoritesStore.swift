// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The ten numbered favourites ("Folder Shortcuts").
//
// 7zFM's Favorites menu is not an open-ended bookmark list. It is exactly **ten
// numbered slots**, and that number is load-bearing rather than incidental: the menu
// is torn down and rebuilt on every open with ten `Bookmark 0`…`Bookmark 9` items in
// the `Add folder to Favorites as` submenu (command ids 810–819) and ten more below
// it for jumping (ids 830–839), each carrying the accelerator text for its digit.
// A slot that has never been set still occupies its row and renders as `-`.
// (FIDELITY.md MA-01…MA-04; upstream `MyLoadMenu.cpp` plus `resource.rc`
// `IDM_FAVORITES`.)
//
// The digits are what the user actually remembers, so the model has to be an array
// with holes, not a set or a dictionary of paths. Slot 3 stays slot 3 after slot 1 is
// cleared; that is the whole point of a numbered favourite.
//
// Key bindings, for context — the store itself is binding-agnostic:
//
//   | Action | Windows 7zFM | ArcSeven          |
//   |--------|--------------|-------------------|
//   | Jump   | `Alt+1…0`    | `⌃⌥1` … `⌃⌥0`     |
//   | Set    | `Alt+Shift+…`| `⇧⌃⌥1` … `⇧⌃⌥0`   |
//
// Note the off-by-one everyone trips on: the tenth slot is reached with the `0` key,
// so the keyboard digit `1` is slot index 0 and the digit `0` is slot index 9. This
// store is addressed by INDEX, 0–9. Mapping a keystroke to an index belongs in the
// menu layer, and `slot(forKeyboardDigit:)` below exists so it is written once.
//
// Storage is the `FM.FolderShortcuts` default, mirroring the Windows multi-string
// value `FM\FolderShortcuts` (FIDELITY.md PST-07 / MA-04).

import Foundation

/// The ten numbered favourite folders.
///
/// ## Concurrency
///
/// `@unchecked Sendable` guarded by an `NSLock`, for the same reason as
/// `FolderHistoryStore`: `UserDefaults` is individually thread-safe, but writing one
/// slot means reading all ten, replacing one, and writing all ten back, and that
/// sequence has to be atomic or a concurrent write to a different slot is lost. An
/// actor would push `await` into the menu-building path, which is synchronous.
public final class FavoritesStore: @unchecked Sendable {
    /// Exactly ten, always. Not a default, not a preference — the menu, the key
    /// bindings and the stored array are all built around this number.
    public static let slotCount = 10

    /// The `UserDefaults` key. Mirrors the Windows value name `FM\FolderShortcuts`.
    public static let defaultsKey = "FM.FolderShortcuts"

    /// What the Favorites menu shows for a slot that has never been set.
    public static let emptySlotPlaceholder = "-"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        key: String = FavoritesStore.defaultsKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    // MARK: Slot addressing

    /// The valid slot indices, `0..<10`.
    public static var slotIndices: Range<Int> { 0..<slotCount }

    /// `true` when `slot` addresses one of the ten.
    public static func isValidSlot(_ slot: Int) -> Bool { slotIndices.contains(slot) }

    /// Map a keyboard digit to a slot index: `1`→0 … `9`→8, `0`→9.
    ///
    /// The tenth favourite is bound to the `0` key because there is no `10` key, so
    /// the digit and the index differ for every slot. Returns `nil` for anything that
    /// is not a single digit.
    public static func slot(forKeyboardDigit digit: Int) -> Int? {
        switch digit {
        case 0: slotCount - 1
        case 1...9: digit - 1
        default: nil
        }
    }

    // MARK: Reading

    /// The path in a slot, or `nil` when the slot is empty or out of range.
    ///
    /// Out-of-range reads answer `nil` rather than trapping: a stale menu item or a
    /// replayed keystroke must not be able to crash the app.
    public func path(at slot: Int) -> String? {
        guard Self.isValidSlot(slot) else { return nil }
        return lock.withLock { loadLocked() }[slot]
    }

    /// All ten slots in order, `nil` for the empty ones.
    ///
    /// Always exactly ``slotCount`` elements, so the menu builder can zip it against
    /// the ten menu items without a bounds check.
    public func all() -> [String?] {
        lock.withLock { loadLocked() }
    }

    /// `true` when no slot holds a path — the state the Favorites menu shows as ten
    /// rows of `-`.
    public var isEmpty: Bool {
        all().allSatisfy { $0 == nil }
    }

    // MARK: Writing

    /// Set or clear one slot.
    ///
    /// Passing `nil` (or a path that is empty once trimmed) clears the slot, which is
    /// the only way to empty one: 7zFM has no `Remove favourite` command, you bookmark
    /// nothing over the top of it.
    ///
    /// - Returns: `false` when `slot` is out of range and nothing was written. The
    ///   result is discardable because the common caller — a menu item wired to a
    ///   known-good index — has nothing useful to do with it.
    @discardableResult
    public func set(_ path: String?, at slot: Int) -> Bool {
        guard Self.isValidSlot(slot) else { return false }
        let value = path?.trimmingCharacters(in: .whitespacesAndNewlines)

        lock.withLock {
            var slots = loadLocked()
            slots[slot] = (value?.isEmpty ?? true) ? nil : value
            storeLocked(slots)
        }
        return true
    }

    /// Empty every slot.
    ///
    /// Removes the key rather than writing ten empty strings, so an untouched domain
    /// stays untouched-looking.
    public func clear() {
        lock.withLock { defaults.removeObject(forKey: key) }
    }

    // MARK: Internals

    /// Read all ten slots, normalising whatever is actually in the domain.
    ///
    /// The stored array is padded, truncated and type-filtered on the way in because
    /// it is user-editable via `defaults write` and because an older build (or a
    /// hand-migrated Windows registry export) may hold a shorter list. The result is
    /// always ``slotCount`` long.
    private func loadLocked() -> [String?] {
        var slots = [String?](repeating: nil, count: Self.slotCount)
        guard let raw = defaults.array(forKey: key) else { return slots }
        for (index, element) in raw.prefix(Self.slotCount).enumerated() {
            // An empty string is how the Windows multi-string spells "unset", and it
            // is what `storeLocked` writes, so it must decode back to `nil`.
            guard let path = element as? String, !path.isEmpty else { continue }
            slots[index] = path
        }
        return slots
    }

    /// Write all ten slots.
    ///
    /// Always writes the full ten-element array — holes included, as empty strings —
    /// rather than a compacted list, because the index IS the identity of a favourite.
    /// A compacted array would renumber every bookmark below a cleared one, and the
    /// user's `⌃⌥5` would silently start opening a different folder.
    private func storeLocked(_ slots: [String?]) {
        defaults.set(slots.map { $0 ?? "" }, forKey: key)
    }
}
