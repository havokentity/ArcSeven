// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
//
// The settings model: every key name, every default, one observable store.
//
// KEY NAMES ARE NOT DECORATIVE. Ledger row 70 (docs/ARCHITECTURE.md) commits ArcSeven to
// `NSUserDefaults` keys that carry the same names and the same value semantics as 7zFM's
// registry values under `HKCU\Software\7-Zip\FM`, so the persistence model can be audited
// against the Windows original one line at a time. `ShowDots` stays `ShowDots`; it does not
// become `showParentDirectoryItem`. The `FM.` prefix stands in for the registry subkey, per
// docs/FIDELITY.md PST-01…PST-16.
//
// WHY NOT @AppStorage. `@AppStorage` installs a KVO observer on the key it is given, and
// `UserDefaults` KVO resolves a dotted key as a *key path*: observing `FM.ShowDots` asks for
// the `ShowDots` member of a (nonexistent) `FM` dictionary, so the observer never fires and
// a second window showing the same setting silently goes stale. Every key we are required
// to use is dotted. So the store is explicit: read once at init, write through in `didSet`,
// and let the `@Observable` macro do the change tracking that KVO cannot.

import Foundation
import Observation

// MARK: - Keys

/// Every defaults key the settings window owns.
///
/// Raw values are the persisted names and are API: other modules read them directly off the
/// standard defaults domain (`bool(forKey: "FM.ShowDots")`) rather than importing SettingsUI,
/// which is what keeps SettingsUI a leaf module that nothing else has to link against.
public enum SettingsKey: String, CaseIterable, Sendable {
    // Settings pane — 7zFM Options ▸ Settings (FIDELITY OPT-18…OPT-24, PST-10).
    // Every one of these is **off** by default on Windows, and that is preserved.
    case showDots = "FM.ShowDots"
    case showRealFileIcons = "FM.ShowRealFileIcons"
    case fullRow = "FM.FullRow"
    case showGrid = "FM.ShowGrid"
    case singleClick = "FM.SingleClick"
    case alternativeSelection = "FM.AlternativeSelection"
    case showSystemMenu = "FM.ShowSystemMenu"

    /// The unpack RAM ceiling (OPT-26, feeding the Memory-usage-request dialog, MEM-01).
    ///
    /// Upstream stores one string (`"4g"`, `"80%"`); we store an integer count of gigabytes
    /// plus a separate enable flag so unticking the box does not destroy the number the user
    /// typed. Semantics are otherwise identical: disabled means "no ArcSeven-imposed limit".
    case memUse = "MemUse"
    case memUseEnabled = "MemUseEnabled"

    // Editor pane (OPT-15, PST-11). Empty means "not set", which is a live behaviour, not a
    // placeholder: see OPT-16 and OPT-17.
    case viewer = "FM.Viewer"
    case editor = "FM.Editor"
    case diff = "FM.Diff"

    // Folders pane (OPT-14). `WorkDirType` is 0 system temp / 1 current folder / 2 specified,
    // in that order, matching the radio order upstream.
    case workDirType = "FM.WorkDirType"
    case workDirPath = "FM.WorkDirPath"
    case tempRemovableOnly = "FM.TempRemovableOnly"

    // Integration pane — 7zFM Options ▸ 7-Zip (OPT-08…OPT-13, PST-15, DIVERGENCES D-11).
    case finderIntegration = "Options.FinderIntegration"
    case cascadedMenu = "Options.CascadedMenu"
    case menuIcons = "Options.MenuIcons"
    case elimDup = "Options.ElimDup"
    /// Upstream `WriteZone`; the Zone.Identifier stream becomes `com.apple.quarantine` (D-08).
    case writeZone = "Options.WriteZone"
    /// Bitmask of enabled context-menu verbs, indexed by `ContextMenuVerb.allCases`.
    case contextMenu = "Options.ContextMenu"

    /// Selected UI language, or empty for "follow the system" (PST-13, D-26).
    case language = "Lang"

    /// Keymap preset: `finder` / `commander` / `custom` (PST-16, docs/SHORTCUTS.md §1.2).
    case shortcutsPreset = "Shortcuts.Preset"
    /// Which pane the settings window had open when it was last closed.
    ///
    /// Not a 7zFM key — its property sheet only remembers the page within a session — but a
    /// Mac settings window is expected to come back where it was left.
    case selectedPane = "Settings.SelectedPane"

    /// The `.custom` preset's delta table, owned and written by FMUI's `ShortcutMap`.
    ///
    /// docs/FIDELITY.md PST-16 names this key `Shortcuts.Custom`; docs/SHORTCUTS.md §1.2 calls
    /// it `Keymap`. The settings window only ever *clears* it, so it clears both names rather
    /// than pick a winner in someone else's file — see `SettingsStore.resetCustomBindings()`.
    case shortcutsCustom = "Shortcuts.Custom"
}

