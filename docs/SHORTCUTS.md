<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# ArcSeven — Keymap Specification

> **Status:** normative. This document is the single authority for every keyboard binding in ArcSeven.
> Where it disagrees with [ARCHITECTURE.md](ARCHITECTURE.md)'s keyboard sketch, this document wins;
> the two genuine collisions in that sketch are called out and resolved in [§3.10](#310-collisions-inherited-from-architecturemd).
>
> **Provenance.** Every "Windows 7zFM key" column entry is transcribed from the upstream 7-Zip sources
> (`github.com/ip7z/7zip`, branch `main`) — chiefly `CPP/7zip/UI/FileManager/PanelKey.cpp`
> (`CPanel::OnKeyDown`), `Panel.cpp` (`CMyListView::OnMessage`), and the `IDR_ACCELERATOR1` /
> `IDM_MENU MENUEX` blocks of `resource.rc`. No 7-Zip code is reproduced here; behaviour is described
> and reimplemented clean-room. Items that could not be confirmed from source are marked
> **[UNVERIFIED]** and collected in [§6](#6-unresolved-items--must-be-verified-against-a-running-7zfm).

**Trademark note.** ArcSeven is not affiliated with or endorsed by 7-Zip or Igor Pavlov. References to
7-Zip and 7zFM below are nominative and descriptive.

---

## Table of contents

1. [The keymap is a data structure](#1-the-keymap-is-a-data-structure)
2. [The master table](#2-the-master-table)
3. [Conflicts and how each is resolved](#3-conflicts-and-how-each-is-resolved)
4. [The Finder preset, justified](#4-the-finder-preset-justified)
5. [The Commander preset](#5-the-commander-preset-7-zip-classic)
6. [Unresolved items](#6-unresolved-items--must-be-verified-against-a-running-7zfm)
7. [Accessibility](#7-accessibility)
8. [Implementation notes](#8-implementation-notes-appkit-mechanics)
9. [Reserved chord register](#9-reserved-chord-register)

### Notation

| Symbol | Key | Symbol | Key |
|---|---|---|---|
| `⌘` | Command | `⏎` | Return |
| `⌥` | Option / Alt | `⌫` | Delete (backspace) |
| `⌃` | Control | `⌦` | Forward Delete (`fn`+`⌫` on laptops) |
| `⇧` | Shift | `⇥` | Tab |
| `fn` | Function | `␣` | Space |
| `⎋` | Escape | `≣` | PC context-menu key (keyCode 110) |

A chord written `⌥⌘←` means Option-Command-Left Arrow. Numeric-keypad keys are written `＋`, `−`, `＊`
to distinguish them from the main-row `=`, `-`, `8` keys.

---

## 1. The keymap is a data structure

### 1.1 Why this is decided on day one, not retrofitted

7zFM's keyboard map is a `switch` statement. `CPanel::OnKeyDown` in `PanelKey.cpp` is a single
`switch (keyDownInfo->wVKey)` with `bool alt/ctrl/shift` locals read from `IsKeyDown()`, and a second,
overlapping map lives in `CMyListView::OnMessage` for the keys that only surface as `WM_CHAR`
(`\`, `/`, and the numpad keys, which are explicitly swallowed there so they never reach the list
control's incremental search). There is no table, no indirection, and therefore no possibility of a
user-editable keymap without rewriting the handler.

Only **two** real accelerators exist in the shipped binary — the whole of `IDR_ACCELERATOR1` is
`F1 → IDM_HELP_CONTENTS` and `Alt+F12 → IDM_FOLDERS_HISTORY`. Everything else fires from `LVN_KEYDOWN`,
which means **every other shortcut in 7-Zip only works while the file list has focus**. Put the caret
in the path combo and `Ctrl+A`, `F5`, `Delete` all stop working. The accelerator text painted into the
menus (`\tF5`, `\tCtrl+N`, …) is decorative — the menu is not what dispatches those keys. A source
comment explains why `F7` and `Ctrl+N` accelerators were commented out: menu loading can be slow on
UNC paths, so the accelerator was removed rather than the menu made fast.

ArcSeven does not reproduce that. **Every command is menu-backed and works app-wide** (this is
[ARCHITECTURE.md](ARCHITECTURE.md) fidelity-ledger row 71: *dropped — this is a bug on Windows, not a
feature*), with a small, explicitly enumerated set of list-scoped aliases. Making that work, and
making three presets work, requires the binding table to be data from the first commit.

### 1.2 The model

```swift
// Sources/ArcSeven/Keymap/KeymapModel.swift

/// A stable, namespaced command identifier. Dotted strings rather than an enum with 200 cases:
/// they survive reordering, they double as `NSUserInterfaceItemIdentifier` on the menu item,
/// they are the JSON key for the `.custom` preset, and they are the App Intents verb id in M6.
public struct Command: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(_ raw: String) { rawValue = raw }
    public init?(rawValue: String) { self.rawValue = rawValue }

    public static let open              = Command("file.open")
    public static let openInside        = Command("file.openInside")
    public static let copyTo            = Command("file.copyTo")
    public static let moveTo            = Command("file.moveTo")
    // …
    public static func openFavorite(_ n: Int) -> Command { Command("favorites.open.\(n)") }
    public static func setFavorite(_ n: Int)  -> Command { Command("favorites.set.\(n)") }
}

/// Our own modifier set. Deliberately NOT `NSEvent.ModifierFlags`: that type is not `Codable`,
/// its raw value is an unstable device-dependent bitfield, and it carries `.numericPad` /
/// `.capsLock` bits we must mask off before comparing.
public struct Modifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift    = Modifiers(rawValue: 1 << 0)
    public static let control  = Modifiers(rawValue: 1 << 1)
    public static let option   = Modifiers(rawValue: 1 << 2)
    public static let command  = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)   // fn; only meaningful for F-keys
}

public enum KeyToken: Hashable, Codable, Sendable {
    case character(Character)      // layout-independent: matched on `charactersIgnoringModifiers`
    case function(Int)             // F1 … F20
    case special(Special)          // .return, .delete, .forwardDelete, .tab, .space, .escape,
                                   // .up, .down, .left, .right, .pageUp, .pageDown,
                                   // .home, .end, .insert, .contextMenu
    case keypad(Keypad)            // .plus, .minus, .multiply, .divide, .digit(Int)
}

public struct KeyChord: Hashable, Codable, Sendable {
    public var key: KeyToken
    public var modifiers: Modifiers
}

/// Where a chord is allowed to fire.
public enum Scope: String, Codable, Sendable {
    /// A real `NSMenuItem.keyEquivalent`. Fires anywhere in the app, including text fields.
    /// Exactly one binding per command may be `.application` and `isPrimary`.
    case application
    /// Dispatched from `FileListTableView.keyDown(with:)`. Never fires while a text field,
    /// the path bar, a sheet, or the rename editor is first responder. This is the only scope
    /// in which bare `⌃`+letter and bare `⌥`+key chords may be used (see §3.4, §3.5).
    case fileList
}

public struct Binding: Hashable, Codable, Sendable {
    public var chord: KeyChord
    public var scope: Scope
    /// The one binding whose chord is painted into the menu item.
    public var isPrimary: Bool
}

public enum PresetID: String, Codable, Sendable, CaseIterable {
    case finder, commander, custom
}

public struct Keymap: Codable, Sendable {
    public var id: PresetID
    public var name: String
    public var bindings: [Command: [Binding]]

    public func primaryChord(for command: Command) -> KeyChord?
    public func command(matching chord: KeyChord, in scope: Scope) -> Command?
    public func conflicts() -> [(KeyChord, [Command])]
}
```

Three tables, one engine:

```swift
public enum Presets {
    public static let finder:    Keymap   // §4 — the default
    public static let commander: Keymap   // §5 — Presets.finder.overlaid(with: classicChords)
    public static func custom(_ overrides: [Command: [Binding]]) -> Keymap
}
```

`.commander` is defined as **additive**: it is `.finder` with the Windows chords overlaid on top.
Only two chords collide between the two tables (`⏎` and `␣`); the overlay resolves both in favour of
the Windows meaning. This means a user who switches to Classic does not lose `⌘C`, `⌘I`, `⌘⌫` or any
other Mac chord — they gain `F5`/`F6`/`F7`, `Insert`, the numpad keys and the `⌃`+letter family
on top. That is what "muscle memory preset" has to mean for someone who moves between a PC at work
and a Mac at home.

`.custom` starts as a copy of whichever preset is active when the user first edits a binding, and
stores **only the deltas** as JSON under the `NSUserDefaults` key `Keymap` (matching the flat-key
persistence convention of ledger row 70). Deltas, not a full snapshot, so a user who customised two
chords in v1.0 still inherits every new command added in v1.1.

### 1.3 Dispatch precedence

Highest wins. A chord that loses at a higher tier is never seen at a lower one.

| # | Tier | Owner | Notes |
|---|---|---|---|
| 1 | macOS system & Accessibility shortcuts | the OS | `⌘␣`, `⌃↑`, `⇧⌘3/4/5`, `⌘⇥`, `⌥⌘=`/`⌥⌘−`/`⌥⌘8` (Zoom), `⌘F5` (VoiceOver), `⌃F1`–`⌃F8` (keyboard navigation). **The validator refuses to bind any of these**, in any preset, including `.custom`. |
| 2 | System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts | the user | macOS lets a user re-key any menu item by its exact title. We cannot read these overrides, so menu item **titles are stable API** — never reword a menu item without a migration note. |
| 3 | `NSMenuItem.keyEquivalent` (`.application` scope) | `MenuController` | Applied from `Keymap.primaryChord(for:)` at menu build time and re-applied on preset change. |
| 4 | `.fileList` scope | `FileListTableView.keyDown(with:)` | Consulted only when the table is first responder **and** the type-select buffer is empty (see [§7.6](#76-type-select-vs-bare-delete)). |
| 5 | `NSTableView` built-ins | AppKit | Arrow keys, `⇧`+arrows, `⌘`+arrows for extend-to-end, type-select, `⌥`+arrows word-wise in the rename editor. |
| 6 | Responder chain | AppKit | Standard key bindings (`⌃A`/`⌃E`/`⌃K`/`⌃D`… inside text fields — see [§3.4](#34-cmd-is-the-primary-modifier-not-ctrl)). |

Everything at tiers 3 and 4 funnels into the same `@objc` action and the same
`validateUserInterfaceItem(_:)` gate, so a command that is disabled in the menu is also inert from its
alias chord. There is exactly one enable/disable rule per command, not two.

---

## 2. The master table

One row per command. `—` means "not bound"; a command with `—` in a preset column is still reachable
from a menu or a context menu. Commander-preset cells list the Windows chord **plus** the inherited
Finder chord, in that order.

### 2.1 File — opening

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Open | `Enter`, double-click | `⌘↓`, `⌘O`, double-click | `⏎`, `⌘↓`, `⌘O`, double-click | Folders navigate in place; a single file is tried as an archive first, then handed to LaunchServices. The hard cap of 20 simultaneously-opened items and the `Too many items` message are preserved. |
| Open Outside | `Shift+Enter` | `⌥⌘↓` | `⇧⏎`, `⌥⌘↓` | Always hands to LaunchServices, never opens internally. 7zFM's `Shift` becomes `⌥` so that `⇧⌘↓` stays free — see [§4.2](#42-open-vs-rename-the-return-key). |
| Open Inside | `Ctrl+PgDn` | `⌃⌘↓` | `⌃PgDn`, `⌃⌘↓` | Force archive browsing even for a file LaunchServices would claim. `⌃` is carried over from `Ctrl+PgDn`. |
| Open Inside `*` | — | — | — | Menu only, exactly as in 7zFM. Forces the "any single matching handler" strategy. |
| Open Inside `#` | — | — | — | Menu only. Parser / recovery-mode handler. |
| Quick Look (= 7zFM "View") | `F3` | `␣`, `⌘Y` | `F3`, `␣`, `⌘Y` | 7zFM's F3 opens the *configured viewer application*. ArcSeven collapses this into Quick Look by default, with a Settings option to route it to an external viewer instead. `␣` is `.fileList` scope; `⌘Y` is the menu equivalent. |
| Edit in External Editor | `F4` | `⌘E` | `F4`, `⌘E` | For files inside an archive this is the temp-file / write-back flow (`7zO` prefix). See [§4.3](#43-the-e-family). |
| Reveal in Finder | — | `⇧⌘R` | `⇧⌘R` | ArcSeven addition. Disabled inside archives. |

### 2.2 File — modifying

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Rename | `F2` | `⏎` | `F2` | In `.finder`, `⏎` renames (Finder convention) and `F2` is unbound. In `.commander`, `⏎` opens and `F2` renames. The single most consequential divergence — [§3.2](#32-return-means-rename-in-finder-and-open-in-7zfm). |
| Duplicate | `Shift+F5` | `⌘D` | `⇧F5`, `⌘D` | 7zFM `OnCopy(move: false, copyToSame: true)` — the dialog is pre-filled with the focused item's **bare name**, not a path. That is exactly Finder's Duplicate. |
| Rename / Move within folder | `Shift+F6` | `⏎` | `⇧F6` | `OnCopy(move: true, copyToSame: true)`. In `.finder` this folds into Rename: the rename sheet accepts a relative or absolute path, which is what the 7zFM dialog does. |
| Copy To… (Copy to Other Pane) | `F5` | `⌥⌘←`, `⌥⌘→` | `F5`, `⌥⌘←`, `⌥⌘→` | One command, two arrows. There are only ever two panes (`kNumPanelsMax = 2`), so the destination is never ambiguous; both arrows are bound so the user can press whichever points away from the focused pane. With one pane visible the destination defaults to the pane's own folder, reduced to a real filesystem path. |
| Move To… (Move to Other Pane) | `F6` | `⇧⌥⌘←`, `⇧⌥⌘→` | `F6`, `⇧⌥⌘←`, `⇧⌥⌘→` | Same shape. Pre-flight `CheckBeforeUpdate` read-only walk of the whole parent chain is preserved. |
| Copy | `Ctrl+C`, `Ctrl+Insert` | `⌘C` | `⌃C`, `⌃Ins`, `⌘C` | File promises out of an archive; one decompression pass for the whole promise set. |
| Cut | `Ctrl+X` | `⌘X` | `⌃X`, `⌘X` | |
| Paste | `Ctrl+V` | `⌘V` | `⌃V`, `⌘V` | |
| Move Item Here | — | `⌥⌘V` | `⌥⌘V` | Finder's paste-as-move. ArcSeven addition; 7zFM has no equivalent. |
| Copy as Pathname | — | `⌥⌘C` | `⌥⌘C` | Finder convention. Inside an archive, yields the virtual path (`…/outer.7z/inner/file`). |
| Move to Trash | `Del` | `⌘⌫` | `F8` **[UNVERIFIED]**, `⌦`, `⌘⌫` | `Delete(toRecycleBin: !shift)`. **Inside an archive there is no Trash** — the entry is removed permanently and the confirmation copy differs. |
| Delete Immediately | `Shift+Del` | `⌥⌘⌫` | `⇧⌦`, `⌥⌘⌫` | Finder's own "Delete Immediately" chord, same three confirmation title/message pairs as 7zFM. |
| Create Folder | `F7` | `⇧⌘N` | `F7`, `⇧⌘N` | Default name `New Folder`, same error titles. |
| Create File | `Ctrl+N`, `Shift+F4` | `⌃⌘N` | `⌃N`, `⇧F4`, `⌃⌘N` | `⌘N` is New Window on macOS; see [§3.4](#34-cmd-is-the-primary-modifier-not-ctrl). |
| New Window | — | `⌘N` | `⌘N` | ArcSeven addition (7zFM is single-window). |
| Properties | `Alt+Enter` | `⌘I` | `⌥⏎`, `⌘I` | Non-modal live inspector that follows the selection. Same assembly order, same `----------` separators, `⌘C` copies `Name: Value` lines. |
| Comment… | `Ctrl+Z` | `⌥⌘K` | `⌃Z`, `⌥⌘K` | `Ctrl+Z` is **Comment** in 7zFM, not Undo. `⌘Z` must remain Undo on macOS — [§3.4](#34-cmd-is-the-primary-modifier-not-ctrl). |
| Split file… | — | — | — | Menu only, as in 7zFM. Enabled only for exactly one filesystem file. |
| Combine files… | — | — | — | Menu only. |
| Link… | — | — | — | Menu only. `⌃⌘A` is deliberately left unbound because that is Finder's Make Alias. |
| Alternate streams | — | — | — | Menu only. On macOS this opens the extended-attribute pseudo-folder. |
| Diff | — | — | — | Menu only, and removed from the menu entirely when no diff tool is configured — exactly 7zFM's `CFileMenu::Load` rule. |
| CRC ▸ (11 methods + generate + test) | — | — | — | Menu only, exact 7zFM order: CRC-32, CRC-64, XXH64, MD5, SHA-1, SHA-256, SHA-384, SHA-512, SHA3-256, BLAKE2sp, `*`, separator, `SHA-256 -> <name>.sha256`, `Test archive : Checksum`. |

### 2.3 Archive commands

7zFM exposes these only on the Archive toolbar and in the injected shell context menu — there is no
keyboard path to Add / Extract / Test at all. ArcSeven adds one, since this is an archive manager.

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Add to Archive… | toolbar / shell menu | `⌥⌘N` | `⌥⌘N` | Completes the "new *X*" family: `⌘N` window · `⇧⌘N` folder · `⌃⌘N` file · `⌥⌘N` archive. |
| Extract… | toolbar / shell menu | `⌥⌘E` | `⌥⌘E` | |
| Extract Here | shell menu | `⇧⌥⌘E` | `⇧⌥⌘E` | |
| Extract to `<name>/` | shell menu | `⌃⌥⌘E` | `⌃⌥⌘E` | |
| Test Archive | toolbar / shell menu | `⌃⌘T` | `⌃⌘T` | `⌥⌘T` is reserved for Show/Hide Toolbar, `⇧⌘T` for the future tab bar. |
| Benchmark | — | — | — | Menu only, as in 7zFM. |
| Delete Temporary Files… | — | — | — | Menu only. Scans the `7zO*` staging directories. |

### 2.4 Edit — selection

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Select All | `Ctrl+A`, `Shift+＋` | `⌘A` | `⌃A`, `⇧＋`, `⌘A` | The `..` row is excluded, as in 7zFM. |
| Deselect All | `Shift+−` | `⇧⌘A` | `⇧−`, `⇧⌘A` | Finder's own Deselect All chord. |
| Invert Selection | `＊` | `⌥⌘A` | `＊`, `⌥⌘A` | |
| Select… (wildcard mask) | `＋` | `⌥⌘S` | `＋`, `⌥⌘S` | 7-Zip wildcard semantics (`DoesWildcardMatchName`), not regex. Default mask `*`. |
| Deselect… (wildcard mask) | `−` | `⇧⌥⌘S` | `−`, `⇧⌥⌘S` | |
| Select by Type | `Alt+＋` | `⌃⌥⌘S` | `⌥＋`, `⌃⌥⌘S` | Selects everything sharing the focused item's extension. Four-key chord accepted: rare command, menu-backed, and `⌘F` is the discoverable path. |
| Deselect by Type | `Alt+−` | `⇧⌃⌥⌘S` | `⌥−`, `⇧⌃⌥⌘S` | |
| Toggle mark and advance | `Insert` | `␣` | `Ins`, `␣` | **Alternative selection mode only.** When that mode is on, `␣` is remapped from Quick Look to this, and Quick Look remains on `⌘Y`. See [§3.8](#38-space-quick-look-vs-type-select-vs-norton-marks). |
| Extend marks | `Shift+↑/↓/←/→` | `⇧↑`, `⇧↓` | `⇧↑`, `⇧↓` | Alternative selection mode only. Mark polarity is decided by the first item touched, then applied across the swept range — 7zFM's `_selectMark` behaviour. |
| Live Filter | — | `⌘F` | `⌘F` | ArcSeven addition with a This-Folder / Entire-Archive scope toggle. Subsumes mask selection and gives Flat View a discoverable form. |

### 2.5 View

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Large Icons | `Ctrl+1` | `⌘1` | `⌃1`, `⌘1` | `NSCollectionView`. |
| Small Icons | `Ctrl+2` | `⌘2` | `⌃2`, `⌘2` | `NSCollectionView`. |
| List | `Ctrl+3` | `⌘3` | `⌃3`, `⌘3` | `NSTableView`. |
| Details | `Ctrl+4` | `⌘4` | `⌃4`, `⌘4` | Default, as in the shipped resource (`MFS_CHECKED` on `IDM_VIEW_DETAILS`). |
| Sort by Name | `Ctrl+F3` | `⌃⌘3` | `⌃F3`, `⌃⌘3` | The digit is carried straight over from the F-key number, and `⌃⌘`+digit is also Finder's own sort family. |
| Sort by Type | `Ctrl+F4` | `⌃⌘4` | `⌃F4`, `⌃⌘4` | |
| Sort by Date | `Ctrl+F5` | `⌃⌘5` | `⌃F5`, `⌃⌘5` | |
| Sort by Size | `Ctrl+F6` | `⌃⌘6` | `⌃F6`, `⌃⌘6` | |
| Unsorted | `Ctrl+F7` | `⌃⌘7` | `⌃F7`, `⌃⌘7` | Raw enumeration order, still with `..` first and folders-first applied. |
| *(no command)* | `Ctrl+F8`…`Ctrl+F12` | — | — | These reach 7zFM's sort lookup, find no PROPID pair, and silently do nothing. ArcSeven leaves `⌃⌘8`–`⌃⌘0` unbound to match. **[UNVERIFIED]** — see [§6.4](#64-ctrlf8ctrlf12-are-silently-inert). |
| Reverse sort order | click the sorted header | click the sorted header | click the sorted header | Folders always sort before files and `..` always sorts first, in **both** directions — neither is inverted by descending order. |
| Size Columns to Fit | `Ctrl+＋` **[UNVERIFIED]** | — | — | Menu only, plus double-clicking a header divider (the Mac idiom). In 7zFM this is Win32 ListView built-in behaviour, not 7-Zip code — [§6.3](#63-ctrlkeypad--column-auto-size). |
| Flat View | — | `⌥⌘F` | `⌥⌘F` | ArcSeven addition; 7zFM has the command but no shortcut. Separate state for disk and archive. |
| Two Panes | `F9` | `⌥⌘2` | `F9`, `⌥⌘2` | Default is **one** pane (`kNumDefaultPanels = 1`), same as 7zFM. Collapsing keeps the last-focused pane. |
| Show/Hide Toolbar | — | `⌥⌘T` | `⌥⌘T` | Standard AppKit. The 7zFM `View ▸ Toolbars` submenu (Archive / Standard / Large Buttons / Show Buttons Text) remains as menu items with no chords. |
| Refresh | `Ctrl+R` | `⌘R` | `⌃R`, `⌘R` | |
| Auto Refresh | — | — | — | Checkbox, no chord — as in 7zFM. FSEvents rather than a polling timer. |
| Timestamp precision ▸ | — | — | — | The dynamic `2017`-placeholder submenu, relabelled at open time with today's date. Five radio levels plus a `UTC` toggle. |
| Show `..` item | Settings checkbox | — | — | Default **off**, matching 7zFM. |

### 2.6 Navigation

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Up One Level | `Backspace`, `Ctrl+PgUp` | `⌘↑`, `⌫` | `⌫`, `⌃PgUp`, `⌘↑` | `⌘↑` is the Finder idiom and is what the menu shows; bare `⌫` is a `.fileList` alias and only fires when the type-select buffer is empty ([§7.6](#76-type-select-vs-bare-delete)). Popping out of a modified archive still prompts. |
| Back | — | `⌘[` | `⌘[` | ArcSeven addition; 7zFM has only the Folders History dialog. |
| Forward | — | `⌘]` | `⌘]` | ArcSeven addition. |
| Computer (volumes list) | `\`, `/`, keypad `/` | `⇧⌘C` | `\`, `⇧⌘C` | 7zFM has **two different roots**: `View ▸ Open Root Folder` (Computer / Documents / Network) and the `\` key (`OpenDrivesFolder`, the drive-letter list). ArcSeven has one Computer root listing volumes plus Home / Documents / network shares. |
| Go to Folder… | — | `⇧⌘G`, `/`, `~` | `⇧⌘G`, `/`, `~` | Typing `/` or `~` in the list opens the sheet with that character pre-typed — exactly Finder. This is where 7zFM's `/` key lands. |
| Home | — | `⇧⌘H` | `⇧⌘H` | Finder Go menu. |
| Documents | — | `⇧⌘O` | `⇧⌘O` | Finder Go menu. |
| Desktop | — | `⇧⌘D` | `⇧⌘D` | Finder Go menu. |
| Downloads | — | `⌥⌘L` | `⌥⌘L` | Finder Go menu. |
| Focus Path Bar | `Alt+F1` (left), `Alt+F2` (right) | `⌘L` | `⌥F1`, `⌥F2`, `⌘L` | One chord replaces two: the path bar belongs to the focused pane, and `⇥` already chooses the pane. `⌘L` is the universal macOS "focus the location field". This also removes an [ARCHITECTURE.md collision](#310-collisions-inherited-from-architecturemd). Focusing also drops the hierarchy popup open, as `SetFocusToPath` does. |
| Folders History… | `Alt+F12` | `⌥⌘Y` | `⌥F12`, `⌥⌘Y` | One of only two real accelerators in 7zFM. |
| Eject | — | `⌃⌘E` | `⌃⌘E` | ArcSeven addition (volumes appear in the Computer root). |

### 2.7 Panes

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Other Pane | `Tab` | `⇥` | `⇥` | `.fileList` scope only — never a menu key equivalent, because a menu item with `⇥` as its equivalent would swallow Tab in every text field and break Full Keyboard Access. See [§3.7](#37-tab-vs-full-keyboard-access) and [§7.2](#72-full-keyboard-access). With one pane visible, this is a no-op that only refreshes the title (7zFM does the same). |
| Same Folder in Other Pane | `Alt+Up` | `⌃⌘↑` | `⌥↑`, `⌃⌘↑` | Binds the *other* pane to *this* pane's folder. No-op with one pane. |
| Focused Subfolder in Other Pane | `Alt+Left`, `Alt+Right` | `⌃⌘←`, `⌃⌘→` | `⌥←`, `⌥→`, `⌃⌘←`, `⌃⌘→` | Takes the focused item; does nothing unless it is a folder. If it is `..`, binds the other pane to *this* pane's parent. The published 7-Zip manual's wording ("open current folder in other panel") is imprecise. |
| Swap Panes | — | — | — | ArcSeven addition, menu only. |

### 2.8 Favourites

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Open favourite 0–9 | `Alt+0…9`, `RightCtrl+0…9` | `⌃⌥0`…`⌃⌥9` | `⌥0`…`⌥9`, `⌃⌥0`…`⌃⌥9` | 7zFM's condition is `(rightCtrl \|\| alt)` — **right** Control only, tested with `IsKeyDown(VK_RCONTROL)`. AppKit cannot distinguish left from right Control in a key equivalent, so ArcSeven does not reproduce the right-Ctrl variant; see [§3.9](#39-right-control-only-bookmarks). |
| Set favourite 0–9 | `Alt+Shift+0…9` | `⇧⌃⌥0`…`⇧⌃⌥9` | `⌥⇧0`…`⌥⇧9`, `⇧⌃⌥0`…`⇧⌃⌥9` | Ten slots. Empty slots render as `-`; paths over 100 characters are elided at the midpoint with ` ... `, keeping the first 50 and last 50 characters — reproduced exactly. |

### 2.9 Application

| Command | Windows 7zFM key | Finder preset | Commander preset | Notes |
|---|---|---|---|---|
| Settings | `Tools ▸ Options` | `⌘,` | `⌘,` | |
| Help | `F1` (accelerator) | `⌘?` | `F1`, `⌘?` | macOS puts app help on `⌘?` (= `⇧⌘/`) as the Help menu's first item. |
| About ArcSeven | `Help ▸ About` | — | — | Moves to the app menu. |
| Close Window | — | `⌘W` | `⌘W` | |
| Quit | `Alt+F4`, **`Ctrl+W`** | `⌘Q` | `⌥F4`, `⌘Q` | 7zFM's `Ctrl+W` posts `IDCLOSE` and quits the whole application. `⌃W` is **deliberately not bound** in either preset — [§3.4](#34-cmd-is-the-primary-modifier-not-ctrl). |
| Activate menu bar | `F10` | `⌃F2` (system) | `⌃F2` (system) | Provided by macOS Full Keyboard Access, not by us. |
| Contextual menu | `Shift+F10`, `≣` | `⌃⏎`, `≣` | `⇧F10`, `⌃⏎`, `≣` | Keyboard invocation arrives with no coordinates; the menu is centred on the focused row's icon rect, or at the pane's top-left when nothing is operated — 7zFM's `LVIR_ICON` behaviour. |
| Operation Queue | — | `⌥⌘0` | `⌥⌘0` | ArcSeven addition. |
| Cancel / dismiss | `Esc` | `⎋`, `⌘.` | `⎋`, `⌘.` | Cancels rename, clears the filter, dismisses a sheet, cancels a running operation (with confirmation). |
| *(no command)* | **`Ctrl+D`** | — | — | **`Ctrl+D` is not a 7zFM binding.** It appears in no `switch` case in `PanelKey.cpp`, in no accelerator, and in no menu; it is not in the official manual's shortcut table either. Third-party cheat sheets that list it are wrong. On macOS `⌘D` is Duplicate ([§2.2](#22-file--modifying)) and `⌃⌘D` is the system Look Up gesture, which is why neither is used for anything else here. |
| *(no command)* | **`F12`** (bare) | — | — | Only `Alt+F12` is bound. Bare `F12` does nothing in 7zFM. |
| *(no command)* | **`F8`** | — | `F8` → Move to Trash **[UNVERIFIED]** | See [§6.2](#62-f8). |

---

## 3. Conflicts and how each is resolved

### 3.1 F1–F12 are fn-key hostages

**The conflict.** On every Mac laptop and on every Magic Keyboard, the top row is by default *not*
F1–F12. It is brightness, Mission Control, Spotlight or Launchpad, dictation, keyboard backlight,
media transport, and volume. Getting a literal `F5` requires either holding `fn` or flipping a
**global, system-wide, all-applications** switch: System Settings ▸ Keyboard ▸ Keyboard Shortcuts… ▸
Function Keys ▸ *"Use F1, F2, etc. keys as standard function keys"*. There is no per-application
version of that switch, and there is no API to set it. Worse, several F-keys stay claimed even after
the flip, because they are also modifier-combination system shortcuts: `⌘F5` toggles VoiceOver,
`⌥⌘F5` opens the Accessibility Shortcuts panel, `⌃F1`–`⌃F8` are the Full Keyboard Access focus
commands, and `F11` may still be Show Desktop depending on Mission Control settings.

Meanwhile, F-keys are the *entire* interaction model of a Norton-style file manager. F5 and F6 are not
conveniences; on Windows they are how copying works.

**The resolution.**

- **The `.finder` preset binds no function keys at all.** Not F1 for Help, not F2 for rename, not
  F5 for copy. A default user never presses a key that requires `fn`, and a default user never has to
  change a system-wide setting to use this app.
- **The `.commander` preset binds all of them**, because that is the entire point of the preset, and
  because a user who deliberately chose "7-Zip Classic" has declared themselves a function-key user.
- Selecting `.commander` presents a **one-time onboarding sheet** that (a) explains the `fn` toggle in
  plain language, (b) reports whether it currently appears to be on, and (c) offers a button that
  opens the exact settings pane via
  `x-apple.systempreferences:com.apple.Keyboard-Settings.extension`. It does **not** claim it can
  change the setting, because it cannot.
- Even in `.commander`, every F-key command *also* keeps its Finder-preset chord. `F5` is an
  addition to `⌥⌘←`, never a replacement. A Classic user whose `fn` toggle is off still has a
  fully working app.
- `F5` and `F6` in particular are additionally exposed on the toolbar (Copy / Move buttons, matching
  7zFM's Standard toolbar) so there is a zero-keyboard path.

### 3.2 `Return` means RENAME in Finder and OPEN in 7zFM

**The conflict.** This is the sharpest one, because both meanings are deeply trained and neither is
wrong. In Finder, `⏎` on a selected file starts an inline rename; `⌘↓` opens. In 7zFM (and in
Explorer, and in every Windows file manager), `Enter` opens and `F2` renames. A Windows user pressing
`⏎` in ArcSeven to open a folder would instead put the folder's name into an editable text field. A Mac
user pressing `⏎` to rename would instead descend into the folder, or launch the file.

There is no binding that satisfies both. It must be a preset decision, and it is the *defining*
difference between the two presets.

**The resolution.**

| | `⏎` | Open | Rename |
|---|---|---|---|
| `.finder` (default) | Rename | `⌘↓`, `⌘O`, double-click | `⏎` |
| `.commander` | Open | `⏎`, `⌘↓`, `⌘O`, double-click | `F2` |

Reasoning for the default: ArcSeven's fidelity contract is about *behaviour* — what a command does, what
it names its dialogs, what order it sorts in — not about *which key* triggers it. A Mac user who
opens ArcSeven for the first time and hits `⏎` expecting rename and getting a launched application has
been failed by the app. A Windows user who hits `⏎` expecting open and gets a rename field has been
mildly surprised, presses `⎋`, and finds the Classic preset in Settings within thirty seconds. The
asymmetry of harm favours Finder.

Two safety details:

- Rename is entered *inline in the table*, never as a modal sheet, and `⎋` reverts. An accidental
  rename is one `⎋` or one `⌘Z` away from undone.
- In `.commander`, the rename menu item shows `F2`, so the discoverability of rename does not
  depend on the user knowing the Windows convention.

### 3.3 `Delete` is backspace-like on macOS

**The conflict.** Three separate mismatches ride on this one key.

1. The key labelled `delete` on a Mac keyboard is `⌫` — a **backspace**. The Windows `Delete` key is
   `⌦` (Forward Delete), which on a Mac laptop only exists as `fn`+`⌫`.
2. On macOS, pressing `⌫` alone in a file list does *nothing*. Deleting requires `⌘⌫`. This is a
   deliberate platform safety property: no single unmodified keypress destroys a file.
3. 7zFM binds bare `Backspace` to **Open Parent Folder**, not to delete.

**The resolution.** These three facts happen to compose perfectly.

| Meaning | 7zFM | ArcSeven |
|---|---|---|
| Up one level | `Backspace` | `⌫` (`.fileList` alias) + `⌘↑` (menu) |
| Move to Trash | `Del` | `⌘⌫` |
| Delete permanently | `Shift+Del` | `⌥⌘⌫` |

Bare `⌫` is safe to bind to "Up One Level" precisely *because* macOS never lets a bare `⌫` delete
anything — there is no destructive command for it to be confused with. So the 7zFM muscle memory is
preserved at zero risk, in **both** presets. `⌘⌫` and `⌥⌘⌫` are Finder's own Move-to-Trash and
Delete-Immediately chords, so the Mac muscle memory is preserved too.

Two consequences that must be implemented, not just documented:

- **Inside an archive there is no Trash.** `⌘⌫` on an archive entry rewrites the archive and the entry
  is gone. The confirmation sheet therefore uses distinct wording ("Delete *n* items from
  *archive.7z*? This cannot be undone.") and the destructive button is not the default.
- Bare `⌫` must not fire while the type-select buffer is non-empty — see [§7.6](#76-type-select-vs-bare-delete).

### 3.4 `⌘` is the primary modifier, not `Ctrl`

**The conflict.** Mechanically translating every `Ctrl+X` into `⌘X` works for most of 7zFM's table and
breaks catastrophically for four entries, because macOS has already spent those chords:

| 7zFM | Naive port | Why it fails | Actual ArcSeven binding |
|---|---|---|---|
| `Ctrl+Z` = **Comment** | `⌘Z` | `⌘Z` is Undo. Universally. A file manager that performs destructive operations *must* have a working Undo. | Comment → `⌥⌘K`; `⌘Z` stays Undo |
| `Ctrl+W` = **Quit the application** | `⌘W` | `⌘W` is Close Window. A user closing a window and having the whole app exit mid-extraction is a data-loss bug. | `⌘W` closes the window; `⌘Q` quits. **`⌃W` is bound to nothing** in either preset — reproducing "Ctrl+W quits" even in Classic would be indefensible. |
| `Ctrl+N` = **Create File** | `⌘N` | `⌘N` is New Window and ArcSeven is multi-window. | Create File → `⌃⌘N`; `⌘N` opens a window |
| `Ctrl+R` = Refresh | `⌘R` | No conflict — Finder's `⌘R` is Show Original, which we do not have. | `⌘R` = Refresh (kept); `⇧⌘R` = Reveal in Finder |

There is also a conflict in the *other* direction that is easy to miss. On macOS the `⌃` modifier is
not free: it carries the standard Emacs-derived text bindings that work in every text field —
`⌃A` start of line, `⌃E` end of line, `⌃K` kill to end, `⌃D` forward delete, `⌃F`/`⌃B` character
motion, `⌃N`/`⌃P` line motion, `⌃T` transpose. `NSTableView` honours `⌃N`/`⌃P` for row movement too.
Binding a bare `⌃`+letter chord at application scope would shadow all of that inside the path bar and
the rename editor.

**The resolution.**

- **`.finder` never binds a bare `⌃`+key chord.** `⌃` appears only as part of `⌃⌘` (a second tier
  beneath `⌘`) or `⌃⌥⌘` (a rarely-used third tier). This is why sorting is `⌃⌘3`–`⌃⌘7` and not
  `⌃3`–`⌃7`.
- **`.commander` does bind bare `⌃`+letter** — `⌃C`, `⌃X`, `⌃V`, `⌃A`, `⌃N`, `⌃R`, `⌃Z` — but every
  one of them is `.fileList` scope. They fire only while the file table is first responder, never in
  a text field, never in a sheet. They also shadow `⌃N`/`⌃P` row motion inside the table; that is a
  deliberate, disclosed cost of the preset, listed in the onboarding sheet.
- This scoping is, pleasingly, exactly how 7zFM behaves anyway: its shortcuts are `LVN_KEYDOWN`
  handlers and stop working the moment the path combo has focus. What is a bug on Windows is the
  only workable design on macOS.

### 3.5 `⌥` types characters, so `⌥`-chords are dangerous

**The conflict.** On macOS, `⌥` is a text-composition modifier, not a command modifier. `⌥e`, `⌥u`,
`⌥i`, `⌥n`, `⌥\`` are **dead keys** — they arm a diacritic and swallow the next keystroke. `⌥c`
produces `ç`, `⌥5` produces `∞`, `⌥␣` produces a non-breaking space. Which characters appear depends
on the active input source, so an `⌥`-chord that is harmless on U.S. English may collide on German,
French or Dvorak. If any `⌥`-chord reaches a text field, the user gets a character instead of a
command — silently, with no error.

Compounding this, the macOS Zoom accessibility feature claims `⌥⌘=`, `⌥⌘−`, `⌥⌘8` and `⌥⌘\` at
system level whenever "Use keyboard shortcuts to zoom" is enabled.

**The resolution.**

- **A bare `⌥`+key chord is never bound at `.application` scope.** In `.finder`, `⌥` appears only in
  combination with `⌘` (`⌥⌘E`, `⌥⌘N`, `⌥⌘V`, `⌥⌘S`, `⌥⌘Y`, `⌥⌘A`, `⌥⌘K`, `⌥⌘F`, `⌥⌘2`, `⌥⌘0`,
  `⌥⌘←/→`, `⌥⌘↓`, `⌥⌘⌫`, `⌥⌘L`). `⌘` suppresses text insertion, so these are safe everywhere.
- `.commander`'s bare-`⌥` chords (`⌥0`–`⌥9`, `⌥↑`, `⌥←`, `⌥→`, `⌥⏎`, `⌥＋`, `⌥−`, `⌥F1`, `⌥F2`,
  `⌥F4`, `⌥F12`) are all `.fileList` scope. Note that `⌥0`–`⌥9` on a U.S. layout produce `º`, `¡`,
  `™`, `£`… — harmless in a table that ignores unmatched characters, catastrophic in a text field.
  Scope is what makes them safe.
- **`⌥⌘=`, `⌥⌘−`, `⌥⌘8` and `⌥⌘\` are on the permanent blocklist** in all three presets, including
  `.custom`. The keymap validator rejects them with a spoken explanation, because taking them would
  break screen magnification for a low-vision user. The mask-selection commands that would naturally
  have landed on `⌥⌘=`/`⌥⌘−` (7zFM's keypad `＋`/`−`) live on `⌥⌘S`/`⇧⌥⌘S` for exactly this reason.
- 7zFM's `WM_SYSCHAR` handler swallows `Alt+Enter`, `Alt+*`, `Alt++` and `Alt+-` purely to suppress
  the Windows beep. macOS has no equivalent beep, so there is nothing to reproduce — but the
  `.fileList` handler must still `return` rather than call `super.keyDown` for handled chords, or
  AppKit will emit the standard unhandled-key funk sound.

### 3.6 `⌘↑` is "enclosing folder" in Finder, `Backspace` is "up" in 7zFM

**The conflict.** Both keys mean the same thing in their own world, and both are strongly trained.
Neither collides with anything else in our command set.

**The resolution.** Bind both, in both presets. `⌘↑` is the **primary** — it is what the
`View ▸ Up One Level` menu item displays, it works from anywhere in the app, and it is what a Mac user
will try first. `⌫` is a `.fileList` alias, exactly as safe as [§3.3](#33-delete-is-backspace-like-on-macos)
establishes, and it is what a 7-Zip user will try first.

The related pair `⌃PgUp` (7zFM: Open Parent Folder) and `⌃PgDn` (Open Inside) are Commander-only.
`⌃⌘↑` is **not** used for "up": in Finder that chord means "open the enclosing folder in a new
window", and ArcSeven uses it for [Same Folder in Other Pane](#27-panes), which is the same "up plus
another window" gesture family and therefore not confusing.

### 3.7 `Tab` vs Full Keyboard Access

**The conflict.** `Tab` switches panes in 7zFM (`CPanelCallbackImp::OnTab`). On macOS, `Tab` is the
Full Keyboard Access traversal key: when *Keyboard navigation* is enabled in System Settings ▸
Keyboard, `Tab` must move focus to the next control. Stealing it app-wide would make ArcSeven
unnavigable for keyboard-only and switch-control users — a hard accessibility failure, not a
preference.

It is also tempting to solve this by putting `⇥` on a menu item as its key equivalent. **That must
not be done**: a menu key equivalent is consulted by `NSApplication` before the window sees the event,
so it would swallow `Tab` inside the path bar, inside the rename editor, and inside every sheet.

**The resolution.**

- `Tab` is `.fileList` scope, handled in `FileListTableView.keyDown(with:)`, never a menu equivalent.
- The menu carries **View ▸ Other Pane** with no key equivalent and a `⇥` hint in the item's
  attributed title, so the binding is still discoverable.
- The pane's key-view loop is ordered so the *next* key view after pane A's table is pane B's table.
  With Full Keyboard Access on, `Tab` therefore still lands on the other pane in the common case, by
  the platform's own mechanism rather than ours.
- A Settings checkbox, **"Tab switches panes"**, defaults to on, and defaults to **off** when
  `AppleKeyboardUIMode` in `NSGlobalDomain` indicates Full Keyboard Access at first launch. When it
  is off, `keyDown` calls `super` and traversal is entirely AppKit's. See [§7.2](#72-full-keyboard-access).
- `⌃⇥` is **reserved** and left unbound: macOS gives it to window-tab switching, and window tabs are
  a planned ArcSeven feature.

### 3.8 `␣`: Quick Look vs type-select vs Norton marks

**The conflict.** Three claimants.

- macOS: `␣` is Quick Look. In Finder it is the single most-used key after the arrows.
- `NSTableView`: `␣` is a legal type-select character (a filename may contain a space).
- Norton/Total Commander tradition, and 7zFM's Alternative selection mode: the mark-and-advance key
  is `Insert`, which a Mac laptop does not have; `␣` is the obvious substitute. Several third-party
  cheat sheets claim `Space` toggles selection in 7-Zip itself — **it does not**; there is no
  `VK_SPACE` case anywhere in `PanelKey.cpp` or `Panel.cpp` ([§6.1](#61-space)).

**The resolution.** The mode decides.

| Alternative selection mode | `␣` | Quick Look | Mark & advance |
|---|---|---|---|
| Off (default) | Quick Look | `␣`, `⌘Y` | n/a |
| On | Toggle mark and advance | `⌘Y` | `␣`, `Insert` |

`⌘Y` is always Quick Look regardless of mode, so the command never becomes unreachable and VoiceOver
users always have a stable chord. Type-select never receives a bare `␣` as its *first* character;
once a buffer exists, `␣` extends it rather than firing either command, and the buffer clears after
the standard AppKit timeout.

### 3.9 Right-Control-only bookmarks

**The conflict.** 7zFM opens a favourite on `Alt+0…9` **or** on `RightCtrl+0…9`, tested literally as
`IsKeyDown(VK_RCONTROL)`. Left Control does nothing. AppKit's key-equivalent matching sees only
`NSEvent.ModifierFlags.control` and cannot distinguish the two; the left/right distinction is only
observable in `flagsChanged(with:)` via `keyCode` 59 vs 62, which is not usable for command dispatch.

**The resolution.** Not reproduced. Favourites are `⌃⌥0`–`⌃⌥9` (open) and `⇧⌃⌥0`–`⇧⌃⌥9` (set) in
`.finder`, with `⌥0`–`⌥9` / `⌥⇧0`–`⌥⇧9` added in `.commander`. `⌘1`–`⌘4` are unavailable because
those are the view modes (7zFM's `Ctrl+1`–`Ctrl+4`), and view-mode fidelity outranks a bookmark
chord. Recorded here as a deliberate, permanent divergence.

### 3.10 Collisions inherited from ARCHITECTURE.md

[ARCHITECTURE.md](ARCHITECTURE.md)'s keyboard column was a sketch, and it collides with itself twice.
Both are resolved here; this document is the authority.

| Collision | ARCHITECTURE.md | Resolution here | Why |
|---|---|---|---|
| `⌥⌘2` claimed by both **Two Panes** (rows 3, 76, 147) and **focus right path bar** (row 149) | `⌥⌘1`/`⌥⌘2` = focus left/right path bar; `⌥⌘2` = toggle two panes | **Two Panes keeps `⌥⌘2`.** Path-bar focus becomes a single `⌘L` for the focused pane. | `⌥⌘2` for "two panes" is stated three times and is mnemonic. Left/right path-bar variants are unnecessary once `⇥` selects the pane, and `⌘L` is the universal macOS location-field chord. Commander keeps explicit `⌥F1`/`⌥F2`. |
| `⌥⌘←`/`⌥⌘→` claimed by both **focused subfolder in other pane** (row 29) and **Copy to Other Pane** (row 34) | both | **Copy to Other Pane keeps `⌥⌘←`/`⌥⌘→`.** Pane-sync moves to the `⌃⌘`+arrow family: `⌃⌘↑` same folder, `⌃⌘←`/`⌃⌘→` focused subfolder. | Copy/move between panes is the flagship two-pane operation and deserves the lighter chord. Pane-sync is niche. Grouping all three sync commands on `⌃⌘`+arrow makes them learnable as a set. |

### 3.11 Near-misses, accepted knowingly

Chords where ArcSeven's meaning differs from a *Finder-specific* (not system-wide) binding. Each is
app-scoped on Finder's side, so nothing breaks; they are listed so the choice is on the record.

| Chord | Finder's meaning | ArcSeven's meaning | Verdict |
|---|---|---|---|
| `⌘R` | Show Original (alias) | Refresh | We have no aliases. Refresh is 7zFM's `Ctrl+R` and `⌘R` is near-universal for reload. |
| `⌥⌘Y` | Slideshow | Folders History | The slideshow association is weak; `⌘Y` remains Quick Look. |
| `⌥⌘N` | New Smart Folder | Add to Archive… | We have no smart folders, and this completes the `N` family. |
| `⌃⌘↑` | Open enclosing folder in new window | Same Folder in Other Pane | Same gesture family ("up, elsewhere"). |
| `⌃⌘S` | Hide Sidebar | *(reserved, unbound)* | Left free in case a Places sidebar is added. |
| `⌃⌘A` | Make Alias | *(reserved, unbound)* | Left free for a future alias command; `File ▸ Link…` stays menu-only, as in 7zFM. |
| `⌘E` | Eject | Edit in External Editor | Deliberate, and deliberately this way round: a user expecting Eject who launches an editor loses nothing, while a user expecting Edit who unmounts a volume mid-write could lose data. Eject is `⌃⌘E`. |

---

## 4. The Finder preset, justified

The rule the whole preset follows: **when Finder has an opinion about a chord, Finder wins; when
Finder has no opinion, the 7zFM chord is carried over as literally as macOS permits.**

### 4.1 Chords taken verbatim from Finder

These are not designed, they are inherited, and any deviation would be a bug:

`⌘O` open · `⌘↓` open · `⌘↑` enclosing folder · `⌘I` Get Info · `⌘D` Duplicate · `⇧⌘N` New Folder ·
`⌘N` New Window · `⌘A` Select All · `⇧⌘A` Deselect All · `⌘C`/`⌘X`/`⌘V` clipboard · `⌥⌘V` Move Item
Here · `⌥⌘C` Copy as Pathname · `⌘⌫` Move to Trash · `⌥⌘⌫` Delete Immediately · `⌘F` Find ·
`⌘Y`/`␣` Quick Look · `⌘[`/`⌘]` Back/Forward · `⇧⌘G` Go to Folder · `⇧⌘C` Computer · `⇧⌘H` Home ·
`⇧⌘O` Documents · `⇧⌘D` Desktop · `⌥⌘L` Downloads · `⌘1`–`⌘4` view modes · `⌃⌘`+digit sort family ·
`⌥⌘T` Show/Hide Toolbar · `⌘,` Settings · `⌘?` Help · `⌘W` Close · `⌘Q` Quit · `⎋`/`⌘.` cancel ·
typing `/` or `~` to open Go to Folder.

### 4.2 Open vs rename: the `⏎` key

Covered in [§3.2](#32-return-means-rename-in-finder-and-open-in-7zfm). The knock-on effect is the
`↓`-arrow family, which stays coherent because Finder already established `⌘↓` as "descend":

| Chord | Command | Rationale |
|---|---|---|
| `⌘↓` | Open | Finder. Tries the internal archive handler first for a single file, then LaunchServices. |
| `⌃⌘↓` | Open Inside | `⌃` carried over from 7zFM's `Ctrl+PgDn`, and `⌃` reads as "deeper". |
| `⌥⌘↓` | Open Outside | `⌥` reads as "somewhere else / alternate application", which is exactly what Open Outside does. 7zFM uses `Shift` here; `⇧⌘↓` is left free because `⇧`+arrow means "extend selection" everywhere on macOS and overloading it invites accidents. |

### 4.3 The `E` family

7zFM has no Extract shortcut at all, so this family is ArcSeven's to define, and it is built to be
learnable as a group rather than as five unrelated chords:

| Chord | Command |
|---|---|
| `⌘E` | Edit in External Editor (7zFM `F4`) |
| `⌥⌘E` | Extract… |
| `⇧⌥⌘E` | Extract Here |
| `⌃⌥⌘E` | Extract to `<name>/` |
| `⌃⌘E` | Eject |

### 4.4 The `N` family

Every "make a new thing" is on `N`, distinguished only by modifier. This is the tidiest structure in
the preset and it absorbs 7zFM's `Ctrl+N` (Create File) without displacing `⌘N`:

| Chord | Command | 7zFM origin |
|---|---|---|
| `⌘N` | New Window | none (7zFM is single-window) |
| `⇧⌘N` | New Folder | `F7` |
| `⌃⌘N` | New File | `Ctrl+N`, `Shift+F4` |
| `⌥⌘N` | New Archive (Add to Archive…) | toolbar only |

### 4.5 The `S` family (selection)

7zFM's selection commands live on the numeric keypad, which most Macs do not have. Rather than
inventing five unrelated chords, they are grouped on `S`, with `⌘S` itself left unbound because
ArcSeven has nothing to save:

| Chord | Command | 7zFM origin |
|---|---|---|
| `⌘A` / `⇧⌘A` / `⌥⌘A` | Select All / Deselect All / Invert | `Ctrl+A` & `⇧＋` / `⇧−` / `＊` |
| `⌥⌘S` | Select… (mask) | `＋` |
| `⇧⌥⌘S` | Deselect… (mask) | `−` |
| `⌃⌥⌘S` | Select by Type | `⌥＋` |
| `⇧⌃⌥⌘S` | Deselect by Type | `⌥−` |

The two four-and-five-key chords are accepted because both commands are rare, both are menu-backed,
and `⌘F` live filtering is the discoverable modern path to the same outcome. `⌥⌘=`/`⌥⌘−` — the
geometrically obvious mapping of keypad `＋`/`−` — are unusable; see [§3.5](#35--types-characters-so--chords-are-dangerous).

### 4.6 Arrow-key families

Arrows carry three distinct families, kept apart by modifier, and the split is deliberate:
`⌥⌘` moves *data* between panes, `⌃⌘` moves *the view* between panes, plain `⌘` moves *you*.

| Family | Chords | Meaning |
|---|---|---|
| `⌘`+arrow | `⌘↑`, `⌘↓` | Navigate: up one level, open |
| `⌥⌘`+arrow | `⌥⌘←`, `⌥⌘→` | **Copy** to the other pane (7zFM `F5`) |
| `⇧⌥⌘`+arrow | `⇧⌥⌘←`, `⇧⌥⌘→` | **Move** to the other pane (7zFM `F6`) |
| `⌃⌘`+arrow | `⌃⌘↑`, `⌃⌘←`, `⌃⌘→` | Pane sync (7zFM `Alt+Up`, `Alt+Left/Right`) |
| `⌥⌘↓` / `⌃⌘↓` | | Open Outside / Open Inside |

`⇧`+arrow and plain arrows are left to `NSTableView` — extending the selection must never be
overridden.

### 4.7 Digits

| Family | Meaning | 7zFM origin |
|---|---|---|
| `⌘1`–`⌘4` | View modes | `Ctrl+1`–`Ctrl+4`, digit preserved |
| `⌃⌘3`–`⌃⌘7` | Sort by Name / Type / Date / Size / Unsorted | `Ctrl+F3`–`Ctrl+F7`, digit preserved from the F-key number |
| `⌃⌥0`–`⌃⌥9` | Open favourite | `Alt+0`–`Alt+9` |
| `⇧⌃⌥0`–`⇧⌃⌥9` | Set favourite | `Alt+Shift+0`–`Alt+Shift+9` |
| `⌥⌘2` | Two Panes | `F9` |
| `⌥⌘0` | Operation Queue | none |

`⌃⌘1`, `⌃⌘2`, `⌃⌘8`, `⌃⌘9`, `⌃⌘0` are left unbound — the last three to match 7zFM, where
`Ctrl+F8`–`Ctrl+F12` reach the sort lookup, find nothing, and silently do nothing.

### 4.8 Commands the Finder preset deliberately leaves unbound

Split file, Combine files, Link…, Alternate streams, Diff, every CRC method, Benchmark, Delete
Temporary Files, Auto Refresh, the timestamp-precision submenu, the four `View ▸ Toolbars` toggles,
Swap Panes, Show `..` item. All are menu items with no chord — which is exactly what 7zFM does. A
chord that nobody presses is a chord that cannot be given to something better later.

---

## 5. The Commander preset ("7-Zip Classic")

Defined as `Presets.finder` overlaid with the table below. Nothing is removed; `⏎` and `␣` are the
only two chords the overlay overrides.

| Group | Chords added | Scope |
|---|---|---|
| Function keys | `F1` help · `F2` rename · `F3` view · `F4` edit · `F5` copy · `F6` move · `F7` new folder · `F8` Trash **[UNVERIFIED]** · `F9` two panes · `⇧F4` new file · `⇧F5` duplicate · `⇧F6` rename-in-place · `⇧F10` context menu · `⌃F3`–`⌃F7` sort · `⌥F1`/`⌥F2` path bar left/right · `⌥F4` quit · `⌥F12` folders history | `.fileList` |
| Return | `⏎` **Open** (overrides Rename) · `⇧⏎` Open Outside · `⌥⏎` Properties | `.fileList` |
| Control letters | `⌃A` · `⌃C` · `⌃X` · `⌃V` · `⌃N` · `⌃R` · `⌃Z` (Comment) | `.fileList` |
| Control others | `⌃Ins` copy · `⌃PgDn` open inside · `⌃PgUp` up one level | `.fileList` |
| Option digits | `⌥0`–`⌥9` open favourite · `⌥⇧0`–`⌥⇧9` set favourite | `.fileList` |
| Option arrows | `⌥↑` same folder in other pane · `⌥←`/`⌥→` focused subfolder in other pane | `.fileList` |
| Numeric keypad | `＋` select mask · `−` deselect mask · `＊` invert · `⇧＋` select all · `⇧−` deselect all · `⌥＋` select by type · `⌥−` deselect by type | `.fileList` |
| Editing keys | `⌦` Trash · `⇧⌦` delete permanently · `Ins` mark and advance | `.fileList` |
| Path | `\` Computer | `.fileList` |

**Not** reproduced in Classic, on principle:

- **`⌃W` does not quit.** 7zFM's `Ctrl+W` posts `IDCLOSE`. Shipping a chord one key away from
  `⌘W` that terminates the app mid-extraction is a data-loss bug regardless of preset.
- **`RightCtrl+0…9`** — impossible in AppKit ([§3.9](#39-right-control-only-bookmarks)).
- **The "only works when the list has focus" limitation** is not reproduced for the inherited Finder
  chords; those stay app-wide. It applies to the Classic chords only because the platform forces it,
  not as a fidelity choice.

Every Classic chord is `.fileList` scope. That is what makes bare `⌃`+letter and bare `⌥`+digit safe
([§3.4](#34-cmd-is-the-primary-modifier-not-ctrl), [§3.5](#35--types-characters-so--chords-are-dangerous)),
and it is why switching presets can never break typing in the path bar or the rename editor.

---

## 6. Unresolved items — must be verified against a running 7zFM

Each of these is a place where the source does not say what the documentation says. They are marked
`// VERIFY:` in code with the identifiers below, and each is behind a compile-time-visible constant so
it can be flipped without a redesign. **Do not implement fidelity behaviour for these until a human
has confirmed the actual behaviour of a shipped 7zFM build.**

Verification protocol: Windows 11 VM, official 7-Zip 25.x or later `7zFM.exe`, a folder containing at
least one file whose name begins with a space, one archive, and one read-only folder. Record results
in `docs/VERIFICATION.md` with the 7-Zip build number and the date.

### 6.1 `Space`

**Claim under test:** several third-party cheat sheets state that `Space` toggles selection of the
focused item in 7-Zip's file manager.

**What the source says:** there is no `VK_SPACE` case in `CPanel::OnKeyDown` (`PanelKey.cpp`) and none
in `CMyListView::OnMessage` (`Panel.cpp`). `WM_CHAR` explicitly swallows `VK_MULTIPLY`, `VK_ADD` and
`VK_SUBTRACT` so they never reach the ListView's incremental search — but `VK_SPACE` is *not* in that
swallow list, which strongly implies `Space` falls through to the Win32 ListView's default handling
(type-ahead, or in `LVS_SINGLESEL` mode a no-op).

**How to verify:** focus a file, press `Space`, observe. Then repeat with Alternative selection mode
on. Then press `Space` immediately after typing a partial filename to see whether it extends the
type-ahead buffer.

**ArcSeven's position, independent of the answer:** `␣` is Quick Look (mode off) or mark-and-advance
(mode on), per [§3.8](#38-space-quick-look-vs-type-select-vs-norton-marks). This is a *chosen*
behaviour, not a guess at 7zFM's — so the verification result cannot invalidate the design. It only
determines whether a "Classic: Space does nothing" footnote is warranted.

### 6.2 `F8`

**Claim under test:** widely-circulated 7-Zip cheat sheets map `F8` to Delete, following the
Norton/Total Commander convention.

**What the source says:** there is no `VK_F8` case in `PanelKey.cpp`. The File menu shows `Del` — not
`F8` — next to `&Delete`. `F8` is not in `IDR_ACCELERATOR1`. On the available evidence, `F8` does
nothing in 7zFM.

**How to verify:** select a file, press `F8`, observe whether the delete confirmation appears.
Repeat with `Shift+F8`.

**ArcSeven's position:** `.commander` binds `F8` → Move to Trash, flagged **[UNVERIFIED]** in the table
and in the preset's onboarding sheet. Rationale: the Commander preset's contract is *Windows file
manager muscle memory*, and in the Norton lineage `F8` is delete; a Total Commander user pressing
`F8` and getting nothing is a worse outcome than a strict-fidelity user getting a delete
confirmation they can cancel. If verification shows `F8` is inert in 7zFM, the binding stays but the
release notes must state that it is a Commander-preset addition rather than 7zFM fidelity.
`.finder` binds `F8` to nothing either way.

### 6.3 `Ctrl`+keypad `＋` (column auto-size)

**Claim under test:** the official 7-Zip manual documents `Ctrl+[Grey +]` as "Adjust optimal column
width for items".

**What the source says:** in `PanelKey.cpp` the `VK_ADD` case with `ctrl` set falls through to
`return true` with no explicit handler — meaning 7-Zip does not implement it. The behaviour the manual
describes is almost certainly the Win32 `SysListView32` control's own built-in
`LVS_EX`/`LVM_SETCOLUMNWIDTH` `LVSCW_AUTOSIZE` response, i.e. a control feature, not an application
feature.

**How to verify:** widen a column manually, press `Ctrl`+keypad `＋`, and observe whether the widths
change. Then repeat in the Large Icons view mode (where there is no header) — if the behaviour is the
ListView's, it should do nothing there.

**ArcSeven's position:** `NSTableView` has no equivalent built-in. Size Columns to Fit is a menu item
with no chord, plus the Mac-native double-click on a header divider. If verification shows 7zFM
genuinely autosizes, nothing changes — the command exists, only the chord is absent, and adding one
later costs nothing.

### 6.4 `Ctrl+F8`…`Ctrl+F12` are silently inert

**What the source says:** these reach the sort-command lookup, find no matching PROPID pair, and
return without acting. Cosmetically identical to an unbound key.

**How to verify:** press each with a sorted panel and confirm the sort indicator does not move and no
error appears.

**Consequence if wrong:** if any of them turns out to sort by a fifth column, `⌃⌘8`–`⌃⌘0` would need
bindings. They are currently reserved and unbound for exactly this reason.

### 6.5 The drives-folder title prefix

**What the source says:** `CApp::RefreshTitle` sets the window title to the focused panel's
`_currentFolderPrefix` and nothing else, falling back to the literal string `7-Zip` when that is
empty. For `CFSDrives` the prefix is the folder's `kpidPath`, which appears to be empty — so the title
should fall back to `7-Zip`. This was flagged `[UNCERTAIN]` in the source survey.

**How to verify:** press `\` to reach the drive list and read the title bar.

**Consequence:** affects the Computer root's window title only. ArcSeven uses the localized display name
of the root in that position; if 7zFM really does show a bare path there, the fidelity ledger gains a
one-line note.

### 6.6 `/` and keypad `/` reaching `OpenDrivesFolder`

**What the source says:** the `VK_DIVIDE` / `'\\'` / `VK_OEM_5` block in `PanelKey.cpp` is entirely
commented out — including the `OpenRootFolder()` call inside it — and the live handling is in
`CMyListView::OnMessage` on `WM_CHAR`, calling `OpenDrivesFolder()`. Whether **all three** of `\`,
main-row `/` and keypad `/` reach that `WM_CHAR` path is not established from the source alone.

**How to verify:** press each of the three keys in a filesystem panel and note which reach the drive
list and which start type-ahead instead.

**Consequence:** `.commander` currently binds only `\` → Computer, because `/` is claimed by Go to
Folder in both presets (Finder's own behaviour) and that is not negotiable. If verification shows all
three work in 7zFM, the divergence is documented rather than fixed.

### 6.7 `Ctrl+Insert` and `Insert` outside Alternative selection mode

**What the source says:** `Ctrl+Insert` is listed as an alias for `EditCopy()`, and `Insert` is stated
to be active *only* in Alternative selection mode, otherwise falling through to the ListView default.

**How to verify:** with Alternative selection mode **off**, press `Insert` on a focused file and
observe whether the selection changes and whether focus advances. Then press `Ctrl+Insert` and check
the clipboard.

**Consequence:** determines whether `.commander`'s `Ins` binding should be unconditional or
mode-gated. Currently mode-gated, matching the source.

---

## 7. Accessibility

Accessibility is a shipping requirement, not a milestone. A file manager is a keyboard application
before it is a mouse application, and a dense two-pane table is precisely the kind of UI that is
routinely inaccessible.

### 7.1 The non-negotiables

1. **Every command is reachable without a pointer.** No command may exist only as a double-click, a
   drag, a header click, or a context-menu-only item. Concretely: drag-and-drop between panes has
   `⌥⌘←/→` and `⇧⌥⌘←/→` equivalents; header-click sorting has `⌃⌘3`–`⌃⌘7`; the header's show/hide
   column menu is duplicated in `View ▸ Columns`; header-divider double-click has
   `View ▸ Size Columns to Fit`.
2. **Every command is a menu item.** This is what makes it discoverable, what lets VoiceOver speak
   its shortcut, what lets `validateUserInterfaceItem(_:)` disable it in exactly one place, and what
   lets a user re-key it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts. This is
   the single largest functional improvement over 7zFM, where shortcuts die when the list loses
   focus.
3. **No command is on a system-reserved chord.** The keymap validator enforces the
   [§1.3 tier-1 blocklist](#13-dispatch-precedence) in all three presets, including `.custom`, and
   explains the refusal in words ("`⌥⌘=` is reserved by macOS Zoom").
4. **No meaning is carried by colour alone.** Marked rows in Alternative selection mode get a leading
   marker glyph and an accessibility value, not just a tint —
   `NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor` is honoured, and the
   glyph is shown unconditionally rather than only when that flag is set.

### 7.2 Full Keyboard Access

- The key-view loop is set explicitly, not left to AppKit's geometric guess. Order per window:
  toolbar → left pane path bar → left pane table → right pane path bar → right pane table → status
  bar (skipped, non-focusable). Panes are therefore *adjacent* in the loop, so `Tab` reaches the
  other pane even when ArcSeven is not intercepting it.
- `window.initialFirstResponder` is the focused pane's table.
- `Tab` interception is gated on the **"Tab switches panes"** preference (default on). At first
  launch the default is flipped to off if `UserDefaults.standard.integer(forKey: "AppleKeyboardUIMode")`
  in `NSGlobalDomain` has the full-access bit set. This is a best-effort read of an
  undocumented-but-stable preference; the user-visible checkbox is the real contract, and it is the
  first item in the Shortcuts settings pane. See [§3.7](#37-tab-vs-full-keyboard-access).
- The `NSSplitView` divider is focusable under Full Keyboard Access and moves with `←`/`→`. The
  divider's `accessibilityLabel` is "Pane divider" and its value is the split ratio as a percentage.
- Toolbar items are reachable with `⌃F5`; navigational items are marked
  `NSToolbarItem.isNavigational = true` so they group correctly.
- Sheets set `initialFirstResponder`, honour `⎋` and `⌘.` as Cancel, and give the destructive button
  a non-default role so `⏎` never destroys anything.

### 7.3 VoiceOver and the `NSTableView` panes

The panes are view-based `NSTableView`s with a fixed `rowHeight` and never
`usesAutomaticRowHeights`; they are also virtual (rows are never all materialised). Both facts matter
for accessibility.

- **Roles.** Let AppKit provide `AXTable`/`AXRow`/`AXCell`. Do not override the role. Do set
  `tableView.accessibilityLabel` to the pane's identity — "Left pane" / "Right pane" — and
  `accessibilityHelp` to the current folder path, so a VoiceOver user who lands in a pane hears which
  one it is.
- **Cell labels are spoken forms, not display forms.** The visible text stays exactly 7zFM's
  (compact sizes, the timestamp rendered at the chosen precision level), but each cell view's
  `accessibilityLabel` is a humanised string:
  - Size: `"1.2 megabytes"`, not `"1 234 567"` and not `"1.2 MB"` (which VoiceOver reads as "one
    point two M B"). Built with `ByteCountFormatter` plus an explicit unit word.
  - Dates: a `DateFormatter` `.long` date and `.short` time, not the packed
    `2026-08-24 13:45:07.1234567` form. The NTFS/nanosecond precision levels are a *visual* setting;
    reading 100-nanosecond digits aloud is useless.
  - Attributes/flags columns: expanded words, not the packed letter string.
  - Empty cells: `accessibilityLabel = ""` so VoiceOver says "empty", not the column name again.
- **The `..` row** gets `accessibilityLabel = "Parent folder"`, never the literal `..`, which
  VoiceOver reads as "dot dot".
- **Column headers** carry sort state in `accessibilityValue` — "sorted ascending" / "sorted
  descending" / no value — and post
  `NSAccessibility.post(element: header, notification: .valueChanged)` when the sort changes.
- **Marked rows** (Alternative selection mode) are not `NSTableView` selection, so they are invisible
  to the default accessibility implementation. Each `NSTableRowView` therefore exposes
  `accessibilityValue` of `"marked"` / `"not marked"` and an `NSAccessibilityCustomAction`
  named "Toggle mark", so VO users can mark rows without knowing the chord.
- **Navigation announcements.** After a folder change, post an
  `.announcementRequested` notification with `"<folder name>, <n> items"` at
  `NSAccessibilityPriorityLevel.high`. Without this, arrowing into a new folder is silent — the table
  simply has different contents and VoiceOver has no reason to say so.
- **Pane switch announcements.** Moving first responder posts `.focusedUIElementChanged`
  automatically, but the pane's *identity* is what the user needs; the table's
  `accessibilityLabel` ("Left pane") carries it, which is why that label is set even though it is
  redundant visually.
- **Virtualisation.** Because rows are supplied lazily, `accessibilityRowCount` must reflect the
  full model count, and the accessibility tree must not be rebuilt on scroll. Never call
  `reloadData()` for a selection change; use `reloadData(forRowIndexes:columnIndexes:)` so VoiceOver's
  cursor is not thrown to the top of the table.
- **Progress.** The operation progress UI throttles `.announcementRequested` to at most one every
  five seconds, uses `accessibilityValueDescription` on the `NSProgressIndicator` (`"43 percent, 2
  minutes remaining"`), and announces completion and every error at `.high` priority. An indeterminate
  phase announces "Scanning" once, not repeatedly.
- **Errors and confirmations** are sheets, never bare `NSBeep`. A beep is not an accessible error.

### 7.4 Menus and VoiceOver

- Key equivalents must be **real** `NSMenuItem.keyEquivalent` values, never text baked into the
  title. VoiceOver reads the equivalent from the item; a title reading "Copy To…  ⌥⌘→" would be
  spoken as literal symbol names.
- The dynamically rebuilt File menu (7zFM rebuilds it on every open) must keep stable
  `NSUserInterfaceItemIdentifier`s equal to the `Command.rawValue`, so App Shortcuts overrides and
  VoiceOver's menu history survive the rebuild.
- 7zFM's `MFT_MENUBARBREAK` two-column Edit menu has no macOS equivalent and no accessible
  equivalent; it becomes an `NSMenuItem.separatorItem()`, as already recorded in the ledger.
- Disabled items stay visible and disabled. 7zFM removes them entirely on small screens; that
  behaviour is not reproduced, because an item that vanishes cannot be discovered or explained.

### 7.5 The shortcut recorder

The `.custom` preset's recorder is itself a piece of accessible UI:

- Operable entirely by keyboard: `⏎`/`␣` to start recording, the chord itself to capture, `⎋` to
  cancel, `⌫` to clear a binding.
- Announces the captured chord in words via `.announcementRequested` — "Option Command Left Arrow" —
  because a symbol string is not readable.
- Refuses tier-1 system chords with a spoken reason, and warns (does not refuse) on a collision with
  another ArcSeven command, naming the other command.
- Offers "Restore Defaults" per command and for the whole table.
- Records the chord's scope too: a chord that is only safe at `.fileList` scope (bare `⌃`+letter,
  bare `⌥`+key) is silently assigned that scope, and the UI says so.

### 7.6 Type-select vs bare `⌫`

An interaction that must be implemented deliberately, not discovered as a bug:

`NSTableView` type-select builds a buffer as the user types. In every Mac list, `⌫` while that buffer
is non-empty deletes the last typed character. But ArcSeven binds bare `⌫` to Up One Level
([§3.3](#33-delete-is-backspace-like-on-macos)). Therefore:

> Bare `⌫` navigates up **only when the type-select buffer is empty**. While a buffer exists, `⌫`
> shortens it, and the buffer clears after the standard AppKit timeout or on `⎋`.

The same rule applies to `␣`: it triggers Quick Look only as the *first* character; once a buffer
exists it extends the buffer. `⌘↑` and `⌘Y` are unaffected by the buffer, which is why both commands
keep a modifier-bearing binding as their primary.

`tableView(_:typeSelectStringFor:row:)` returns the Name column's raw value, so type-ahead matches
what the user sees, and matching is diacritic- and case-insensitive.

---

## 8. Implementation notes (AppKit mechanics)

- **One key equivalent per menu item.** AppKit permits exactly one. Every alias in this document
  (`⌫`, `␣`, `⇥`, `F5`, `⌃C`, …) is therefore dispatched from `FileListTableView.keyDown(with:)`
  through the same `@objc` action selector as the menu item, so behaviour and validation cannot
  drift. Where an alias must work app-wide rather than list-scoped, add a **hidden**
  `NSMenuItem` carrying the alias equivalent rather than special-casing the responder chain.
- **Match on `charactersIgnoringModifiers`**, lowercased, with `.deviceIndependentFlagsMask` applied
  and `.capsLock`/`.numericPad`/`.function` masked off before comparison — otherwise non-US layouts
  and Caps Lock silently break every binding.
- **`keyDown` must not call `super` for handled chords**, or AppKit emits the unhandled-key sound.
  Conversely it *must* call `super` for everything it does not handle, or type-select and arrow
  navigation break.
- **Preset switching is live.** Changing the preset re-applies key equivalents across the whole menu
  tree and rebuilds the `.fileList` reverse-dispatch dictionary; no relaunch, no window rebuild.
- **Swift 6 strict concurrency.** `Keymap`, `Command`, `KeyChord`, `Modifiers` and `Binding` are
  `Sendable` value types. `KeymapStore` is `@MainActor` because everything it touches (`NSMenu`,
  `NSEvent`, the responder chain) is main-actor-isolated. Persistence encoding/decoding happens off
  the main actor and hands back a `Sendable` `Keymap`.
- **`validateUserInterfaceItem(_:)`** is the single source of enablement, mirroring 7zFM's
  `CFileMenu::Load` rules: read-only parent chain disables Rename / Move To / Delete / Comment /
  Create Folder / Create File; hash-folder listings disable almost everything; `Link…` requires
  exactly one item; `Split`/`Combine` require exactly one filesystem file. Unlike 7zFM's toolbar —
  which never disables anything and reports failure after the click — ArcSeven disables the toolbar item
  too.
- **Menu titles are API** ([§1.3](#13-dispatch-precedence), tier 2). Renaming a menu item silently
  breaks any user's App Shortcuts override. Changes go in the release notes.

---

## 9. Reserved chord register

Chords deliberately left unbound, and why. Consult this before adding a command.

| Chord | Reserved for |
|---|---|
| `⌘Z`, `⇧⌘Z` | Undo / Redo. Must never be Comment. |
| `⌘S` | Nothing to save; kept free so the `S` selection family reads cleanly. |
| `⌘T`, `⇧⌘T`, `⌃⇥`, `⇧⌃⇥`, `⌘⇧\` | Window tabs (planned M6). |
| `⌃⌘S` | Show/Hide Sidebar, if a Places sidebar is added. |
| `⌃⌘A` | Make Alias (Finder's chord), if alias creation is added. |
| `⌃⌘1`, `⌃⌘2` | Free slots in the sort family. |
| `⌃⌘8`, `⌃⌘9`, `⌃⌘0` | Match 7zFM, where `Ctrl+F8`–`Ctrl+F12` are inert. |
| `⇧⌘↓` | `⇧`+arrow means "extend selection" on macOS; not overloaded. |
| `⌃W` | Never bound. 7zFM's `Ctrl+W` quits the app; that is not reproduced. |
| `⌥⌘=`, `⌥⌘−`, `⌥⌘8`, `⌥⌘\` | macOS Zoom (Accessibility). Permanently blocklisted. |
| `⌘F5`, `⌥⌘F5`, `⌃F1`–`⌃F8` | VoiceOver, Accessibility Shortcuts, Full Keyboard Access. |
| `⌘␣`, `⌃␣`, `⌃⌘␣` | Spotlight, input-source switching, emoji picker. |
| `⌘⇥`, `⌘\``, `⌃↑`, `⌃↓`, `⌃←`, `⌃→` | App switcher, window cycling, Mission Control. |
| `⇧⌘3`, `⇧⌘4`, `⇧⌘5` | Screenshots. |
| `⌘H`, `⌥⌘H`, `⌘M`, `⌥⌘Esc` | Hide, Hide Others, Minimize, Force Quit. |