/// The alternate spelling of `.shortcutsCustom` (docs/SHORTCUTS.md §1.2). See that key's note.
let legacyKeymapKey = "Keymap"

// MARK: - Notifications

public extension Notification.Name {
    /// Any list-appearance setting changed.
    ///
    /// 7zFM applies the whole Options sheet on OK by calling `SetListSettings()` and then
    /// `RefreshAllPanels()` (OPT-02). macOS settings apply immediately, so the equivalent is
    /// this notification, posted per change; observers do the same two things.
    static let arcSevenListSettingsDidChange = Notification.Name("ArcSevenListSettingsDidChange")

    /// The keymap preset changed. Preset switching is live: docs/SHORTCUTS.md §8 requires key
    /// equivalents to be re-applied across the whole menu without a relaunch.
    static let arcSevenKeymapPresetDidChange = Notification.Name("ArcSevenKeymapPresetDidChange")

    /// The language override changed. OPT-29's refresh chain: rebuild menus, reload toolbars.
    /// Unlike the two above this one cannot fully apply in-process — see `LanguagePane`.
    static let arcSevenLanguageDidChange = Notification.Name("ArcSevenLanguageDidChange")

    /// A Finder-integration setting changed, so the extension's menu policy must be re-pushed.
    static let arcSevenIntegrationDidChange = Notification.Name("ArcSevenIntegrationDidChange")
}

// MARK: - Enumerated values

/// 7zFM's working-folder radio group (OPT-14). Raw values are the persisted integers.
public enum WorkDirType: Int, CaseIterable, Sendable {
    case systemTemp = 0
    case currentFolder = 1
    case specified = 2
}

/// `WriteZone` (OPT-11), retargeted from `Zone.Identifier` to `com.apple.quarantine` (D-08).
///
/// Upstream also accepts raw values ≥ 3 typed into the registry and shows them in the combo;
/// an unknown stored value therefore falls back to `.never` for display but is left on disk.
///
/// The cases are spelled `never` / `always` rather than `no` / `yes`; the raw values are the
/// upstream ones and are what persists, so this is a spelling of the API, not of the setting.
public enum QuarantinePropagation: Int, CaseIterable, Sendable {
    case never = 0
    case always = 1
    /// Upstream's `For Office files`; here, types conforming to `public.executable`,
    /// `public.script`, or the Office document UTIs.
    case documentsAndExecutables = 2
}

/// The context-menu verb checklist (OPT-13), in upstream's exact order, minus the three
/// `#ifdef EMAIL_SUPPORT` rows — those become the system Share item, listed last.
public enum ContextMenuVerb: Int, CaseIterable, Sendable, Identifiable {
    case openArchive
    case openArchiveSubmenu
    case extractFiles
    case extractHere
    case extractToFolder
    case testArchive
    case addToArchive
    case addTo7z
    case addToZip
    case checksum
    case appSubmenuChecksum
    case share

    public var id: Int { rawValue }

    /// Bit position in the `Options.ContextMenu` mask.
    ///
    /// Upstream's mask has fixed bit positions that include the email verbs; dropping three
    /// rows makes bit-for-bit parity impossible, so positions are list order here and the mask
    /// is ours. Nothing outside ArcSeven reads it.
    var bit: Int { 1 << rawValue }

    var title: String {
        switch self {
        case .openArchive: "Open archive"
        case .openArchiveSubmenu: "Open archive ▸"
        case .extractFiles: "Extract files…"
        case .extractHere: "Extract Here"
        case .extractToFolder: "Extract to “<Folder>”"
        case .testArchive: "Test archive"
        case .addToArchive: "Add to archive…"
        case .addTo7z: "Add to “<Archive>.7z”"
        case .addToZip: "Add to “<Archive>.zip”"
        case .checksum: "Checksum ▸"
        case .appSubmenuChecksum: "ArcSeven ▸ Checksum ▸"
        case .share: "Share ▸"
        }
    }
}

/// The keymap presets (docs/SHORTCUTS.md §1.2). Raw values are persisted.
public enum KeymapPreset: String, CaseIterable, Sendable, Identifiable {
    case finder
    case commander
    case custom

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .finder: "Finder"
        case .commander: "7-Zip Classic"
        case .custom: "Custom"
        }
    }
}

// MARK: - Store

/// The single read/write path for everything the settings window owns.
///
/// Main-actor isolated because every consumer is a view. Writes go straight to the standard
/// defaults domain in `didSet`, so a crash between two settings changes cannot lose the first
/// one, and so other modules can read the keys without knowing this type exists.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: Settings pane

    public var showDots: Bool { didSet { writeList(.showDots, showDots) } }
    public var showRealFileIcons: Bool { didSet { writeList(.showRealFileIcons, showRealFileIcons) } }
    public var fullRow: Bool { didSet { writeList(.fullRow, fullRow) } }
    public var showGrid: Bool { didSet { writeList(.showGrid, showGrid) } }
    public var singleClick: Bool { didSet { writeList(.singleClick, singleClick) } }
    public var alternativeSelection: Bool { didSet { writeList(.alternativeSelection, alternativeSelection) } }
    public var showSystemMenu: Bool { didSet { writeList(.showSystemMenu, showSystemMenu) } }

    public var memUseEnabled: Bool { didSet { write(.memUseEnabled, memUseEnabled) } }
    public var memUseGigabytes: Int { didSet { write(.memUse, memUseGigabytes) } }

    // MARK: Editor pane

    public var viewerPath: String { didSet { write(.viewer, viewerPath) } }
    public var editorPath: String { didSet { write(.editor, editorPath) } }
    public var diffPath: String { didSet { write(.diff, diffPath) } }

    // MARK: Folders pane

    public var workDirType: WorkDirType { didSet { write(.workDirType, workDirType.rawValue) } }
    public var workDirPath: String { didSet { write(.workDirPath, workDirPath) } }
    public var tempRemovableOnly: Bool { didSet { write(.tempRemovableOnly, tempRemovableOnly) } }

    // MARK: Integration pane

    public var finderIntegration: Bool { didSet { writeIntegration(.finderIntegration, finderIntegration) } }
    public var cascadedMenu: Bool { didSet { writeIntegration(.cascadedMenu, cascadedMenu) } }
    public var menuIcons: Bool { didSet { writeIntegration(.menuIcons, menuIcons) } }
    public var elimDup: Bool { didSet { write(.elimDup, elimDup) } }
    public var quarantinePropagation: QuarantinePropagation {
        didSet { write(.writeZone, quarantinePropagation.rawValue) }
    }
    public var contextMenuMask: Int { didSet { writeIntegration(.contextMenu, contextMenuMask) } }

    // MARK: Language pane

    public var language: String { didSet { writeLanguage() } }

    // MARK: Shortcuts pane

    public var keymapPreset: KeymapPreset {
        didSet {
            write(.shortcutsPreset, keymapPreset.rawValue)
            NotificationCenter.default.post(name: .arcSevenKeymapPresetDidChange, object: nil)
        }
    }

    // MARK: Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.registerDefaults(in: defaults)

        showDots = defaults.bool(forKey: SettingsKey.showDots.rawValue)
        showRealFileIcons = defaults.bool(forKey: SettingsKey.showRealFileIcons.rawValue)
        fullRow = defaults.bool(forKey: SettingsKey.fullRow.rawValue)
        showGrid = defaults.bool(forKey: SettingsKey.showGrid.rawValue)
        singleClick = defaults.bool(forKey: SettingsKey.singleClick.rawValue)
        alternativeSelection = defaults.bool(forKey: SettingsKey.alternativeSelection.rawValue)
        showSystemMenu = defaults.bool(forKey: SettingsKey.showSystemMenu.rawValue)

        memUseEnabled = defaults.bool(forKey: SettingsKey.memUseEnabled.rawValue)
        memUseGigabytes = defaults.integer(forKey: SettingsKey.memUse.rawValue)

        viewerPath = defaults.string(forKey: SettingsKey.viewer.rawValue) ?? ""
        editorPath = defaults.string(forKey: SettingsKey.editor.rawValue) ?? ""
        diffPath = defaults.string(forKey: SettingsKey.diff.rawValue) ?? ""

        workDirType = WorkDirType(rawValue: defaults.integer(forKey: SettingsKey.workDirType.rawValue)) ?? .systemTemp
        workDirPath = defaults.string(forKey: SettingsKey.workDirPath.rawValue) ?? ""
        tempRemovableOnly = defaults.bool(forKey: SettingsKey.tempRemovableOnly.rawValue)

        finderIntegration = defaults.bool(forKey: SettingsKey.finderIntegration.rawValue)
        cascadedMenu = defaults.bool(forKey: SettingsKey.cascadedMenu.rawValue)
        menuIcons = defaults.bool(forKey: SettingsKey.menuIcons.rawValue)
        elimDup = defaults.bool(forKey: SettingsKey.elimDup.rawValue)
        quarantinePropagation = QuarantinePropagation(
            rawValue: defaults.integer(forKey: SettingsKey.writeZone.rawValue)
        ) ?? .never
        contextMenuMask = defaults.integer(forKey: SettingsKey.contextMenu.rawValue)

        language = defaults.string(forKey: SettingsKey.language.rawValue) ?? ""
        keymapPreset = KeymapPreset(
            rawValue: defaults.string(forKey: SettingsKey.shortcutsPreset.rawValue) ?? ""
        ) ?? .finder
    }

    /// Seed the registration domain with every default that is not "zero".
    ///
    /// Called from `main.swift` before the delegate exists, and again from `init` above. Both
    /// are needed and neither is redundant: `init` runs the first time the settings window is
    /// opened, which is far too late for a module that reads `bool(forKey: "Options.MenuIcons")`
    /// at launch and would otherwise get `false` for a setting whose shipped value is `true`.
    /// Registering twice is harmless — the registration domain is replaced wholesale, not merged
    /// per call, and it never shadows a value the user has actually set.
    ///
    /// `nonisolated` because it touches nothing but the `UserDefaults` it is handed, which is
    /// itself thread-safe. The main-actor isolation it would otherwise inherit from the class is
    /// about the observable UI state below, and has no business reaching a launch-time seed that
    /// runs before there is any UI at all.
    ///
    /// The seven Settings-pane checkboxes are deliberately absent: they are all off upstream,
    /// and absent already reads as `false`.
    public nonisolated static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            SettingsKey.memUse.rawValue: 4,                 // OPT-26: the spin edit starts at 4 GB.
            SettingsKey.workDirType.rawValue: WorkDirType.systemTemp.rawValue,
            SettingsKey.finderIntegration.rawValue: true,
            SettingsKey.cascadedMenu.rawValue: true,        // OPT-10: both are ticked upstream.
            SettingsKey.menuIcons.rawValue: true,
            SettingsKey.contextMenu.rawValue: ContextMenuVerb.allCases.reduce(0) { $0 | $1.bit },
            SettingsKey.shortcutsPreset.rawValue: KeymapPreset.finder.rawValue,
        ])
    }

    // MARK: Derived accessors

    public func isVerbEnabled(_ verb: ContextMenuVerb) -> Bool {
        contextMenuMask & verb.bit != 0
    }

    public func setVerb(_ verb: ContextMenuVerb, enabled: Bool) {
        contextMenuMask = enabled ? contextMenuMask | verb.bit : contextMenuMask & ~verb.bit
    }

    /// How many bindings the `.custom` preset overrides, or 0 when it has never been edited.
    ///
    /// Read-only on purpose: the delta table belongs to FMUI's `ShortcutMap` and its shape is
    /// that module's business. All the settings window needs is a count and a way to clear it.
    public var customBindingCount: Int {
        for key in [SettingsKey.shortcutsCustom.rawValue, legacyKeymapKey] {
            if let dictionary = defaults.dictionary(forKey: key) { return dictionary.count }
        }
        return 0
    }

    /// Which pane the settings window should open on, or `nil` when it has never been closed.
    ///
    /// Window state rather than a setting, but it goes through the store like everything else:
    /// this file is the one place that touches the defaults domain, so the key cannot drift
    /// out of it. Not `@Observable`-tracked — the window reads it once, at construction.
    public var selectedPaneIndex: Int? {
        get { defaults.object(forKey: SettingsKey.selectedPane.rawValue) as? Int }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: SettingsKey.selectedPane.rawValue)
                return
            }
            defaults.set(newValue, forKey: SettingsKey.selectedPane.rawValue)
        }
    }

    /// Discard the `.custom` delta table, under both spellings the docs use for it.
    public func resetCustomBindings() {
        defaults.removeObject(forKey: SettingsKey.shortcutsCustom.rawValue)
        defaults.removeObject(forKey: legacyKeymapKey)
        NotificationCenter.default.post(name: .arcSevenKeymapPresetDidChange, object: nil)
    }

    // MARK: Writing

    private func write(_ key: SettingsKey, _ value: Any) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func writeList(_ key: SettingsKey, _ value: Any) {
        write(key, value)
        NotificationCenter.default.post(name: .arcSevenListSettingsDidChange, object: nil)
    }

    private func writeIntegration(_ key: SettingsKey, _ value: Any) {
        write(key, value)
        NotificationCenter.default.post(name: .arcSevenIntegrationDidChange, object: nil)
    }

    /// The language override is two writes, not one.
    ///
    /// `Lang` is ours and is what the ledger audits (PST-13). `AppleLanguages` in the app's own
    /// defaults domain is what `Bundle` actually consults when it picks a `.lproj` at launch —
    /// it is the same mechanism System Settings ▸ General ▸ Language & Region ▸ Applications
    /// writes. Removing it (rather than writing an empty array) is what restores "follow the
    /// system", because an empty array would pin the app to no language at all.
    private func writeLanguage() {
        write(.language, language)
        if language.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: .arcSevenLanguageDidChange, object: nil)
    }
}
