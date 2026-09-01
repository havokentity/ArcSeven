<!--
SPDX-License-Identifier: Apache-2.0
Copyright (C) 2026 Rajesh D'Monte
-->

# ArcSeven — Fidelity Reference

**This document defines what "1:1" means for ArcSeven.**

ArcSeven is a clean-room reimplementation of the Windows 7-Zip File Manager (`7zFM.exe`) for macOS.
It is **not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov.**
Every reference to 7-Zip below is nominative and descriptive: it names the program whose behaviour
is being specified, nothing more.

> **No 7-Zip or unRAR source code appears in this repository.** Every row below cites the upstream
> file (and, where useful, the function or resource identifier) that *documents* the behaviour. The
> behaviour is then reimplemented from that description. Citations are to `github.com/ip7z/7zip`,
> branch `main` (7-Zip 26.02), paths relative to `CPP/7zip/UI/`. Resource scripts (`*.rc`) are the
> authoritative specification for captions, control sets, order and defaults; `.cpp` files are the
> authority for behaviour and defaults computed at runtime.

Companion documents:
[ARCHITECTURE.md](ARCHITECTURE.md) (how it is built) ·
[DIVERGENCES.md](DIVERGENCES.md) (every deliberate departure, with rationale).

---

## Legend

| Verdict | Meaning |
|---|---|
| **1:1** | Same capability, same control set, same order, same strings, same defaults, same edge-case behaviour. Any difference is the input device or the widget toolkit, not the semantics. |
| **Adapted** | Same capability, deliberately different mechanism or binding because the Windows mechanism does not exist on macOS or is actively wrong here. Every Adapted row has a numbered entry in [DIVERGENCES.md](DIVERGENCES.md) if the adaptation is user-visible and debatable. |
| **Deferred** | Committed to, not in v1.0. The milestone is named in the Note. |
| **Dropped** | Deliberately not shipped. Reason in the Note; full rationale in DIVERGENCES.md. |
| **UNRESOLVED** | The upstream behaviour could not be established from source and has **not** been guessed. Listed in [DIVERGENCES.md §U](DIVERGENCES.md#u--unresolved-needs-an-empirical-check-against-a-running-7zfm) with the experiment that settles it. |

**Fidelity rule of thumb:** we reproduce 7zFM's *semantics*, including its quirks — the sort
comparator, the status-bar formulas, the column defaults, the dialog control sets, the
"toolbar buttons are never disabled" behaviour, the deliberately-leaked temp files. We do **not**
reproduce Win32 dialog-unit geometry, modal property sheets, in-window menu bars, or F-key defaults
that are broken on Mac hardware.

**Engine note.** Behaviour rows that require archive I/O are implemented by driving the bundled,
unmodified upstream `7zz` binary as a subprocess (`Contents/Helpers/7zz`). Where a row's macOS
mapping names a `7zz` switch, that is the concrete mechanism.

---

## 1. Window shell and chrome

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| WIN-01 | Window title | Title is *only* the focused panel's `_currentFolderPrefix`, with trailing separator; empty prefix renders the literal string `7-Zip` (`App.cpp` `CApp::RefreshTitle`) | Same string, with `/` separators; empty prefix renders the literal app name `ArcSeven`. Additionally sets `NSWindow.representedURL` for real filesystem paths | **1:1** | Refreshed on focus change, Tab, folder change, path-bar focus — same triggers. `representedURL` is additive; the *text* stays the raw path |
| WIN-02 | Title inside archives | Accumulates virtual path: `…/outer.7z/inner.zip/sub/` (`PanelItemOpen.cpp`) | Identical | **1:1** | `representedURL` is cleared while inside an archive (there is no real URL) |
| WIN-03 | Window class / style | `7-Zip::FM`, `WS_OVERLAPPEDWINDOW` (`FM.cpp:199`, `FM.cpp:291`) | `NSWindow`, titled + closable + miniaturizable + resizable | **Adapted** | Platform primitive |
| WIN-04 | Window position restore | 5×`UInt32` (l, t, r, b, maximized) under `FM\Position` (`ViewSettings.cpp`) | `NSWindow.setFrameAutosaveName` + explicit zoomed-state key in `NSUserDefaults` (`FM.Position`) | **Adapted** | Same information, macOS-native storage |
| WIN-05 | Vertical stack | Title → menu bar → global toolbar → per-panel { rebar, list, status bar }; splitter between panels | Title → (system menu bar) → `NSToolbar` → `NSSplitView` of two panel view controllers, each { path bar, table, status bar } | **1:1** | The structural fact that path bar and status bar are **per-panel** and only the toolbar/menu are global is preserved |
| WIN-06 | Menu bar location | In-window menu bar (File / Edit / View / Favorites / Tools / Help) (`resource.rc` `IDM_MENU`) | macOS system menu bar with the same six menus, plus the mandatory `ArcSeven` app menu | **Adapted** | See MH-03/MT-01 for the items that move into the app menu |
| WIN-07 | Splitter | 4 px, position stored as a ratio out of `kSplitterRateMax = 1<<16`, proportional on resize; first-time 2-pane = dead centre (`FM.cpp`) | `NSSplitView`, `dividerThickness = 4`, identical ratio math and identical first-time centring, autosaved | **1:1** | |
| WIN-08 | Drag & drop registration | `RegisterDragDrop` on `WM_CREATE` (`FM.cpp`) | `registerForDraggedTypes` on both panel tables; outbound via `NSFilePromiseProvider` | **1:1** | Promise-drag out of an archive is an improvement, not a divergence |
| WIN-09 | About box | `IDD_ABOUT` — logo, version, build date, copyright, `www.7-zip.org` button, OK (`AboutDialog.rc`) | Standard macOS About panel + Acknowledgements pane carrying the Apache-2.0 notice, 7-Zip's `License.txt`, LGPL-2.1 text and the unRAR paragraph verbatim | **Adapted** | The homepage button links to 7-zip.org **and** to the ArcSeven repository, labelled so the two are not confused |

---

## 2. Toolbar — the seven buttons

Created as one `ToolbarWindow32` with the Archive group added first, then the Standard group
(`App.cpp` `CApp::ReloadToolbars`). Bitmaps are 48×36 / 24×24 masked with magenta.

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| TB-01 | **Add** | `kMenuCmdID_Toolbar_Add`, `IDS_ADD`, `Add.bmp`/`Add2.bmp` → Add-to-Archive dialog for the selection | `NSToolbarItem` "Add", SF Symbol `plus.rectangle.on.folder` | **1:1** | |
| TB-02 | **Extract** | `kMenuCmdID_Toolbar_Extract`, `IDS_EXTRACT` → Extract dialog | "Extract", `arrow.down.doc` | **1:1** | |
| TB-03 | **Test** | `kMenuCmdID_Toolbar_Test`, `IDS_TEST` → integrity test | "Test", `checkmark.seal` | **1:1** | Drives `7zz t` |
| TB-04 | **Copy** | `IDM_COPY_TO`, `IDS_BUTTON_COPY` — same as F5 / File ▸ Copy To… | "Copy", `doc.on.doc` | **1:1** | |
| TB-05 | **Move** | `IDM_MOVE_TO`, `IDS_BUTTON_MOVE` — same as F6 / File ▸ Move To… | "Move", `arrow.right.doc.on.clipboard` | **1:1** | |
| TB-06 | **Delete** | `IDM_DELETE`, `IDS_BUTTON_DELETE` — same as Del / File ▸ Delete | "Delete", `trash` | **1:1** | Destination is the Trash by default — see [D-03](DIVERGENCES.md#d-03--delete-moves-to-the-trash-by-default) |
| TB-07 | **Info** | `IDM_PROPERTIES`, `IDS_BUTTON_INFO` — same as Alt+Enter / File ▸ Properties | "Info", `info.circle` | **1:1** | |
| TB-08 | Button enable state | All buttons are `TBSTATE_ENABLED` **always**; an invalid operation fails *after* the click with a message box (`App.cpp`) | Real `validateToolbarItem(_:)` enable state by default | **Adapted** | Classic preset restores never-disabled. See [D-13](DIVERGENCES.md#d-13--toolbar-buttons-are-validated-not-permanently-enabled) |
| TB-09 | Toolbar visibility bitmask | One `UInt32` at `FM\Toolbars`: `1` = button text, `2` = large buttons, `4` = standard toolbar, `8` = archive toolbar, `1<<31` = "unset" sentinel. Factory default: both toolbars on, small buttons, text shown (`RegistryUtils.cpp` `ReadToolbar`) | Same four booleans, same defaults, same View ▸ Toolbars submenu, stored as `FM.Toolbars` (same bit layout) | **1:1** | |
| TB-10 | Empty toolbar | If both toolbar flags are off, the toolbar control is **destroyed**, not hidden (zero height) | `NSWindow.toolbar = nil` | **1:1** | |
| TB-11 | Button artwork | Seven `.bmp` pairs, magenta-masked (`resource.rc`) | SF Symbols, template-rendered so Dark Mode and Liquid Glass tinting are automatic | **Adapted** | Upstream artwork is not redistributed; glyphs are chosen to match the verb, not the pixels |
| TB-12 | Toolbar grouping | Two logical groups added in sequence into one control | Two `NSToolbarItemGroup`s so macOS 26 renders two glass capsules, not seven | **Adapted** | Cosmetic |

---

## 3. Panel rebar and path bar (per panel)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| PB-01 | Container | `ReBarWindow32` with two bands (`Panel.cpp`) | Horizontal `NSStackView` in the panel header | **Adapted** | Widget only |
| PB-02 | Band 0 — up button | One-button toolbar, `VIEW_PARENTFOLDER` shell image, `kParentFolderID` → `OpenParentFolder()` | `NSButton`, SF Symbol `arrow.up`, same action | **1:1** | |
| PB-03 | Band 1 — path combo | `WC_COMBOBOXEX` with the system small-icon image list, `CBES_EX_PATHWORDBREAKPROC`, `cxMinChild = 30`, editable | Editable combo (`NSComboBox` subclass) backed by an `NSPathControl`-style hierarchy popup, with per-level file icons | **1:1** | Double-click selects one path component (the `PATHWORDBREAKPROC` behaviour) is reimplemented in the field's text-selection delegate |
| PB-04 | Dropdown contents | The folder hierarchy of the current path, each level with its icon and indentation, plus root entries; inside archives the virtual components appear too | Identical, including virtual archive components | **1:1** | |
| PB-05 | Enter / Esc in the field | Enter navigates to the typed path; Esc restores the previous text (`ComboBoxEditSubclassProc`) | Identical | **1:1** | |
| PB-06 | Focus + drop-down keys | `Alt+F1` focuses and drops the **left** panel's combo, `Alt+F2` the **right** (`PanelKey.cpp`) | `⌘L` focuses the **focused** panel's path bar, `⌥⌘L` the **other** panel's; both drop the list open | **Adapted** | The literal ⌥⌘1/⌥⌘2 sketch collides with the two-panel toggle; see [D-28](DIVERGENCES.md#d-28--path-bar-focus-keys-are-remapped-to-avoid-a-collision) |
| PB-07 | Title refresh coupling | Focusing the combo refreshes the window title | Identical | **1:1** | |

---

## 4. Status bar (per panel) — the four parts

Four parts with right-edge x-coordinates 220 / 320 / 420 / rest (`Panel.cpp` `_statusBar.SetParts`);
content from `PanelListNotify.cpp` `CPanel::Refresh_StatusBar`.

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| SB-01 | Part 0 — selection count | `IDS_N_SELECTED_ITEMS` = `"{0} object(s) selected"` formatted with `"<numOperated> / <numTotal>"`, e.g. `3 / 128 object(s) selected`. `numOperated` = marked items, or the focused item when nothing is marked; `numTotal` excludes `..` | Identical string, identical formula | **1:1** | The `object(s)` pluralisation is verbatim, not localised into `object`/`objects` |
| SB-02 | Part 1 — operated size | Sum of `GetItemSize(i)` over operated items, via `ConvertSizeToString`; **empty string** when nothing is operated | Identical, including the empty-string rule | **1:1** | |
| SB-03 | Part 2 — focused size | Shown only when `focusedItem >= 0`, selection count > 0 and the focused row is not `..`; otherwise empty | Identical | **1:1** | |
| SB-04 | Part 3 — focused mtime | `kpidMTime` via `ConvertPropertyToShortString2`, same guards | Identical, rendered at the View-menu timestamp precision (MV-12) | **1:1** | |
| SB-05 | Part 4 | Commented out in the resource (focused item name) | Not present | **1:1** | |
| SB-06 | Refresh policy | Posted `kRefresh_StatusBar` on list key-down (except bare Ctrl/Shift/Alt), `NM_CLICK`, `NM_RCLICK`, and after every Select/Deselect/Invert command. Deliberately **not** on each `LVN_ITEMCHANGED` (a 9.26 performance fix), so rubber-band selection updates only on mouse-up | Identical: coalesced refresh on the same triggers, explicitly **not** per selection-change notification | **1:1** | Reproduces the visible "count lags during a drag-select" behaviour |
| SB-07 | Part widths | Fixed 220 / 100 / 100 / flexible (dialog units) | Same proportions in points, `NSStackView` with fixed-width fields and a trailing flexible field | **1:1** | |

---

## 5. Menus

Accelerator text shown in a menu is decorative on Windows: only `F1` and `Alt+F12` are real
accelerators (`resource.rc` `IDR_ACCELERATOR1`); every other shortcut is handled in
`CPanel::OnKeyDown` / `CMyListView::OnMessage`, so it only fires **when the file list has focus**.
ArcSeven makes every shortcut a real menu key equivalent that works app-wide — see
[D-14](DIVERGENCES.md#d-14--shortcuts-work-app-wide-not-only-when-the-file-list-has-focus).

### 5.1 File menu (`resource.rc` `IDM_FILE`; rebuilt on every open by `PanelMenu.cpp` `CPanel::CreateFileMenu`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MF-01 | `&Open` — `Enter` | `IDM_OPEN` → `OpenItem()`; folders open internally, a single file is tried internally (as an archive) first, then handed to the shell (`PanelItems.cpp` `OpenSelectedItems`) | `Open` — `⌘↓` (Classic: `Return`). Same internal-first dispatch | **Adapted** | Key only. See [D-01](DIVERGENCES.md#d-01--the-default-keymap-is-mac-native-not-f5f6f7) |
| MF-02 | 20-item open cap | `indices.Size() > 20` → `IDS_TOO_MANY_ITEMS` = `"Too many items"` and nothing opens | Identical cap, identical message | **1:1** | Also: only the **first** folder in a multi-selection opens |
| MF-03 | `Open &Inside` — `Ctrl+PgDn` | `IDM_OPEN_INSIDE` → `OpenItemInside(NULL)` | `Open Inside` — `⌃⌘↓` | **Adapted** | Key only |
| MF-04 | `Open Inside *` | `IDM_OPEN_INSIDE_ONE` → `OpenItemInside(L"*")` — force any single matching handler | Same command, maps to `7zz … -t*` | **1:1** | |
| MF-05 | `Open Inside #` | `IDM_OPEN_INSIDE_PARSER` → `OpenItemInside(L"#")` — parser/recovery handler | Same command, maps to `7zz … -t#` | **1:1** | |
| MF-06 | `Open O&utside` — `Shift+Enter` | `IDM_OPEN_OUTSIDE` → hand to the OS shell | `Open Outside` — `⌥⌘↓` → `NSWorkspace.open` | **Adapted** | Key only |
| MF-07 | `&View` — `F3` | `IDM_FILE_VIEW` → `EditItem(false)`, launches the configured Viewer | `View` — `⌘Y`. Empty Viewer setting → Quick Look | **Adapted** | Settings ▸ Editor still holds an explicit Viewer path (OPT-16) |
| MF-08 | `&Edit` — `F4` | `IDM_FILE_EDIT` → `EditItem(true)`, launches the configured Editor | `Edit` — `⌘E`. Empty Editor setting → the LaunchServices default editor for the type | **Adapted** | Drives the temp-file write-back flow (TMP-01…08) |
| MF-09 | `Rena&me` — `F2` | `IDM_RENAME` → in-place label edit; blocked in read-only folders and on `..` (`PanelItems.cpp`) | `Rename` — `Return` (Classic: `F2`), in-place, extension pre-deselected | **Adapted** | See [D-02](DIVERGENCES.md#d-02--return-renames-by-default-and-opens-only-in-the-commander-preset) |
| MF-10 | `&Copy To...` — `F5` | `IDM_COPY_TO` → `OnCopy(false, shift)` (`App.cpp`) | `Copy To…` — `⌥⌘→` / `⌥⌘←` (directional, to the other pane); `⌘C`/`⌘V` also work; Classic adds `F5` | **Adapted** | Semantics identical, see PAN-05 |
| MF-11 | `&Move To...` — `F6` | `IDM_MOVE_TO` → `OnCopy(true, shift)` | `Move To…` — `⇧⌥⌘→` / `⇧⌥⌘←`; `⌥⌘V` pastes-as-move; Classic adds `F6` | **Adapted** | |
| MF-12 | `&Delete` — `Del` | `IDM_DELETE` → `Delete(!IsKeyDown(VK_SHIFT))` — Recycle Bin unless Shift | `Delete` — `⌘⌫` (Trash) / `⌥⌘⌫` (permanent) | **Adapted** | See [D-03](DIVERGENCES.md#d-03--delete-moves-to-the-trash-by-default) |
| MF-13 | `&Split file...` | `IDM_SPLIT`; enabled only when `isFsFolder && numItems == 1 && all are files` | Identical command and identical enable rule | **1:1** | See SPL-01 |
| MF-14 | `Com&bine files...` | `IDM_COMBINE`, same enable rule | Identical | **1:1** | See SPL-05 |
| MF-15 | `P&roperties` — `Alt+Enter` | `IDM_PROPERTIES` (`PanelMenu.cpp` `CPanel::Properties`) | `Get Info` — `⌘I`, as a **non-modal inspector** that follows the selection | **Adapted** | Content and assembly order are 1:1 — see PRP-01…07 |
| MF-16 | `Comme&nt...` — `Ctrl+Z` | `IDM_COMMENT` → `ChangeComment()` (**not** Undo) | `Comment…` — `⌥⌘K` | **Adapted** | `⌘Z` must remain Undo. See [D-15](DIVERGENCES.md#d-15--comment-is-k-not-z) |
| MF-17 | `CRC` ▸ submenu | Popup literally labelled `CRC` (no ellipsis, no mnemonic), 11 items | Same submenu, same label, same 11 items in the same order | **1:1** | See §11 |
| MF-18 | `Di&ff` | `IDM_DIFF`; the item is **removed** when no Diff path is configured (Options ▸ Editor); a configured Diff path also unlocks "super mode" extras | Same item, same removal rule, default tool `opendiff` | **1:1** | An additional built-in archive-vs-archive diff is an improvement, listed in ARCHITECTURE §5 |
| MF-19 | `Create Folder` — `F7` | `IDM_CREATE_FOLDER`, dialog default `New Folder`, error title `Error Creating Folder` | `New Folder` — `⇧⌘N`, identical dialog, default and error title | **Adapted** | Key only |
| MF-20 | `Create File` — `Ctrl+N` (also `Shift+F4`) | `IDM_CREATE_FILE`, default `New File`, error title `Error Creating File` | `New File` — `⌃⌘N` | **Adapted** | Key only |
| MF-21 | `&Link...` | `IDM_LINK` → `IDD_LINK`: Hard Link / File Symbolic Link / Directory Symbolic Link / Directory Junction / WSL; disabled unless exactly one item (`LinkDialog.rc`) | Hard Link / File Symbolic Link / Directory Symbolic Link only | **Adapted** | Junction and WSL dropped — no macOS analogue. See [D-16](DIVERGENCES.md#d-16--link-types-junction-and-wsl-are-dropped) |
| MF-22 | `&Alternate streams` | `IDM_ALT_STREAMS` → opens the NTFS ADS pseudo-folder; disabled when unsupported for the selection | `Extended Attributes` pseudo-folder listing xattrs incl. `com.apple.ResourceFork` / `com.apple.FinderInfo` | **Deferred** | Adapted concept, ships post-v1.0 (M6). See [D-17](DIVERGENCES.md#d-17--ntfs-alternate-data-streams-become-extended-attributes) |
| MF-23 | `E&xit` — `Alt+F4` | `IDCLOSE`; **removed** when the menu is being built as a context menu (`programMenu == false`) | `Quit ArcSeven` — `⌘Q`, in the app menu; never in the context menu | **Adapted** | |
| MF-24 | 7-Zip shell verbs injected at the top | When the panel is **not** inside an archive, `CreateSevenZipMenu` inserts the shell-extension verb set at the very top of the File menu (`PanelMenu.cpp`) | Same verb set, same position, served from ArcSeven's own command table (no extension round-trip) | **1:1** | Verb list at SHL-04…SHL-09 |
| MF-25 | `System ▸` submenu | When Options ▸ Settings ▸ "Show system menu" is on **and** not inside an archive, the full Explorer shell context menu is inserted as a `System` submenu at position 0 (slow inside big archives, hence the guard) | `Finder ▸` submenu: Reveal in Finder, Quick Look, Open With ▸, Get Info, Tags ▸, Services ▸ | **Adapted** | Same option, same default (off), same in-archive guard. See [D-18](DIVERGENCES.md#d-18--the-system--shell-menu-becomes-a-finder--submenu) |
| MF-26 | Disable rules | Read-only folder chain disables Rename / Move To / Delete / Comment / Create Folder / Create File. Hash folders disable Open, Open Inside ×3, Open Outside, View, Edit, Copy To, Move To, Comment, Create Folder, Create File, Link, Diff. `numItems != 1` disables Link | Identical rule set, applied by the same predicates (`IsThereReadOnlyFolder()` walks the **entire** parent-archive chain) | **1:1** | |
| MF-27 | Small-screen omission | When `!IsDialogSizeOK(40, 200)`, disabled items and separators are **omitted** rather than greyed | Not reproduced — items are always present and greyed | **Dropped** | Windows CE / tiny-display accommodation with no macOS analogue |
| MF-28 | Version-control extras | `Ver Edit (&1)` / `Ver Commit` / `Ver Revert` / `Ver Diff (&0)`, appended only when an undocumented `VerCtrlPath` registry value **and** a Diff path exist and exactly one FS file < 2 GiB is selected (`VerCtrl.cpp`) | — | **Dropped** | Undocumented, invocation contract never traced. See [D-09](DIVERGENCES.md#d-09--version-control-integration-ver-edit--commit--revert--diff-is-dropped) |

### 5.2 Edit menu (`resource.rc` `IDM_EDIT`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| ME-01 | `Select &All` — `Shift+[Grey +]` | `IDM_SELECT_ALL` → `SelectAll(true)`; skips `..` | `⌘A` | **Adapted** | Key only |
| ME-02 | `Deselect All` — `Shift+[Grey -]` | `IDM_DESELECT_ALL` | `⇧⌘A` | **Adapted** | Key only |
| ME-03 | `&Invert Selection` — `Grey *` | `IDM_INVERT_SELECTION` | `⌃⌘A` | **Adapted** | Key only |
| ME-04 | `Select...` — `Grey +` | `IDM_SELECT` → `SelectSpec(true)`: `IDD_COMBO` dialog titled `Select`, static `Mask:`, default value `*`, 7-Zip wildcard semantics (`DoesWildcardMatchName`), with history (`PanelSelect.cpp`) | `⌘=`, identical dialog, title, default and wildcard semantics | **Adapted** | Key only. Numpad bindings live in the Classic preset |
| ME-05 | `Deselect...` — `Grey -` | `IDM_DESELECT` → `SelectSpec(false)`, title `Deselect` | `⌘-` | **Adapted** | Key only |
| ME-06 | `MFT_MENUBARBREAK` | A bar-break item renders the Edit popup as two side-by-side columns with a vertical rule | `NSMenuItem.separatorItem()` | **Dropped** | Purely visual; no macOS construct. See [D-19](DIVERGENCES.md#d-19--the-edit-menu-column-break-becomes-a-separator) |
| ME-07 | `Select by Type` — `Alt+[Grey+]` | `IDM_SELECT_BY_TYPE` → selects every item sharing the focused item's extension | `⌥⌘=` | **Adapted** | The missing space in `Alt+[Grey+]` versus `Alt+[Grey -]` is a shipped-resource inconsistency, moot here |
| ME-08 | `Deselect by Type` — `Alt+[Grey -]` | `IDM_DESELECT_BY_TYPE` | `⌥⌘-` | **Adapted** | |
| ME-09 | Cut / Copy / Paste items | Present but **commented out** in the resource; `Ctrl+X`/`C`/`V` still work via the key handler (`PanelKey.cpp`) | Real `Cut ⌘X` / `Copy ⌘C` / `Paste ⌘V` menu items | **Adapted** | A macOS Edit menu without them is broken; the commands already existed |
| ME-10 | Clipboard payload | `EditCopy()` writes `CF_HDROP` | `NSPasteboard` file URLs; entries inside an archive are written as file **promises** | **Adapted** | Promise write-out is an improvement (no pre-extraction) |

### 5.3 View menu (`resource.rc` `IDM_VIEW`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MV-01 | `Lar&ge Icons` — `Ctrl+1` | `IDM_VIEW_LARGE_ICONS`, `LVS_ICON`, radio group 1–4 | `⌘1`, `NSCollectionView` icon layout | **Deferred** | M2; M1 ships Details only |
| MV-02 | `S&mall Icons` — `Ctrl+2` | `LVS_SMALLICON` | `⌘2` | **Deferred** | M2 |
| MV-03 | `&List` — `Ctrl+3` | `LVS_LIST` | `⌘3` | **Deferred** | M2 |
| MV-04 | `&Details` — `Ctrl+4` | `LVS_REPORT`; **`MFS_CHECKED` by default** (`kListMode_Report`) | `⌘4`, view-based `NSTableView`; same default | **1:1** | Persisted per panel, packed one byte per panel into `FM.ListMode` |
| MV-05 | Sort radios `Name` / `Type` / `Date` / `Size` / `Unsorted` — `Ctrl+F3…F7` | `IDM_VIEW_ARANGE_BY_*`, radio group | `⌃⌘3` / `⌃⌘4` / `⌃⌘5` / `⌃⌘6` / `⌃⌘7` | **Adapted** | Keys only |
| MV-06 | Sort-radio fallback quirk | `GetSortControlID` maps only Name/Extension/MTime/Size/NoProperty; **any other sort column leaves "Name" radio-checked** (`MyLoadMenu.cpp`) | Identical — sorting by e.g. CRC shows `Name` checked | **1:1** | Deliberately reproduced quirk |
| MV-07 | `Flat View` | `IDM_VIEW_FLAT_VIEW`, checkbox, **no shortcut** | Same item, same absence of a shortcut | **1:1** | See §8 |
| MV-08 | `&2 Panels` — `F9` | `IDM_VIEW_TWO_PANELS` → `SwitchOnOffOnePanel()` | `⌥⌘2` (Classic: `F9`) | **Adapted** | Key only |
| MV-09 | `Toolbars ▸` | Archive Toolbar / Standard Toolbar / — / Large Buttons / Show Buttons Text, each check-marked from `g_App` state | Identical four items, identical check state | **1:1** | |
| MV-10 | `Open Root Folder` — `\` … but see MV-11 | `IDM_OPEN_ROOT_FOLDER` → `OpenRootFolder()` (Computer / Documents / Network) | `Computer` — `⇧⌘C`, listing volumes plus Home / Documents / network shares | **Adapted** | See [D-20](DIVERGENCES.md#d-20--the-two-root-concepts-collapse-into-one) |
| MV-11 | The `\` key | Handled in `CMyListView::OnMessage` on `WM_CHAR` and calls `OpenDrivesFolder()` — the drive-letter list, **a different destination from the menu item**. The `PanelKey.cpp` block for `VK_DIVIDE` / `'\\'` / `VK_OEM_5` is entirely commented out | `/` opens `Go to Folder…` (`⇧⌘G`) | **Adapted** | The Windows split is an accident of history; macOS has one root |
| MV-12 | Timestamp-precision submenu | The item literally labelled `2017` in the resource is a placeholder whose label is replaced at menu-open time with the current UTC date at DAY precision. Children are the same instant rendered at DAY / MIN / SEC / NTFS (100 ns) / NS precision, radio-checked, then a `UTC` toggle (`IDM_VIEW_TIME_UTC`) that flips `g_Timestamp_Show_UTC` and redraws both panels (`MyLoadMenu.cpp`) | Identical, including the runtime relabel, the five precision levels, the radio state and the UTC checkbox | **1:1** | `Is_MenuItem_TimePopup()` also matches any label starting with `"20"` — a detection heuristic, not user-visible |
| MV-13 | `Up One Level` — `Backspace` | `IDM_OPEN_PARENT_FOLDER` | `⌘↑`, with `⌫` as an alias | **Adapted** | |
| MV-14 | `Folders History...` — `Alt+F12` | `IDM_FOLDERS_HISTORY`, one of the only two real accelerators | `⌥⌘Y` | **Adapted** | |
| MV-15 | `&Refresh` — `Ctrl+R` | `IDM_VIEW_REFRESH` → `OnReload()`, preserves the focused item | `⌘R` | **Adapted** | `⇧⌘R` is Reveal in Finder — see [D-21](DIVERGENCES.md#d-21--r-is-refresh-r-is-reveal-in-finder) |
| MV-16 | `Auto Refresh` | Checkbox; per-panel `SetTimer(kTimerID, kTimerElapse)` polling, suspended around modal operations by an RAII guard | Same menu toggle and same suspension policy, implemented with FSEvents / `DispatchSource` instead of polling | **Adapted** | Same capability, no timer wakeups |
| MV-17 | `Show NTFS streams`, `Show deleted files` | Present in the resource but **commented out** | Not present | **1:1** | |

### 5.4 Favorites menu (`resource.rc` `IDM_FAVORITES`; rebuilt on open by `MyLoadMenu.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MA-01 | `&Add folder to Favorites as ▸` | Cleared and refilled with exactly 10 items `Bookmark 0` … `Bookmark 9`, accel text `Alt+Shift+0` … `Alt+Shift+9`, command ids 810–819 | Same 10 items, same labels; keys `⇧⌃⌥0` … `⇧⌃⌥9` | **Adapted** | Keys only |
| MA-02 | Favourites list | Everything from index 2 down is removed and 10 items appended showing the stored path, or `-` when empty; accel text `Alt+0` … `Alt+9`, ids 830–839 | Same 10 slots, same `-` placeholder; keys `⌃⌥0` … `⌃⌥9` | **1:1** | |
| MA-03 | Long-path elision | Paths longer than 100 chars keep the first 50 and last 50 with `" ... "` inserted at the midpoint | Identical elision, identical separator string | **1:1** | |
| MA-04 | Storage | `FM\FolderShortcuts` (multi-string) | `FM.FolderShortcuts`, array of 10 strings | **Adapted** | Same key name, `NSUserDefaults` backing |
| MA-05 | Right-Ctrl bookmarks | `RightCtrl+0..9` opens and `Shift+RightCtrl+0..9` sets a bookmark (`IsKeyDown(VK_RCONTROL)`) | Not reproduced; the `⌃⌥` bindings cover both | **Dropped** | macOS does not distinguish left/right modifiers in key equivalents |

### 5.5 Tools menu (`resource.rc` `IDM_TOOLS`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MT-01 | `&Options...` | `IDM_OPTIONS` → the six-page property sheet titled `Options` | `ArcSeven ▸ Settings…` — `⌘,` | **Adapted** | Mandatory macOS placement. Page set is 1:1 — see §14 |
| MT-02 | `&Benchmark` | `IDM_BENCHMARK` → `MyBenchmark(false)`; both panels' timers are disabled for the duration | Same command, same timer suspension, driving `7zz b` | **1:1** | See §13 |
| MT-03 | `Benchmark 2` | `IDM_BENCHMARK2` / `IDD_BENCH_TOTAL` — compiled in **only** under Windows CE | — | **Dropped** | Not present on desktop Windows either |
| MT-04 | `Delete Temporary Files...` | `IDM_TEMP_DIR` → `MyBrowseForTempFolder` → `IDD_BROWSE2`, captioned `7-Zip: Browse Temp Files`: entry list, read-only path field with a `<--` up button, `Delete` / `Refresh` / `Close` / `Help`, filter combo. Scans `%TEMP%\7zO*.tmp` | Same window (captioned `ArcSeven: Browse Temp Files`), same controls, scanning the app's temp directory for `7zO*` staging dirs | **1:1** | Exists because of the deliberate temp-file leak — see TMP-07 |

### 5.6 Help menu (`resource.rc` `IDM_HELP`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MH-01 | `&Contents...` — `F1` | `IDM_HELP_CONTENTS` → `ShowHelpWindow("FM/index.htm")`; a genuine accelerator | `ArcSeven Help` — `⇧⌘/`, opening the bundled help book | **Adapted** | Help content is first-party, not 7-Zip's |
| MH-02 | `&About 7-Zip...` | `IDM_ABOUT` → `CAboutDialog` | `ArcSeven ▸ About ArcSeven` | **Adapted** | See WIN-09 |
| MH-03 | Menu ordering | Help is the last top-level menu | Same, and the app menu is first (system requirement) | **Adapted** | |

---

## 6. Columns — geometry, visibility, and the per-folder sets

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| COL-01 | Column source | Columns are **not** a fixed set: each `IFolderFolder` advertises its own property list via `GetNumberOfProperties` / `GetPropertyInfo` and the panel builds columns from it | Identical: `FolderProvider.properties` per folder kind | **1:1** | |
| COL-02 | Initial widths | `GetColumnWidth`: `kpidName` → 160 px, everything else → 100 px (`PanelItems.cpp`) | 160 pt / 100 pt | **1:1** | |
| COL-03 | Alignment | `GetColumnAlign`: date PROPIDs (`kpidCTime`, `kpidATime`, `kpidMTime`, `kpidChangeTime`) forced **left**; `VT_UI1/I2/UI2/I4/INT/UI4/UINT/I8/UI8/BOOL` **right**; `VT_EMPTY/I1/FILETIME/BSTR` **left**; anything else **centre** | Identical mapping | **1:1** | Dates left-aligned despite being `FILETIME` is an explicit upstream override, reproduced |
| COL-04 | Filesystem folder property order | `Name, Size, Modified, Created, Accessed, [Metadata Changed], Attributes, Packed Size, [iNode], [Links], Comment, Folders, Files, Path Prefix` (`FSFolder.cpp`) | Same order, plus `Mode`, `User`, `Group` available (hidden by default) for POSIX | **1:1** | The POSIX additions are hidden by default so the visible set is unchanged |
| COL-05 | Filesystem default **visibility** | `GetColumnVisible(propID, isFsFolder=true)` returns false for `Accessed`, `Metadata Changed`, `Attributes`, `Packed Size`, `iNode`, `Links`, `Link`. **Visible: Name, Size, Modified, Created, Comment, Folders, Files, Path Prefix** | Identical visible set and identical hidden set | **1:1** | `Folders`/`Files` populate only when folder statistics have been computed; `Path Prefix` is meaningful only in flat view |
| COL-06 | Drives / "Computer" folder | `Name, Total Size, Free Space, Type, Label, File System, Cluster Size`, all visible (`FSDrives.cpp`) | Same seven columns for the Volumes root; `File System` from `URLResourceKey.volumeTypeNameKey`, `Cluster Size` from `statfs.f_bsize` | **1:1** | |
| COL-07 | Root folder | Single `Name` column; items `Computer`, `Documents`, `Network`, `\\.\` (`RootFolder.cpp`) | Single `Name` column; items `Computer`, `Documents`, `Network`. `\\.\` (raw physical drives) dropped | **Adapted** | Raw-device browsing is not shipped; see [D-22](DIVERGENCES.md#d-22--raw-physical-device-browsing--is-dropped) |
| COL-08 | ZIP archive columns | `Path, Folder, Size, Packed Size, Modified, Created, Accessed, Attributes, Encrypted, Comment, CRC, Method, Characteristics, Host OS, Version, Volume Index, Offset` (`ZipHandler.cpp`) | Identical, from the corresponding `7zz l -slt` fields | **1:1** | |
| COL-09 | 7z archive columns | Ordered candidate map `Path(Name), Size, Packed Size, [Pack0..Pack4], Created, Modified, Accessed, Attributes, Position, CRC, Anti, Encrypted, Method, Block`; the handler advertises **only the properties actually present in the opened archive** (`7zProperties.cpp`) | Same candidate order; the visible set is derived per archive from the fields `7zz l -slt` actually emits | **1:1** | Whether the union-with-blanks or the per-archive dynamic set is what users see is settled as *dynamic*, matching the handler — flagged for confirmation in [DIVERGENCES §U-04](DIVERGENCES.md#u-04--7z-column-set-union-vs-per-archive) |
| COL-10 | Header context menu | Right-click on the header lists **every** property the folder exposes, in natural order, check-marked when visible, with **index 0 (Name) greyed** so it can never be hidden (`PanelItems.cpp` `ShowColumnsContextMenu`) | `NSTableHeaderView` menu with identical contents and the identical greyed-Name rule | **1:1** | |
| COL-11 | Toggling a column on | Appended at the far right (`prop.Order = _visibleColumns.Size()`) | Identical | **1:1** | |
| COL-12 | Toggling a column off | Column removed; **if it was the sort column, sorting resets to Name ascending** | Identical | **1:1** | |
| COL-13 | Column reordering | `LVS_EX_HEADERDRAGDROP` is set unconditionally — headers are always drag-reorderable, and the order persists | `NSTableView.allowsColumnReordering = true` (default), persisted | **1:1** | |
| COL-14 | Column-click sorting | `OnColumnClick` indexes `_visibleColumns[iSubItem]`, so it respects drag-reordered columns | Identical | **1:1** | |
| COL-15 | Persistence scope | Sort column, direction, widths, order and visibility saved **per folder-type ID** (`GetFolderTypeID()`) under `FM\Columns\<TypeID>`; re-read in `InitColumns` only when the type ID changes | Identical model, `FM.Columns.<TypeID>` in `NSUserDefaults` | **1:1** | A `.zip` remembers a different layout from a disk folder |
| COL-16 | `Ctrl+[Grey +]` auto-size | Documented in the manual as "Adjust optimal column width for items"; `PanelKey.cpp`'s `VK_ADD`+Ctrl branch returns without calling a handler, implying it is the ListView control's own behaviour | Not implemented pending confirmation | **UNRESOLVED** | [U-03](DIVERGENCES.md#u-03--ctrlgrey--column-auto-size) |

### 6.1 The complete PROPID → column-name table

Transcribed from `PropertyName.rc`. Every name below is the exact user-visible string. "Value source"
names where ArcSeven obtains the value: `l -slt` = the corresponding field of `7zz l -slt`; `FS` = the
filesystem (`URLResourceKey` / `stat`); `derived` = computed by ArcSeven.

| Column name | String id (`PropertyName.rc`) | macOS value source | Fidelity | Note |
|---|---|---|---|---|
| `Path` | `IDS_PROP_PATH` | `l -slt` `Path` / FS path | **1:1** | |
| `Name` | `IDS_PROP_NAME` | derived (last path component) | **1:1** | Never hideable (COL-10) |
| `Extension` | `IDS_PROP_EXTENSION` | derived, from the **last dot, dot included** | **1:1** | See SRT-06 |
| `Folder` | `IDS_PROP_IS_FOLDER` | `l -slt` `Attributes` `D` / FS `isDirectory` | **1:1** | |
| `Size` | `IDS_PROP_SIZE` | `l -slt` `Size` / FS `fileSize` | **1:1** | |
| `Packed Size` | `IDS_PROP_PACKED_SIZE` | `l -slt` `Packed Size` | **1:1** | Hidden by default on disk folders |
| `Attributes` | `IDS_PROP_ATTRIBUTES` | `l -slt` `Attributes` | **1:1** | Windows attribute letters preserved verbatim for archive entries; disk folders show the POSIX-derived equivalent |
| `Created` | `IDS_PROP_CTIME` | `l -slt` `Created` / FS `creationDate` | **1:1** | |
| `Accessed` | `IDS_PROP_ATIME` | `l -slt` `Accessed` / FS `contentAccessDate` | **1:1** | Hidden by default |
| `Modified` | `IDS_PROP_MTIME` | `l -slt` `Modified` / FS `contentModificationDate` | **1:1** | |
| `Solid` | `IDS_PROP_SOLID` | `l -slt` archive-level `Solid` | **1:1** | Archive property, not a column |
| `Commented` | `IDS_PROP_C0MMENTED` | `l -slt` `Commented` | **1:1** | Upstream identifier really is `C0MMENTED` (digit zero) |
| `Encrypted` | `IDS_PROP_ENCRYPTED` | `l -slt` `Encrypted` | **1:1** | Also the pre-flight password-prompt signal |
| `Split Before` | `IDS_PROP_SPLIT_BEFORE` | `l -slt` | **1:1** | |
| `Split After` | `IDS_PROP_SPLIT_AFTER` | `l -slt` | **1:1** | |
| `Dictionary` | `IDS_PROP_DICTIONARY_SIZE` | `l -slt` `Method` decode | **1:1** | |
| `CRC` | `IDS_PROP_CRC` | `l -slt` `CRC` | **1:1** | Uppercase hex (HSH-07) |
| `Type` | `IDS_PROP_FILE_TYPE` | derived from UTI / handler name | **1:1** | |
| `Anti` | `IDS_PROP_ANTI` | `l -slt` | **1:1** | 7z anti-items |
| `Method` | `IDS_PROP_METHOD` | `l -slt` `Method` | **1:1** | |
| `Host OS` | `IDS_PROP_HOST_OS` | `l -slt` `Host OS` | **1:1** | |
| `File System` | `IDS_PROP_FILE_SYSTEM` | `l -slt` / `statfs` | **1:1** | |
| `User` | `IDS_PROP_USER` | `l -slt` `User` / `getpwuid` | **1:1** | |
| `Group` | `IDS_PROP_GROUP` | `l -slt` `Group` / `getgrgid` | **1:1** | |
| `Block` | `IDS_PROP_BLOCK` | `l -slt` `Block` | **1:1** | 7z solid-block index |
| `Comment` | `IDS_PROP_COMMENT` | `l -slt` `Comment` | **1:1** | Editable per-entry for zip — see CMT-01 |
| `Position` | `IDS_PROP_POSITION` | `l -slt` | **1:1** | |
| `Path Prefix` | `IDS_PROP_PREFIX` | derived | **1:1** | Meaningful only in flat view; participates in the sort cascade |
| `Folders` | `IDS_PROP_FOLDERS` | derived (folder statistics) | **1:1** | Populated only once statistics are computed |
| `Files` | `IDS_PROP_FILES` | derived | **1:1** | |
| `Version` | `IDS_PROP_VERSION` | `l -slt` | **1:1** | |
| `Volume` | `IDS_PROP_VOLUME` | `l -slt` | **1:1** | |
| `Multivolume` | `IDS_PROP_IS_VOLUME` | `l -slt` | **1:1** | |
| `Offset` | `IDS_PROP_OFFSET` | `l -slt` | **1:1** | |
| `Links` | `IDS_PROP_LINKS` | `l -slt` / `st_nlink` | **1:1** | Hidden by default |
| `Blocks` | `IDS_PROP_NUM_BLOCKS` | `l -slt` | **1:1** | |
| `Volumes` | `IDS_PROP_NUM_VOLUMES` | `l -slt` | **1:1** | |
| `64-bit` | `IDS_PROP_BIT64` | `l -slt` | **1:1** | Executable handlers |
| `Big-endian` | `IDS_PROP_BIG_ENDIAN` | `l -slt` | **1:1** | |
| `CPU` | `IDS_PROP_CPU` | `l -slt` | **1:1** | |
| `Physical Size` | `IDS_PROP_PHY_SIZE` | `l -slt` archive-level | **1:1** | |
| `Headers Size` | `IDS_PROP_HEADERS_SIZE` | `l -slt` archive-level | **1:1** | |
| `Checksum` | `IDS_PROP_CHECKSUM` | `l -slt` | **1:1** | Raw property (SRT-08) |
| `Characteristics` | `IDS_PROP_CHARACTS` | `l -slt` | **1:1** | |
| `Virtual Address` | `IDS_PROP_VA` | `l -slt` | **1:1** | |
| `ID` | `IDS_PROP_ID` | `l -slt` | **1:1** | |
| `Short Name` | `IDS_PROP_SHORT_NAME` | `l -slt` | **1:1** | 8.3 names in archives; never synthesised on macOS |
| `Creator Application` | `IDS_PROP_CREATOR_APP` | `l -slt` | **1:1** | |
| `Sector Size` | `IDS_PROP_SECTOR_SIZE` | `l -slt` | **1:1** | |
| `Mode` | `IDS_PROP_POSIX_ATTRIB` | `l -slt` / `st_mode` | **1:1** | Available on disk folders too (COL-04) |
| `Symbolic Link` | `IDS_PROP_SYM_LINK` | `l -slt` / `readlink` | **1:1** | |
| `Error` | `IDS_PROP_ERROR` | `l -slt` archive-level | **1:1** | |
| `Total Size` | `IDS_PROP_TOTAL_SIZE` | `URLResourceKey.volumeTotalCapacityKey` | **1:1** | Volumes root |
| `Free Space` | `IDS_PROP_FREE_SPACE` | `volumeAvailableCapacityKey` | **1:1** | Volumes root |
| `Cluster Size` | `IDS_PROP_CLUSTER_SIZE` | `statfs.f_bsize` | **1:1** | Volumes root |
| `Label` | `IDS_PROP_VOLUME_NAME` | `volumeNameKey` | **1:1** | Volumes root |
| `Local Name` | `IDS_PROP_LOCAL_NAME` | mount point | **Adapted** | Windows network-drive concept; shows the mount path |
| `Provider` | `IDS_PROP_PROVIDER` | `volumeTypeNameKey` (e.g. `smbfs`, `apfs`) | **Adapted** | |
| `NT Security` | `IDS_PROP_NT_SECURITY` | `l -slt` (archive entries only) | **1:1 (read-only)** | Never applied on extraction — see [D-04](DIVERGENCES.md#d-04--the-ntfs-group-in-the-add-options-sub-dialog-becomes-a-macos-group) |
| `Alternate Stream` | `IDS_PROP_ALT_STREAM` | `l -slt` | **1:1 (read-only)** | See MF-22 |
| `Aux` | `IDS_PROP_AUX` | `l -slt` | **1:1** | |
| `Deleted` | `IDS_PROP_DELETED` | `l -slt` | **1:1** | |
| `Is Tree` | `IDS_PROP_IS_TREE` | `l -slt` | **1:1** | |
| `SHA-1` | `IDS_PROP_SHA1` | `l -slt` | **1:1** | Raw property |
| `SHA-256` | `IDS_PROP_SHA256` | `l -slt` | **1:1** | |
| `Error Type` | `IDS_PROP_ERROR_TYPE` | `l -slt` archive-level | **1:1** | Triggers the `Open WARNING:` row in Properties (PRP-05) |
| `Errors` | `IDS_PROP_NUM_ERRORS` | `l -slt` | **1:1** | |
| `Errors` | `IDS_PROP_ERROR_FLAGS` | `l -slt`, decoded to text | **1:1** | **Two distinct properties render with the same name** — reproduced, not fixed |
| `Warnings` | `IDS_PROP_WARNING_FLAGS` | `l -slt`, decoded | **1:1** | |
| `Warning` | `IDS_PROP_WARNING` | `l -slt` | **1:1** | |
| `Streams` | `IDS_PROP_NUM_STREAMS` | `l -slt` | **1:1** | |
| `Alternate Streams` | `IDS_PROP_NUM_ALT_STREAMS` | `l -slt` | **1:1** | |
| `Alternate Streams Size` | `IDS_PROP_ALT_STREAMS_SIZE` | `l -slt` | **1:1** | |
| `Virtual Size` | `IDS_PROP_VIRTUAL_SIZE` | `l -slt` | **1:1** | |
| `Unpack Size` | `IDS_PROP_UNPACK_SIZE` | `l -slt` | **1:1** | |
| `Total Physical Size` | `IDS_PROP_TOTAL_PHY_SIZE` | `l -slt` | **1:1** | |
| `Volume Index` | `IDS_PROP_VOLUME_INDEX` | `l -slt` | **1:1** | |
| `SubType` | `IDS_PROP_SUBTYPE` | `l -slt` | **1:1** | |
| `Short Comment` | `IDS_PROP_SHORT_COMMENT` | `l -slt` | **1:1** | |
| `Code Page` | `IDS_PROP_CODE_PAGE` | `l -slt` | **1:1** | Also drives legacy CP932/936/949 name decoding |
| `Is not archive type` | `IDS_PROP_IS_NOT_ARC_TYPE` | `l -slt` | **1:1** | |
| `Physical Size can't be detected` | `IDS_PROP_PHY_SIZE_CANT_BE_DETECTED` | `l -slt` | **1:1** | |
| `Zeros Tail Is Allowed` | `IDS_PROP_ZEROS_TAIL_IS_ALLOWED` | `l -slt` | **1:1** | |
| `Tail Size` | `IDS_PROP_TAIL_SIZE` | `l -slt` | **1:1** | |
| `Embedded Stub Size` | `IDS_PROP_EMB_STUB_SIZE` | `l -slt` | **1:1** | |
| `Link` | `IDS_PROP_NT_REPARSE` | `l -slt` reparse data | **1:1 (read-only)** | Raw property; sorted by its embedded target path |
| `Hard Link` | `IDS_PROP_HARD_LINK` | `l -slt` / `st_nlink` | **1:1** | |
| `iNode` | `IDS_PROP_INODE` | `l -slt` / `st_ino` | **1:1** | Hidden by default |
| `Stream ID` | `IDS_PROP_STREAM_ID` | `l -slt` | **1:1** | |
| `Read-only` | `IDS_PROP_READ_ONLY` | `l -slt` / FS | **1:1** | Also used in the read-only error blocks |
| `Out Name` | `IDS_PROP_OUT_NAME` | derived | **1:1** | |
| `Copy Link` | `IDS_PROP_COPY_LINK` | `l -slt` | **1:1** | |
| `ArcFileName` | `IDS_PROP_ARC_FILE_NAME` | derived | **1:1** | |
| `IsHash` | `IDS_PROP_IS_HASH` | derived | **1:1** | Marks hash-listing pseudo-folders |
| `Metadata Changed` | `IDS_PROP_CHANGE_TIME` | `l -slt` / `st_ctime` | **1:1** | Hidden by default |
| `User ID` | `IDS_PROP_USER_ID` | `l -slt` / `st_uid` | **1:1** | |
| `Group ID` | `IDS_PROP_GROUP_ID` | `l -slt` / `st_gid` | **1:1** | |
| `Device Major` | `IDS_PROP_DEVICE_MAJOR` | `l -slt` | **1:1** | |
| `Device Minor` | `IDS_PROP_DEVICE_MINOR` | `l -slt` | **1:1** | |
| `Dev Major` | `IDS_PROP_DEV_MAJOR` | `l -slt` | **1:1** | |
| `Dev Minor` | `IDS_PROP_DEV_MINOR` | `l -slt` | **1:1** | |

---

## 7. Sorting

All from `PanelSort.cpp` (`CompareItems`, `CompareItems2`, `CompareFileNames_ForFolderList`,
`CPanel::SortItemsWithPropID`).

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| SRT-01 | `..` first | `kParentIndex` returns −1 / +1 **before** the ascending flip — `..` is first in both directions | Identical | **1:1** | |
| SRT-02 | Folders before files | Also returned before the ascending flip — folders are first in both directions | Identical | **1:1** | |
| SRT-03 | Primary key | The current sort PROPID | Identical | **1:1** | |
| SRT-04 | Tie-break cascade | Up to 3 iterations: `sortProp → kpidName → kpidPrefix` | Identical, including the 3-iteration bound | **1:1** | |
| SRT-05 | Final tie-break | `MyCompare(lParam1, lParam2)` — the original enumeration order, i.e. a stable sort | Identical: stable sort on enumeration index | **1:1** | |
| SRT-06 | Natural name compare | Not lexicographic: when both cursors are on digits, leading zeros are stripped, **run length compared first**, then digits pairwise; otherwise case-insensitive via `MyCharUpper`. So `file2 < file10`, and `file002` ties with `file2` at that segment. Explicitly **not** Explorer's punctuation collation | Identical algorithm, applied to the **NFC-normalised** name | **1:1** | NFC normalisation is required because APFS returns decomposed names — see [D-23](DIVERGENCES.md#d-23--names-are-compared-and-matched-after-nfc-normalisation) |
| SRT-07 | Extension compare | Compares the substring starting at the **last dot, dot included**; no dot → empty string; same natural comparison | Identical | **1:1** | |
| SRT-08 | Raw properties | `SHA-1`, `Checksum`, `NT Security`, `Link` compare as raw byte buffers; empty sorts before non-empty; `Link` parses the reparse buffer and compares the embedded UTF-16LE target path | Same ordering rules; `Link` compares the resolved symlink target string | **1:1** | |
| SRT-09 | Direction on re-click | Clicking the same column toggles direction | Identical | **1:1** | |
| SRT-10 | Direction on new column | Resets to **ascending**, except `Size`, `Packed Size`, `Created`, `Accessed`, `Modified`, which start **descending** | Identical | **1:1** | |
| SRT-11 | Post-sort scroll | The focused item is scrolled back into view (`EnsureVisible`) | Identical (`scrollRowToVisible`) | **1:1** | |
| SRT-12 | Unsorted mode | `kpidNoProperty` → raw enumeration order, still with `..`-first and folders-first applied | Identical | **1:1** | |

---

## 8. Flat view

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| FLT-01 | Toggle | View ▸ `Flat View` (`IDM_VIEW_FLAT_VIEW`), checkbox, no shortcut | Identical | **1:1** | |
| FLT-02 | Semantics | Recursive listing of everything beneath the current folder; `Path Prefix` becomes meaningful and participates in the sort cascade | Identical | **1:1** | |
| FLT-03 | Split state | Kept **separately** for disk and for archives (`_flatModeForDisk` / `_flatModeForArc`); `ChangeFlatMode()` writes back to whichever is active; leaving an archive restores the disk value | Identical two-variable model | **1:1** | |
| FLT-04 | Persistence | Archive flat state persisted per panel as `FlatViewArc<N>` | `FM.FlatViewArc0` / `FM.FlatViewArc1` | **1:1** | |
| FLT-05 | Discoverability | — | `⌘F` live filter with a **This Folder / Entire Archive** scope toggle, where *Entire Archive* is flat view | **Adapted** | Additive: the menu item and its behaviour are unchanged |

---

## 9. Dual panes

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| PAN-01 | Maximum panels | `kNumPanelsMax = 2` (`App.h:17`) | Two | **1:1** | |
| PAN-02 | Default at first run | **`kNumDefaultPanels = 1`** (`FM.cpp:127`) — 7zFM starts as a *single*-pane manager, despite `CApp` initialising `NumPanels(2)` | Same default: one pane | **1:1** | Frequently misremembered; the source is unambiguous |
| PAN-03 | Persistence + validation | `FM\Panels` = 3×`UInt32` { numPanels, currentPanel, splitterPos }; on load `numPanels < 1 \|\| > 2 → 1`, `currentPanel >= 2 → 0` | `FM.Panels` with identical fields and identical validation | **1:1** | |
| PAN-04 | Collapsing to one pane | `IsPanelVisible(i) = (NumPanels > 1 \|\| i == LastFocusedPanel)` — the **last focused** pane survives | Identical | **1:1** | |
| PAN-05 | Copy/Move destination | `destPanelIndex = (NumPanels <= 1) ? srcPanelIndex : (1 - srcPanelIndex)`; `Shift` sets `copyToSame`, pre-filling the dialog with the focused item's **bare name** (duplicate/rename) | Identical four semantics: to-other-pane copy/move and within-folder copy/move | **1:1** | Keys adapted (MF-10/MF-11) |
| PAN-06 | One-pane copy target | With one pane, `Reduce_Path_To_RealFileSystemPath(destPath)` — copying out of an archive defaults to the archive's containing folder | Identical | **1:1** | |
| PAN-07 | Destination-pane routing | If the destination equals the other pane's path and that pane supports operations, the operation is routed through **that pane's** `IFolderOperations` — this is how you copy *into* an archive open in the other pane. `FSDrives` / `RootFolder` destinations are rejected with `Operation is not supported.` | Identical routing and identical rejection | **1:1** | Implemented as `7zz a` against the destination archive |
| PAN-08 | Self-copy guard | If `destPath == destPanel.GetFsPath()` **and** (one pane **or** `destPath == srcPanel.GetFsPath()`), show `Cannot copy files onto itself` | Identical condition, identical message | **1:1** | |
| PAN-09 | Single item into a bare filename | If exactly one item and the destination has no trailing separator, the last component is the target **name** | Identical | **1:1** | |
| PAN-10 | Copy into archive confirmation | `Confirm File Copy` / `Are you sure you want to copy files to archive` | Identical title and text | **1:1** | |
| PAN-11 | `Tab` | Switches panes; with one pane it does nothing but refresh the title. Intercepted only when the message came from the list view | `Tab` switches panes; the key-view loop is built so `Tab` reaches the other pane's table | **1:1** | `⌃Tab` stays reserved for window tabs |
| PAN-12 | `Alt+Up` | `OnSetSameFolder` — bind the **other** pane to *this* pane's folder. No-op with one pane | `⌥⌘↑` | **Adapted** | Key only |
| PAN-13 | `Alt+Left` / `Alt+Right` | `OnSetSubFolder` — take the **focused item**; not a folder → nothing; `..` → bind the other pane to this pane's parent; otherwise bind it to that sub-folder. No-op with one pane | `⌥⌘←` / `⌥⌘→` when the focus is a folder | **Adapted** | The manual's "open current folder in other panel" is imprecise; the source behaviour is reproduced |
| PAN-14 | Focus → title | Any pane list gaining focus fires `PanelWasFocused()` → title changes to that pane's path | Identical | **1:1** | |
| PAN-15 | Drag between panes | `PanelDrag.cpp`; dropping into a pane inside an archive performs an archive update | Identical, plus promise-drag out to Finder | **1:1** | |

---

## 10. Keyboard map

Windows bindings from `PanelKey.cpp` and `Panel.cpp` (`CMyListView::OnMessage`). ArcSeven ships a
**Mac-native default preset** and an opt-in **7-Zip Classic** preset; both are data, not code
([D-01](DIVERGENCES.md#d-01--the-default-keymap-is-mac-native-not-f5f6f7)).

| # | Command | Windows 7zFM | ArcSeven default | ArcSeven Classic | Fidelity |
|---|---|---|---|---|---|
| KEY-01 | Open | `Enter` | `⌘↓` | `Return` | **Adapted** |
| KEY-02 | Open outside | `Shift+Enter` | `⌥⌘↓` | `⇧Return` | **Adapted** |
| KEY-03 | Open inside | `Ctrl+PgDn` | `⌃⌘↓` | `⌃⌘↓` | **Adapted** |
| KEY-04 | Properties | `Alt+Enter` | `⌘I` | `⌥Return` | **Adapted** |
| KEY-05 | Rename | `F2` | `Return` | `F2` | **Adapted** |
| KEY-06 | View / Edit | `F3` / `F4` | `⌘Y` / `⌘E` | `F3` / `F4` | **Adapted** |
| KEY-07 | Copy To / Move To | `F5` / `F6` | `⌥⌘→` / `⇧⌥⌘→` | `F5` / `F6` | **Adapted** |
| KEY-08 | Copy/Move within folder | `Shift+F5` / `Shift+F6` | `⌥⌘D` (duplicate) / `⇧⌥⌘D` | `⇧F5` / `⇧F6` | **Adapted** |
| KEY-09 | Create Folder / File | `F7` / `Ctrl+N` (also `Shift+F4`) | `⇧⌘N` / `⌃⌘N` | `F7` / `⇧F4` | **Adapted** |
| KEY-10 | Two panels | `F9` | `⌥⌘2` | `F9` | **Adapted** |
| KEY-11 | Delete / permanent delete | `Del` / `Shift+Del` | `⌘⌫` / `⌥⌘⌫` | `⌦` / `⇧⌦` | **Adapted** |
| KEY-12 | Up one level | `Backspace` | `⌘↑` (alias `⌫`) | `⌫` | **Adapted** |
| KEY-13 | Switch pane | `Tab` | `Tab` | `Tab` | **1:1** |
| KEY-14 | Refresh | `Ctrl+R` | `⌘R` | `⌘R` | **Adapted** |
| KEY-15 | Comment | `Ctrl+Z` | `⌥⌘K` | `⌥⌘K` | **Adapted** |
| KEY-16 | Quit | `Ctrl+W` / `Alt+F4` | `⌘Q` (`⌘W` closes the window) | same | **Adapted** |
| KEY-17 | View modes | `Ctrl+1..4` | `⌘1..4` | same | **Adapted** |
| KEY-18 | Sort by Name/Type/Date/Size/Unsorted | `Ctrl+F3..F7` | `⌃⌘3..7` | `⌃F3..F7` | **Adapted** |
| KEY-19 | Select All / Deselect All / Invert | `⇧Grey+` / `⇧Grey−` / `Grey*` | `⌘A` / `⇧⌘A` / `⌃⌘A` | + numpad set | **Adapted** |
| KEY-20 | Select… / Deselect… (mask) | `Grey+` / `Grey−` | `⌘=` / `⌘-` | + numpad set | **Adapted** |
| KEY-21 | Select/Deselect by Type | `Alt+Grey+` / `Alt+Grey−` | `⌥⌘=` / `⌥⌘-` | + numpad set | **Adapted** |
| KEY-22 | Path bar focus | `Alt+F1` / `Alt+F2` | `⌘L` / `⌥⌘L` | `⌥F1` / `⌥F2` | **Adapted** |
| KEY-23 | Folders history | `Alt+F12` | `⌥⌘Y` | `⌥F12` | **Adapted** |
| KEY-24 | Bookmarks open / set | `Alt+0..9` / `Alt+Shift+0..9` | `⌃⌥0..9` / `⇧⌃⌥0..9` | same | **Adapted** |
| KEY-25 | Root / drives | `\` and `/` | `⇧⌘C` (Computer), `⇧⌘G` (Go to Folder) | same | **Adapted** |
| KEY-26 | Help | `F1` | `⇧⌘/` | `F1` | **Adapted** |
| KEY-27 | Settings | — (Tools ▸ Options) | `⌘,` | `⌘,` | **Adapted** |
| KEY-28 | Alternative-selection `Insert` | `Insert` toggles the focused mark and advances one row (only in Alternative selection mode) | `Insert` where a keyboard has one; `⌃Space` otherwise | **Adapted** | |
| KEY-29 | `Shift+arrow` range marking | `OnArrowWithShift`, polarity decided by the first item touched, then applied across the sweep (Alternative selection mode only) | Identical model | **1:1** | |
| KEY-30 | `Space` | No 7-Zip binding; falls through to the list control's type-ahead search | Quick Look (macOS convention) | **UNRESOLVED / Adapted** | Whether upstream toggles selection is [U-01](DIVERGENCES.md#u-01--space-key-selection-toggle) |
| KEY-31 | `F8` | No `VK_F8` case anywhere in `PanelKey.cpp`, contrary to several third-party cheat sheets | Unbound in both presets | **UNRESOLVED** | [U-02](DIVERGENCES.md#u-02--f8) |
| KEY-32 | `Ctrl+F8`…`Ctrl+F12` | Reach the sort lookup, find no PROPID pair, and do nothing | Unbound | **1:1** | |
| KEY-33 | Type-select | The list control's incremental search | `tableView(_:typeSelectStringFor:row:)` | **1:1** | |
| KEY-34 | Shortcut scope | Only fire when the file list has focus (they are `LVN_KEYDOWN` handlers, not accelerators) | All shortcuts are menu key equivalents and work app-wide | **Adapted** | [D-14](DIVERGENCES.md#d-14--shortcuts-work-app-wide-not-only-when-the-file-list-has-focus) |

---

## 11. CRC / hash menu and results

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| HSH-01 | Submenu label | Literally `CRC` — no ellipsis, no mnemonic (`resource.rc` `IDM_CRC`) | Identical | **1:1** | |
| HSH-02 | Item order | `CRC-32`, `CRC-64`, `XXH64`, `MD5`, `SHA-1`, `SHA-256`, `SHA-384`, `SHA-512`, `SHA3-256`, `BLAKE2sp`, `*` | Identical order and identical labels | **1:1** | |
| HSH-03 | Method strings | `CRC32`, `CRC64`, `XXH64`, `MD5`, `SHA1`, `SHA256`, `SHA384`, `SHA512`, `SHA3-256`, `BLAKE2sp`, `*` | Passed straight through as `7zz h -scrc<Method>` | **1:1** | |
| HSH-04 | `*` semantics | Computes every registered hasher, iterated **sorted ascending by hasher ID** (`HashCalc.cpp`) | Same set; the emitted row order follows `7zz h -scrc*` output | **1:1 pending U-05** | BLAKE2sp's numeric ID could not be confirmed from source — [U-05](DIVERGENCES.md#u-05--blake2sp-ordering-within-the-all-hashes-command) |
| HSH-05 | Progress | Progress dialog titled `Checksum calculating...` (`IDS_CHECKSUM_CALCULATING`) | Identical title | **1:1** | |
| HSH-06 | Result window | `IDD_LISTVIEW` titled `Checksum information`, 2 columns, deletion allowed, first row not auto-selected (`HashGUI.cpp` `ShowHashResults`) | Same window, same title, same 2-column list, same delete-row affordance | **1:1** | |
| HSH-07 | Digest case rule | digest > 8 bytes → **lowercase** hex; ≤ 8 bytes → **UPPERCASE** hex; `NULL` data → a run of spaces, 2 per byte | Identical | **1:1** | So MD5/SHA*/BLAKE2sp are lowercase and CRC32/CRC64/XXH64 are uppercase |
| HSH-08 | Group-digest suffix | For aggregate rows over more than one item: digest + `-` + extra bytes in **UPPERCASE** hex; 8 bytes when `GetNumExtraBytes_for_Group() > 4`, else 4 | Identical | **1:1** | |
| HSH-09 | Row labels | Single file → `<HASHNAME>`; otherwise `<HASHNAME> checksum for data`, `… for data and names`, and `… for streams and names` when alternate streams exist — built by substituting the hasher name into `IDS_CHECKSUM_CRC_*` and dropping the trailing colon | Identical, with `for streams and names` emitted only when xattr streams were hashed | **1:1** | |
| HSH-10 | Header rows | `Errors` (only when non-zero), `Name`, `Folders` (only when non-zero), `Files`, `Size` (`<bytes> bytes : <n> KiB\|MiB\|GiB`), `Alternate Streams`, `Alternate Streams Size` | Identical rows and identical conditionals | **1:1** | |
| HSH-11 | `.sha256` generation | The shell verb `SHA-256 -> <name>.sha256` writes a checksum file via the `Hash` archive handler | Offered in the Finder integration verb set and as `File ▸ CRC ▸ SHA-256 → file` | **1:1** | |
| HSH-12 | Verify against a checksum file | Shell verb `Test archive : Checksum` | Same command; opening a `.sha256`/`.crc32` file as a folder gives the Hash pseudo-folder | **1:1** | |

---

## 12. Dialogs

### 12.1 Add to Archive — `IDD_COMPRESS` (`CompressDialog.rc`, `CompressDialog.cpp`, `UpdateGUI.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| ADD-01 | Caption | Constant `Add to Archive` (never suffixed with the path) | Identical sheet title | **1:1** | |
| ADD-02 | Archive path split | Folder prefix as a static line **above**; the combo holds only the file name; on split failure the whole string goes into the combo and the prefix is cleared | Identical two-field split with the same failure behaviour | **1:1** | |
| ADD-03 | Archive-path history | MRU capped at `kHistorySize = 20`; selecting an item re-splits the path fields | Identical, cap included | **1:1** | |
| ADD-04 | Extension → format auto-switch | Typing/selecting a path whose extension matches another registered format switches the Format combo (`ArcPath_WasChanged`) | Identical | **1:1** | |
| ADD-05 | `...` browse | Save-panel titled `Browse`; one filter per format in combo order, described `"<Name> (<ext…>)"`; extensions in the deny list `xpi odt ods docx xlsx` are omitted from masks; then a combined `Archive: (…)` entry, then `All Files (*)`. With SFX checked the only filter is `exe (*.exe)`. Picking a format filter forces the extension and switches the Format combo | Identical filter list construction, identical deny list, identical forcing behaviour, as an `NSSavePanel` with `allowedContentTypes` | **1:1** | |
| ADD-06 | Format list gating | Skip handlers without `UpdateEnabled`; skip `Flags_KeepName()` handlers unless exactly one input **file**; skip `Hash` unless pre-selected; skip `swfc` unless a single `.swf`. Combo has `CBS_SORT` → alphabetical | Same rules; the creatable set is empirically `7z, zip, tar, gzip, bzip2, xz, wim` (verified against the bundled `7zz`); alphabetical order | **1:1** | `swfc` requires an external codec and is not shipped |
| ADD-07 | `Hash` format visibility | Shown only when pre-selected via the shell `CRC SHA` verb | Same: reachable from the checksum verbs, not offered as a normal format | **1:1** | Flagged for confirmation: [U-06](DIVERGENCES.md#u-06--hash-format-visibility-in-the-add-dialog) |
| ADD-08 | zstd | Not in the list at all — `ZstdHandler` registers `CreateArcOut = NULL` and every zstd block in `CompressDialog.cpp` is commented out | Not offered for creation; zstd archives extract and test normally | **1:1** | [D-05](DIVERGENCES.md#d-05--zstd-stays-decode-only) |
| ADD-09 | Archive-name generation | `kKeepName` formats keep the original file name and append `.<mainExt>`; otherwise the previous extension is stripped and `.<mainExt>` appended; SFX forces `.exe`; the `Hash` handler uses the lower-cased method name | Identical | **1:1** | |
| ADD-10 | Compression level | Per-format `LevelsMask`: 7z = 0–9; Zip = 0,1,3,5,7,9; GZip = 1,5,7,9; BZip2 = 1,3,5,7,9; xz = 1–9; Tar = 0; wim = 0; Hash = none (combo empty → disabled). Labels `0 - Store`, `1 - Fastest`, `3 - Fast`, `5 - Normal`, `7 - Maximum`, `9 - Ultra`; 2/4/6/8 bare. Default 5 (registry value > 9 clamps to 9, −1 → 5); `SetNearestSelectComboBox` picks the highest item ≤ desired | Identical masks, labels, defaults and nearest-selection rule. Emits `-mx=<level>` | **1:1** | |
| ADD-11 | Method combo | Per-format arrays in combo order; first entry prefixed `"*  "` (asterisk + two spaces) with item data −1 meaning "emit nothing". 7z: `LZMA2, LZMA, PPMd, BZip2` (+ external single-stream codecs; `Copy`/`Deflate`/`Deflate64` explicitly skipped). 7z+SFX: `LZMA2, LZMA, PPMd`. Zip: `Deflate, Deflate64, BZip2, LZMA, PPMd`. GZip: `Deflate`. BZip2: `BZip2`. xz: `LZMA2`. Tar: `GNU, POSIX`. wim: empty. Hash: `SHA256, SHA1` | Identical arrays, identical `"*  "` prefix and semantics. Emits `-m0=<Method>` for 7z, `-mm=<Method>` otherwise | **1:1** | |
| ADD-12 | Level 0 clears methods | When level == 0 and the handler is neither a hash handler nor Tar, the Method, Dictionary and Word-size combos are cleared and disabled | Identical | **1:1** | |
| ADD-13 | Filters are not in the Method combo | `BCJ`, `BCJ2`, `Delta`, `ARM64`, `RISCV`, `ARM`, `PPC`, `SPARC`, `IA64` are never listed; 7z applies BCJ/BCJ2 automatically at level ≥ 9. To force one you type it in **Parameters** | Identical, including the level ≥ 9 memory allowance | **1:1** | |
| ADD-14 | Dictionary size | Exact enumerations per method (LZMA/LZMA2 64-bit list `64 KB … 3840 MB`; PPMd-7z `1 MB … 1024 MB`; PPMd-zip `1 … 256 MB`; Deflate fixed 32 KB; Deflate64 fixed 64 KB; BZip2 `100 KB … 900 KB`; Copy `0 B`), with the documented auto values per level. Rendering has **no GB unit** — 1 GiB shows as `1024 MB` | Identical lists, identical auto values, identical rendering (including `1024 MB`). Emits `-m0d=<n>b` / `-md=<n>b`, or `…mem=` in PPMd order mode | **1:1** | The BZip2 `100 KB…900 KB` labelling is a 7-Zip quirk (real bzip2 blocks are 100 000-byte units) — reproduced verbatim |
| ADD-15 | Word size | LZMA/LZMA2 `8 … 273` (auto `level<7 ? 32 : 64`); Deflate `8 … 258`; Deflate64 `8 … 257`; PPMd-7z `2 … 32` (model order); PPMd-zip `2 … 16`; BZip2/Copy/GNU/POSIX/hashes disabled. `GetOrderMode()` switches the property name from `fb` to `o` | Identical lists and identical property-name switch | **1:1** | |
| ADD-16 | Solid block size | Only for `kFF_Solid` formats (**7z, xz**), and disabled at level 0. Items: `*  <auto>` (data −1) · **7z only** `Non-solid` (data 0) · `1 MB … 64 GB` (data = log₂ 20…36) · `Solid` (data 64). On OK: −1 → not specified; 0 → 0; ≥64 → fully solid; else `1 << log`. Emits `-ms=<n>b`. The auto text uses a formatter that **does** have a GB unit | Identical items, identical item data, identical emission | **1:1** | |
| ADD-17 | Thread count | Only for `kFF_MultiThread` formats (7z, Zip, BZip2, xz, generic). `autoThreads = min(cpus, numAlgoThreadsMax)` then reduced while estimated memory exceeds the limit (Zip decrements to 1; LZMA2 uses `numThreads1 = level>=5 ? 2 : 1` and decrements `numBlockThreads`). Combo: `*  <auto>` then `1 … min(hwThreads*2, numAlgoThreadsMax)`; the numeric list is skipped when both are 1. Emits `-mmt=<n>` | Identical algorithm and identical combo construction. The **auto** value additionally prefers the P-core count on Apple silicon | **1:1 +** | The P-core preference only changes the *auto* value, never an explicit selection. See ARCHITECTURE §5.4 |
| ADD-18 | Hardware-threads hint | 26.02 renders `/ <procThreads>` or `/ <proc> / <sys>` when they differ | Same, from `hw.perflevel*.logicalcpu` | **1:1** | |
| ADD-19 | Memory-limit combo | `IDC_COMPRESS_MEM_USE` is a **limit selector**, not a read-out: `*  80%` (default) · `10%…100%` (a saved custom percentage is inserted in sorted position) · byte sizes `256 MB … 16384 GB`, rendered `GB` when ≥ 2 GiB and 1 GiB-aligned, else `MB`. Command-line form strips the space and trailing `B` (`4G`, `512M`, `80%`) | Identical list and identical rendering. Emits `-mmemuse=` | **1:1** | RAM from `hw.memsize`; `_ramSize_Reduced = max(ram, 64 MB)`, auto limit = 80% |
| ADD-20 | Memory read-outs | Compressing row: `<required> [/ <limit>] [/ <RAM>]`; Decompressing row: `<decompressMemory>`. Formatting rounds **up**: ≤ 16 GiB → MB, ≤ 64 TiB → GB, else TB; undefined → `?` | Identical | **1:1** | |
| ADD-21 | Memory estimator | The exact per-method formula (LZMA/LZMA2 hash-size computation, `+2 MB`, the `numThreads1` extra `2 MB + 4 MB` at level ≥ 5, block-size inflation `blockSize += blockSize >> (blockSize < 1GB ? 1 : 2)` capped at `0xFFFF0000`, the chunked path with `numPackChunks` and the three chunk-size thread bumps, the BCJ2 `12MB*2 + 5MB` at level ≥ 9, Zip's `numMainZipThreads * (sizeof(size_t) << 23)`, PPMd `dict + 2 MB`, Deflate `(3+1) MB × threads`, BZip2 `10 MB × threads` with `decompMem = 7 MB`) | Reproduced **formula for formula** in `MemoryEstimator`, with `sizeof(size_t) = 8` | **1:1** | This is the single most-tested pure function in the project |
| ADD-22 | Recompute chain | Changing the dictionary triggers `SaveOptionsInMem → SetDictionary2 → SetSolidBlockSize → SetNumThreads → SetMemoryUsage` | Identical ordering | **1:1** | |
| ADD-23 | Update mode | `Add and replace files` / `Update and add files` / `Freshen existing files` / `Synchronize files`; `&` stripped from the localized string before insertion | Identical four entries, same order, mapped to the same `-u` action sets | **1:1** | |
| ADD-24 | Path mode | `Relative pathnames` (index 0, default) / `Full pathnames` / `Absolute pathnames` | Identical three entries and order | **1:1** | |
| ADD-25 | Split to volumes | Preset list exactly `10M`, `100M`, `1000M`, `650M - CD`, `700M - CD`, `4092M - FAT`, `4480M - DVD`, `8128M - DVD DL`, `23040M - BD`. Grammar: space-separated sequence, suffixes `b/k/m/g/t`, a `-` **terminates parsing successfully** (so `650M - CD` is one value), the remainder of a token after a suffix is skipped; `0`, non-numeric, or overflow → `Incorrect volume size` | Identical presets (including the deliberately conservative DVD/BD numbers) and identical grammar | **1:1** | |
| ADD-26 | Tiny-volume confirmation | If the last parsed size < 100 KiB: `Specified volume size: {0} bytes.\nAre you sure you want to split archive into such volumes?`, Yes/No/Cancel, only Yes proceeds | Identical | **1:1** | |
| ADD-27 | Volume naming | `<archive>.<ext>.001`, `.002`, … | Identical | **1:1** | |
| ADD-28 | `Create SF&X archive` | Enabled only for `kFF_SFX` formats (**7z only**) and only while the method is in `{Copy, LZMA, LZMA2, PPMd}`; force-unchecked when disabled; toggling rewrites the extension to `.exe` and re-filters the Method combo. Default module `7z.sfx` from the program directory | Present, **off and inoperative by default** because no Windows PE stub is bundled; the user may point Settings at a downloaded `7z.sfx`. A macOS self-extracting `.command` is offered alongside | **Adapted** | [D-07](DIVERGENCES.md#d-07--no-windows-sfx-stub-is-bundled-so-sfx-is-off-by-default) |
| ADD-29 | `Compress shared files` | `options.OpenShareForWrite` (= `-ssw`) | Same checkbox, same switch | **1:1** | |
| ADD-30 | `Delete files after compression` | `options.DeleteAfterCompressing` (= `-sdel`) | Same checkbox; deletion goes to the Trash, matching MF-12 | **Adapted** | |
| ADD-31 | Encryption group gating | The whole group is enabled only for `kFF_Encrypt` formats (**7z, zip**); `Encrypt file names` is **shown** only for `kFF_EncryptFileNames` (**7z**) and emits `-mhe=on\|off` | Identical gating and identical emission | **1:1** | |
| ADD-32 | Encryption method | 7z: single item `AES-256`, index 0 = default → emits nothing. Zip: `ZipCrypto` (index 0, default) and `AES-256`; selecting AES-256 emits `-mem=AES256` (dash removed) | Identical | **1:1** | |
| ADD-33 | Show Password | Toggling to visible **hides** the `Reenter password:` label and the second field; unchecking restores them and re-enables the match requirement. State persisted | Identical | **1:1** | Plus an optional Keychain/Touch ID "remember" affordance (additive) |
| ADD-34 | Empty password | No encryption at all | Identical | **1:1** | |
| ADD-35 | Parameters field | Tokens split on whitespace; a token longer than 2 chars starting with `-m`/`-M` has the `-m` stripped (`-mx=9` ≡ `x=9`); each token splits at the **first** `=`; a token with no `=` becomes a name-only boolean; dialog-derived properties are emitted first so Parameters override them | Identical grammar, identical ordering | **1:1** | |
| ADD-36 | Method-override detection | If any token parses as `0=` for 7z, or starts with `m=` for non-7z, the dialog's own method / dictionary / word-size properties are **not emitted at all** (level, solid, threads, memuse, encryption and timestamps still are) | Identical | **1:1** | |
| ADD-37 | Per-format persistence | The Parameters text and all per-format options are stored per format and restored on switching back | Identical | **1:1** | |
| ADD-38 | OK-time validation order | (1) read password 1 · (2) **zip only**: password must be ASCII 0x20–0x7F else `Use only English letters, numbers and special characters (!, #, $, ...) for password.` · (3) **zip+AES**: length > 99 → `Password is too long` · (4) if Show Password is unchecked, the two fields must match else `Passwords do not match` · (5) memory check: required > limit → the five-line blocked message, OK aborted · (6) resolve the archive path, `Incorrect archive path` on failure · (7) parse volume sizes · (8) persist | Identical order, identical messages, identical abort points | **1:1** | The five-line memory message reproduces `The operation was blocked by 7-Zip.` with ArcSeven named instead |
| ADD-39 | Options summary static | `ShowOptionsString()` builds a compact token list: `tp<N>`, `tm`/`tm-`, `tc`/`tc-`, `ta`/`ta-`, `-stl`/`-stl-`, `SL`, `HL`, `AS`, `Sec`, joined with single spaces | Same mechanism; `AS` becomes `XA` (extended attributes) and `Sec` becomes `ACL` | **Adapted** | Follows [D-04](DIVERGENCES.md#d-04--the-ntfs-group-in-the-add-options-sub-dialog-becomes-a-macos-group) |

### 12.2 Add ▸ Options sub-dialog — `IDD_COMPRESS_OPTIONS` (`CompressOptionsDialog.rc`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| ADO-01 | Caption / buttons | `Options`, with OK / Cancel / Help | Identical | **1:1** | |
| ADO-02 | `NTFS` group | `Store symbolic links` · `Store hard links` · `Store alternate data streams` · `Store file security`. Each checkbox is **hidden** when the handler does not advertise the flag; the groupbox itself hides when none apply (7z: sym+hard+security · wim: alt streams+security+sym+hard · tar: sym+hard · zip/gzip/bzip2/xz: none) | Group renamed **macOS**: `Store symbolic links` · `Store hard links` · `Store extended attributes and resource forks` · `Store POSIX ACLs`. Same per-handler hiding rule | **Adapted** | [D-04](DIVERGENCES.md#d-04--the-ntfs-group-in-the-add-options-sub-dialog-becomes-a-macos-group) |
| ADO-03 | Type info static | Runtime text such as `Type: 7z` / `Type: tar: GNU` | Identical | **1:1** | |
| ADO-04 | `Time` group | Timestamp-precision combo + four `":"` "explicitly set" mini-checkboxes paired with `Store modification time`, `Store creation time`, `Store last access time`, `Set archive time to latest file time`, plus `Do not change source files last access time` | Identical control set and identical pairing semantics | **1:1** | |
| ADO-05 | "Explicitly set" semantics | When the mini-checkbox is off, the paired checkbox is disabled, reset to the handler default, and **nothing is emitted** | Identical | **1:1** | |
| ADO-06 | Precision combo | Only the levels the handler supports: `100 ns : Windows`, `1 sec : Unix`, `2 sec : DOS`, `1 ns : Linux`, plus decimal sub-second entries. Emits `-mtp=<n>` | Identical strings (including `: Windows` / `: DOS`, which describe the on-disk encoding, not the host OS) | **1:1** | |
| ADO-07 | Per-format precision coupling | For zip, a non-Windows precision force-disables creation and access time; for tar, creation/access are disabled except POSIX, which enables access time | Identical | **1:1** | |
| ADO-08 | Emitted switches | `-mtm=`, `-mtc=`, `-mta=`, `-mtp=`, `-stl`, `-ssp`, and the link/stream/security family | Same, with the ACL/xattr switches replacing the NT-security ones | **Adapted** | |

### 12.3 Extract — `IDD_EXTRACT` (`ExtractDialog.rc`, `ExtractDialog.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| EXT-01 | Caption | `Extract`, becoming `Extract : <full archive path>` when exactly one archive is being extracted | Identical | **1:1** | |
| EXT-02 | `E&xtract to:` combo | Editable, destination MRU capped at `kHistorySize = 16` | Identical, cap included | **1:1** | |
| EXT-03 | `...` browse | Folder picker titled `Specify a location for extracted files.` | `NSOpenPanel` with `canChooseDirectories`, same title | **1:1** | |
| EXT-04 | Sub-folder name splitter | The unlabelled checkbox + edit implement "extract into a sub-folder named X": when checked the destination splits into prefix (combo) and name (edit) and is re-joined on OK with a normalised trailing separator; when unchecked the edit is hidden. State persisted | Identical | **1:1** | |
| EXT-05 | Path normalisation | `NormalizeDirPathPrefix()` guarantees a trailing separator; failure to resolve → `Incorrect output directory path` | Identical, with `/` | **1:1** | |
| EXT-06 | Path mode combo | Only **three** entries: `Full pathnames` · `No pathnames` · `Absolute pathnames` | Identical three entries, mapped to `7zz x`, `7zz e`, and `x -spf` | **1:1** | |
| EXT-07 | Sticky `kCurPaths` | `kCurPaths` (used when extracting a selection from inside an open archive) is not selectable; on init it displays as `Full pathnames`, and on OK it is **preserved** if the caller passed it and the user left `Full pathnames` selected | Identical sticky behaviour | **1:1** | An easily-missed quirk; explicitly covered by a unit test |
| EXT-08 | `Eliminate duplication of root folder` | `ElimDup` — when the whole archive sits under one top folder whose name equals the archive base name, that level is dropped. Persisted; shared with the Options ▸ 7-Zip tab | Identical, and the same shared preference | **1:1** | |
| EXT-09 | Overwrite mode combo | `Ask before overwrite` · `Overwrite without prompt` · `Skip existing files` · `Auto rename` · `Auto rename existing files`. `kRename` renames the **incoming** file (`name_1.ext`); `kRenameExisting` renames the **file on disk** and writes the incoming under the original name | Identical five entries and identical semantics: `-aoa`, `-aos`, `-aou`, `-aot`. **Ask** is implemented by ArcSeven (collision pre-scan + the OVR dialog), never by letting `7zz` prompt on stdin | **Adapted (mechanism only)** | The subprocess always runs with `-y`; prompting is ours |
| EXT-10 | Password group | Password edit with `*` masking + `Show Password`; state persisted | Identical, plus optional Keychain storage | **1:1 +** | Password is fed to `7zz` on **stdin**, never on argv, for extract/list/test |
| EXT-11 | `Restore file security` | `IDX_EXTRACT_NT_SECUR` — restores NT ACLs; `CBoolPair` merge where a command-line value wins over the registry | Replaced by `Restore extended attributes and ACLs` | **Adapted** | [D-04](DIVERGENCES.md#d-04--the-ntfs-group-in-the-add-options-sub-dialog-becomes-a-macos-group) |
| EXT-12 | `Restore alternate data streams` | Exists in the header, **commented out** of the resource since 23.00 | Not present | **1:1** | |
| EXT-13 | Buttons | `OK` (default) / `Cancel` / `Help` | Identical | **1:1** | |
| EXT-14 | Quarantine | — (Windows propagates `Zone.Id` per the Options ▸ 7-Zip setting) | Extracted files receive `com.apple.quarantine` per OPT-11 | **Adapted** | [D-08](DIVERGENCES.md#d-08--zoneid-propagation-becomes-comapplequarantine-propagation) |

### 12.4 Overwrite confirmation — `IDD_OVERWRITE` (`OverwriteDialog.rc/.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| OVR-01 | Caption | `Confirm File Replace` | Identical | **1:1** | |
| OVR-02 | Header / question | `Destination folder already contains processed file.` · `Would you like to replace the existing file` · `with this one?` | Identical three strings in the same positions | **1:1** | |
| OVR-03 | Buttons | Top row `&Yes`, `Yes to &All`, `A&uto Rename` (the last is 104 units wide vs 80); bottom row `&No`, `No to A&ll`, `&Cancel` | Same six buttons, same two-row grouping and same order | **1:1** | |
| OVR-04 | Info block | Four lines: directory prefix (with trailing separator) · file name · `"<decimal> bytes"` plus `" : <n> KiB\|MiB\|GiB"` when size ≥ 1024 (GiB at ≥ 10 GiB, MiB at ≥ 10 MiB, else KiB) · `Modified: <UTC time>` | Identical four-line block and identical thresholds | **1:1** | |
| OVR-05 | String reduction | Strings longer than **72** chars are elided at the midpoint (delete `len-72` at position 36, insert `" ... "`); a line ending in a space is wrapped in quotes (anti-spoofing) | Identical, including the quote-wrap | **1:1** | The quote-wrap is a security behaviour, not cosmetic |
| OVR-06 | Icon slots | Slot 1 = shell icon from the **extension only**; slot 2 = the real embedded icon, only for real `.exe`/`.ico` files and only when its image index differs | Slot 1 = `NSWorkspace.icon(for: UTType)`; slot 2 = `NSWorkspace.icon(forFile:)` when it differs (app bundles, `.icns`, custom icons) | **1:1** | |
| OVR-07 | Flags | `ShowExtraButtons` (default true) hides `Yes to All` / `No to All` / `Auto Rename` when false; `DefaultButton_is_NO` makes No default and focused | Identical | **1:1** | |
| OVR-08 | Return mapping | Cancel → `kCancel` (`E_ABORT`) · Yes → `kYes` · No → `kNo` · Yes to All → sets the run's overwrite mode to `kOverwrite` · No to All → `kSkip` · Auto Rename → `kRename` | Identical, applied to the remainder of the operation | **1:1** | |

### 12.5 Password — `IDD_PASSWORD` (`PasswordDialog.rc/.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| PWD-01 | Caption / controls | `Enter password`; `&Enter password:` static, one masked field, `&Show password` checkbox, OK / Cancel. **No confirmation field** | Identical control set | **1:1** | |
| PWD-02 | Show toggle | Reads the current text, flips the mask character, re-sets the text; state round-tripped into the registry | Identical, persisted as `FM.ShowPassword` | **1:1** | |
| PWD-03 | Modality | Raised modally over the Progress dialog (`ProgressDialog->WaitCreating()`), both for extraction and when the compressor needs a password it wasn't given | Sheet attached to the progress window, same trigger points | **1:1** | |
| PWD-04 | Cancel | `E_ABORT` for the whole operation | Identical: cancels the operation, not just the prompt | **1:1** | |
| PWD-05 | Pre-flight detection | — | A pre-flight `l -slt` checks `Encrypted = +` so the prompt appears **before** the operation starts rather than mid-run | **Adapted** | Additive; removes a subprocess-driven stall |
| PWD-06 | Password transport | — | stdin for extract/list/test; **argv for create** (the only path `7zz` supports), with the `ps`-visibility trade-off documented in code | **Adapted** | See ARCHITECTURE §6; M5 removes the argv path |
| PWD-07 | Keychain | — | Optional "Remember this password", keyed on a content fingerprint, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.userPresence` | **Adapted** | Additive, opt-in, never auto-filled for a just-downloaded archive |

### 12.6 Progress — `IDD_PROGRESS` (`ProgressDialog2.rc`, `ProgressDialog2a.rc`, `ProgressDialog2.cpp`)

The ten value fields, in resource order.

| # | Field / feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| PRG-01 | `Elapsed time:` | `HH:MM:SS`, zero-padded; hours ≥ 100 print unpadded; updated only when the whole-second value changes | Identical | **1:1** | |
| PRG-02 | `Remaining time:` | `elapsed × (total − done) / done`, same format; **cleared to empty** when indeterminate | Identical, including the blank-when-indeterminate rule | **1:1** | |
| PRG-03 | `Files:` | Count of files processed | Identical, from the `+ `/`- ` prefixed log lines of `7zz -bb3` | **1:1** | |
| PRG-04 | *(unlabelled)* files total | `" / <total>"` rendered in the value column of row 3 **with no label to its left** | Identical layout | **1:1** | Total from a pre-flight `l -slt` |
| PRG-05 | `Errors:` | Error count | Identical | **1:1** | |
| PRG-06 | `Total size:` | Byte count; raw until 100000 units, then `>>10/20/30` with ` KB`/` MB`/` GB` | Identical thresholds and identical suffixes (` KB`, not ` KiB`) | **1:1** | |
| PRG-07 | `Speed:` | `completedBytes × 1000 / elapsedMs`; ≥ `10000<<10` → ` MB/s`, ≥ 10000 → ` KB/s`, else ` B/s` | Identical | **1:1** | |
| PRG-08 | `Processed:` | Uncompressed bytes done, same size formatting | Identical | **1:1** | |
| PRG-09 | `Compressed size:` | Compressed bytes produced (compression) or read (extraction) | Identical | **1:1** | |
| PRG-10 | `Compression ratio:` | `packSize × 100 / unpackSize`, integer, followed by `%` | Identical | **1:1** | |
| PRG-11 | Status line | `IDT_PROGRESS_STATUS`, `SS_NOPREFIX`. Verb set: `Opening...`, `Scanning...`, `Adding`, `Updating`, `Analyzing`, `Replicating`, `Repacking`, `Skipping`, `Deleting`, `Header creating`, `Removing`, `Extracting`, `Testing`, `Moving...`, `Copying...`, `Renaming...`, `Splitting...`, `Combining...`, `Checksum calculating...`, `Compressing` | Identical verb strings, identical trailing ellipses (some verbs have them, some don't — reproduced) | **1:1** | |
| PRG-12 | File-name line | 24-unit-tall static, `SS_LEFTNOWORDWRAP` — may occupy two lines, never word-wraps | Two-line label with head/middle truncation, no word wrap | **1:1** | |
| PRG-13 | Progress bar | `PBS_SMOOTH` | `NSProgressIndicator`, determinate | **1:1** | Value from `-bsp2` percent ticks interpolated against the pre-flight total |
| PRG-14 | Message list | Report list, no column header, **hidden until the first error**; showing it also reveals the `Errors:` label and value. Two columns: index and message. Multi-line messages split on `\n` into rows | Identical, including hidden-until-first-error | **1:1** | |
| PRG-15 | `&Background` | Default button. Toggles process priority (`IDLE_PRIORITY_CLASS` ↔ `NORMAL_PRIORITY_CLASS`), swaps its own caption to `&Foreground`, and adds a `Backgrounded` marker to the title | Same button and caption swap; priority via `setpriority(PRIO_PROCESS, …)` on the child. **Never** QoS `.background`, which pins work to E-cores | **Adapted** | Mechanism only. See ARCHITECTURE §5.4 |
| PRG-16 | `&Pause` | Toggles paused state, swaps caption to `&Continue`, prefixes the title with `Paused`; elapsed-time accounting excludes paused time | Same button and caption swap; `SIGSTOP`/`SIGCONT` to the child process group; identical elapsed-time accounting | **Adapted** | Mechanism only |
| PRG-17 | `Cancel` | Auto-pauses first, then asks `Are you sure you want to cancel?` (Yes/No/Cancel) titled with the operation; Yes stops, otherwise resume | Identical, then `SIGINT` to the child's process group and pipes drained to EOF | **1:1** | |
| PRG-18 | Window title | `[<pct>%] [Paused] [Backgrounded] [<MainAddTitle>] <title> [<fileName>]` | Identical composition | **1:1** | |
| PRG-19 | On completion | Cancel is relabelled `&Close` and becomes the default; `Background` and `Pause` are **hidden**; hash results render here; if `ErrorMessage` is set a `MB_ICONERROR` box appears; else if there were **no** list messages and an `OkMessage` exists, an OK box appears; if there **were** messages, the dialog stays open until Close | Identical, with the alerts as sheets on the progress window | **1:1** | |
| PRG-20 | Test OK message | `Archives: <n>` / `Packed Size: <bytes> bytes : <n> KiB\|MiB\|GiB` / `[Folders: <n>]` / `Files: <n>` / `Size: …` / `[Alternate Streams…]` / blank / `There are no errors` | Identical block | **1:1** | |
| PRG-21 | Error message texts | `Unsupported compression method`, `Data error`, `CRC failed`, `Unavailable data`, `Unexpected end of data`, `There are some data after the end of the payload data`, `Is not archive`, `Headers Error`, `Wrong password`, `Error #<n>`; rendered `"<reason> : <path>"` with `" : Wrong password?"` inserted before the path for encrypted items when the reason isn't already Wrong password | Identical strings and identical composition | **1:1** | |
| PRG-22 | Modality | Modal | **Non-modal**, plus `NSDockTile` progress and a completion notification when not frontmost | **Adapted** | [D-24](DIVERGENCES.md#d-24--the-progress-window-is-non-modal) |
| PRG-23 | Exit-code handling | — | `0` ok · `1` **warning, still succeeded** (surface the warnings, do not fail) · `2` fatal · `7` bad command line · `8` out of memory · `255` cancelled | **Adapted** | Engine-specific; `1 = warning` is the classic mis-handling and is explicitly tested |

### 12.7 Memory-usage request — `IDD_MEM` (`MemDialog.rc`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MEM-01 | Caption / message | `Memory usage request`; message assembled from `The operation requires big amount of memory (RAM).` plus required size, allowed limit, the 7-Zip-set limit, and RAM size | Identical, with ArcSeven named in place of 7-Zip | **1:1** | |
| MEM-02 | Controls | `Change allowed limit for next operations` checkbox + spin edit (default `4`) + `GB` static; `Action` groupbox with `&Allow archive unpacking` / `&Skip archive unpacking` radios and `&Repeat selected action for current operation`; `Continue` / `Cancel` | Identical control set and order | **1:1** | |
| MEM-03 | Skip result | `Archive extraction was skipped.` | Identical | **1:1** | |

### 12.8 Copy / Move — `IDD_COPY` (`CopyDialog.rc`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| CPY-01 | Caption / label | `Copy` / `Move`; static `Copy to:` / `Move to:` | Identical | **1:1** | |
| CPY-02 | Destination combo | Editable, dropdown = copy history (`FM\CopyHistory`), `...` browse | Identical, `FM.CopyHistory` | **1:1** | |
| CPY-03 | Info block | `Folders: <n> <size>` / `Files: <n> <size>` / `Size: <sum>` (only when both sizes are known and non-zero) / current folder prefix / indented relative paths, truncated with a trailing `...` beyond the line budget | Identical assembly | **1:1** | |
| CPY-04 | Path resolution | Empty → `Operation is not supported.`; `CorrectFsPath` failure → `E_INVALIDARG`; a non-absolute path is appended to the source pane's path; a leading single `\` (not `\\`) is rejected | Identical, with `/`; the leading-separator rule becomes "a path starting with `/` is absolute", so no rejection case exists | **Adapted** | Windows UNC-specific |
| CPY-05 | Move pre-check | `CheckBeforeUpdate(IDS_MOVE)` fails if any folder in the parent chain is read-only; copy requires `DoesItSupportOperations()` else `Operation is not supported.` | Identical | **1:1** | |
| CPY-06 | Alt-stream destinations | Allowed **only** into an alt-streams folder open in the second pane | Same rule for the xattr pseudo-folder | **Deferred** | Follows MF-22 |
| CPY-07 | Read-only error block | Four lines: operation name / `Operation is not supported.` / path of the read-only level / `Read-only` | Identical | **1:1** | |

### 12.9 Split / Combine — `IDD_SPLIT` (`SplitDialog.rc`, `SplitUtils.cpp`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| SPL-01 | Split dialog | Caption `Split File`; `&Split to:` editable combo + `...`; `Split to &volumes,  bytes:` (double space in the shipped resource) + editable combo with the ADD-25 presets and grammar; OK / Cancel | Identical controls; the double space is **fixed** | **Adapted** | [D-25](DIVERGENCES.md#d-25--shipped-string-typos-are-fixed) |
| SPL-02 | Confirmation | `Confirm Splitting` / `Are you sure you want to split file into {0} volumes?` | Identical | **1:1** | |
| SPL-03 | Errors | `Volume size must be smaller than size of original file`, `Incorrect volume size` | Identical | **1:1** | |
| SPL-04 | Progress title | `Splitting...` | Identical | **1:1** | |
| SPL-05 | Combine dialog | Caption `Combine Files`, label `&Combine to:`; errors `Select only first part of split file`, `Cannot detect file as split file`, `Cannot find more than one part of split file`; progress `Combining...` | Identical | **1:1** | |

### 12.10 Create Folder / Create File / Select mask — `IDD_COMBO` (`ComboDialog.rc`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| CMB-01 | Create Folder | Title `Create Folder`, static `Folder name:`, default `New Folder`, error title `Error Creating Folder` | Identical | **1:1** | |
| CMB-02 | Create File | Title `Create File`, static `File Name:`, default `New File`, error title `Error Creating File` | Identical | **1:1** | Note the inconsistent capitalisation of `File Name:` versus `Folder name:` — reproduced |
| CMB-03 | Name validation | Rejects a last component of `.` or `..` (`E_INVALIDARG`); sub-paths are allowed (`CreateComplexDir`); after creation only the first path component is focused/selected | Identical, plus rejection of an embedded `/` | **1:1** | |
| CMB-04 | Hash folders | Neither command is available | Identical | **1:1** | |
| CMB-05 | Select / Deselect mask | Titles `Select` / `Deselect`, static `Mask:`, default `*`, editable combo with history | Identical | **1:1** | |

### 12.11 Delete confirmations

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| DEL-01 | One file | Title `Confirm File Delete`, text `Are you sure you want to delete '{0}'?` | Identical | **1:1** | |
| DEL-02 | One folder | Title `Confirm Folder Delete`, text `Are you sure you want to delete the folder '{0}' and all its contents?` | Identical | **1:1** | |
| DEL-03 | Multiple | Title `Confirm Multiple File Delete`, text `Are you sure you want to delete these {0} items?` | Identical | **1:1** | |
| DEL-04 | Destination | `SHFileOperation` with `FOF_ALLOWUNDO` (Recycle Bin) unless Shift; long paths fall back with `The system cannot move a file with long path to the Recycle Bin` | `NSWorkspace.recycle(_:)` (Trash) by default; `⌥⌘⌫` deletes permanently. No long-path failure mode exists on macOS | **Adapted** | [D-03](DIVERGENCES.md#d-03--delete-moves-to-the-trash-by-default) |
| DEL-05 | Inside an archive | Deletes the entry outright | There is no Trash inside an archive: `⌘⌫` removes the entry permanently, with distinct confirmation wording that says so | **Adapted** | [D-03](DIVERGENCES.md#d-03--delete-moves-to-the-trash-by-default) |
| DEL-06 | Error title / progress | `Error Deleting File or Folder`; progress title `Deleting...` | Identical | **1:1** | |

### 12.12 Diagnostic messages — `IDD_MESSAGES`

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| MSG-01 | Dialog | Caption `7-Zip: Diagnostic messages`, 2-column list, `&Close`. **No code path instantiates it in 24.x–26.x** — errors surface in the Progress dialog's embedded list | Not shipped | **Dropped** | [D-10](DIVERGENCES.md#d-10--the-diagnostic-messages-dialog-is-dropped) |
| MSG-02 | Empty case | `There are no errors` | String retained; used by the Test result block (PRG-20) | **1:1** | |

---

## 13. Benchmark — `IDD_BENCH` (`BenchmarkDialog.rc`)

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| BCH-01 | Window | Caption `Benchmark`; resizable **and minimizable**; a 140-unit log column occupies the right edge | Same window, same resizability, same log column | **1:1** | |
| BCH-02 | Inputs | `&Dictionary size:` combo · `Memory usage:` + computed value · `&Number of CPU threads:` combo · hardware-threads description · `Passes:` combo + passes-completed value · `Elapsed time:` + value | Identical control set and order | **1:1** | |
| BCH-03 | Results grid headers | `Size`, `Speed`, `CPU Usage`, `Rating / Usage`, `Rating`, all right-aligned | Identical | **1:1** | |
| BCH-04 | `Compressing` group | Rows `Current` and `Resulting` across all five columns | Identical | **1:1** | |
| BCH-05 | `Decompressing` group | Rows `Current` and `Resulting` across all five columns | Identical | **1:1** | |
| BCH-06 | `Total Rating` group | Only three of the five columns are populated: total CPU usage, total rating/usage, total rating | Identical | **1:1** | |
| BCH-07 | Error line | Right-aligned full-width error static; errors here typically indicate defective RAM | Identical, with the same interpretation in the help text | **1:1** | |
| BCH-08 | System block | CPU brand string · version · CPU feature flags · two system-info lines · the running log column | Same fields; CPU brand from `machdep.cpu.brand_string`, features from `hw.optional.*`, and the **P-core / E-core split** added to the hardware-threads line | **1:1 +** | Additive detail on the same line |
| BCH-09 | Buttons | `&Restart` (top-right), `&Stop` (directly below), `&Help` and `Cancel` on the bottom row | Identical | **1:1** | |
| BCH-10 | Metric semantics | Ratings in MIPS normalised against a single-threaded Intel Core 2; `CPU Usage` normalised to a one-thread load; `Rating / Usage` = rating at 100 % usage; `Total Rating` = average of compression and decompression | Identical definitions, values produced by `7zz b` | **1:1** | |
| BCH-11 | Timer suspension | Both panels' auto-refresh timers are disabled for the duration | Identical | **1:1** | |

---

## 14. Options / Settings — the six tabs

Page order is fixed: `System`, `7-Zip`, `Folders`, `Editor`, `Settings`, `Language`
(`OptionsDialog.cpp`). ArcSeven keeps all six as toolbar items in a macOS Settings window, in the same
order, with the second renamed.

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| OPT-01 | Sheet title / placement | Property sheet titled `Options`, reached from Tools ▸ Options… | Settings window, `⌘,`, in the app menu | **Adapted** | MT-01 |
| OPT-02 | Post-OK actions | Reload menu + toolbars if the language changed, then `SetListSettings()` and `RefreshAllPanels()` | Identical refresh chain | **1:1** | |
| **Tab 1 — `System`** (`SystemPage.rc`) | | | | | |
| OPT-03 | Purpose | `Associate 7-Zip with:` — a report list of archive extensions with two value columns (current user / all users), editing the **registry** file associations | **LaunchServices**: the same extension list, with the current-app column driven by `LSCopyDefaultRoleHandlerForContentType` / `LSSetDefaultRoleHandlerForContentType(_:role:)` keyed on the UTI for each extension | **Adapted** | [D-06](DIVERGENCES.md#d-06--the-options-system-tab-becomes-launchservices-default-app-handling) |
| OPT-04 | Per-cell state | Four states: blank (no association) · `AppName` (another program) · `[7-Zip]` (a *different* 7-Zip installation) · `7-Zip` (this copy) | Same four states: blank · other app's display name · `[ArcSeven]` (a different ArcSeven bundle) · `ArcSeven` (this bundle, matched by bundle URL) | **1:1** | The four-state model maps cleanly |
| OPT-05 | `+` current-user button | Bulk-toggles association for the current user; caption replaced at runtime with the user's name | Same button, same bulk behaviour | **1:1** | |
| OPT-06 | `+` all-users button | Bulk-toggles for **All users**; requires administrator rights | — | **Dropped** | macOS has no system-wide default-handler API; LaunchServices is per-user. [D-06](DIVERGENCES.md#d-06--the-options-system-tab-becomes-launchservices-default-app-handling) |
| OPT-07 | Extension list source | A fixed list of known archive extensions | Derived from `CFBundleDocumentTypes` + the imported UTI declarations, so the list and the app's actual claims cannot drift apart | **Adapted** | |
| **Tab 2 — `7-Zip`** (`MenuPage2.rc`), renamed **`Integration`** | | | | | |
| OPT-08 | `Integrate 7-Zip to shell context menu` | Registers/unregisters the Explorer shell extension; on 64-bit Windows the caption gains ` (64-bit)` | `Enable Finder integration` — reports `FIFinderSyncController.isExtensionEnabled` and opens the system management UI via `showExtensionManagementInterface()`; a diagnostics row offers the `pluginkit -e use -u <UUID>` fallback | **Adapted** | [D-11](DIVERGENCES.md#d-11--shell-extension-registration-becomes-a-finder-sync-extension-toggle) |
| OPT-09 | `(32-bit)` | Second checkbox for the 32-bit shell extension on 64-bit Windows | — | **Dropped** | No macOS analogue |
| OPT-10 | `Cascaded context menu` / `Icons in context menu` | Groups all verbs under one `7-Zip ▸` submenu; draws `MenuLogo.bmp` beside each verb | Same two toggles, driving `setSubmenu(_:for:)` and `NSMenuItem.image` in the Finder Sync extension | **1:1** | Submenus and item icons in a Finder Sync menu are supported despite the common claim otherwise |
| OPT-11 | `Propagate Zone.Id stream:` | Combo: `* No` (0, default) · `Yes` (1) · `For Office files` (2), plus a raw numeric entry when the registry holds ≥ 3 | `Propagate quarantine flag:` with the same three entries, writing `com.apple.quarantine` onto extracted files. `For Office files` becomes "for documents and executables" (types conforming to `public.executable`, `public.script`, or the Office UTIs) | **Adapted** | [D-08](DIVERGENCES.md#d-08--zoneid-propagation-becomes-comapplequarantine-propagation) |
| OPT-12 | `Eliminate duplication of root folder` | Shared with the Extract dialog | Identical, same shared preference | **1:1** | |
| OPT-13 | `Context menu items:` checklist | Checkbox list, no header, single 200-unit column, in this exact order: `Open archive`, `Open archive >`, `Extract files...`, `Extract Here`, `Extract to <Folder>`, `Test archive`, `Add to archive...`, `Add to <Archive>.7z`, `Add to <Archive>.zip`, `Compress and email...`, `Compress to <Archive>.7z and email`, `Compress to <Archive>.zip and email`, `CRC SHA >`, `7-Zip > CRC SHA >` | Same list, same order, minus the three email rows | **Adapted** | Email rows are `#ifdef EMAIL_SUPPORT` on Windows; the macOS equivalent is the system Share menu, offered as a separate row |
| **Tab 3 — `Folders`** (`FoldersPage2.rc`) | | | | | |
| OPT-14 | Working folder | Radios `&System temp folder` (default) / `&Current` / `Specified:` + path edit + `...` (browse title `Specify a location for temporary archive files.`), plus `Use for removable drives only` | Identical control set, defaults and browse title | **1:1** | "Removable" = volumes where `volumeIsRemovableKey` or `volumeIsEjectableKey` is true |
| **Tab 4 — `Editor`** (`EditPage2.rc`) | | | | | |
| OPT-15 | Three path triplets | `&View:` / `&Editor:` / `&Diff:`, each label + edit + `...` | Identical three rows | **1:1** | Stored as `FM.Viewer`, `FM.Editor`, `FM.Diff` |
| OPT-16 | Empty-value behaviour | An unset Viewer/Editor means the command fails with `Cannot start editor.` | An unset Viewer falls back to Quick Look and an unset Editor to the LaunchServices default | **Adapted** | Strictly more useful; the explicit paths still win |
| OPT-17 | Diff unlocks "super mode" | Setting a Diff path makes `File ▸ Diff` visible and enables the extra commands | Identical gating for `File ▸ Diff` | **1:1** | The version-control extras it also gated are dropped (MF-28) |
| **Tab 5 — `Settings`** (`SettingsPage2.rc`, defaults from `RegistryUtils.cpp` `CFmSettings::Load`) | | | | | |
| OPT-18 | `Show ".." item` | Checkbox, **default off** | Identical, default off | **1:1** | See DOT-01 |
| OPT-19 | `Show real file &icons` | Checkbox, **default off** — per-file icon extraction instead of per-extension | Identical: off → `NSWorkspace.icon(for: UTType)`; on → `NSWorkspace.icon(forFile:)` | **1:1** | |
| OPT-20 | `&Full row select` | Checkbox, **default off** (so clicks on other columns remain usable — an explicit upstream comment) | — | **Dropped** | `NSTableView` is always full-row and has no other mode. [D-29](DIVERGENCES.md#d-29--full-row-select-is-dropped-nstableview-has-no-other-mode) |
| OPT-21 | `Show &grid lines` | Checkbox, **default off** | Identical (`NSTableView.gridStyleMask`) | **1:1** | |
| OPT-22 | `&Single-click to open an item` | Checkbox, **default off** | Identical | **1:1** | |
| OPT-23 | `&Alternative selection mode` | Checkbox, **default off** — Norton-style marks, single OS selection | Identical model and default | **1:1** | See KEY-28/29 |
| OPT-24 | `Show system &menu` | Checkbox, **default off** | Same checkbox, same default, controlling the `Finder ▸` submenu | **Adapted** | MF-25 |
| OPT-25 | `Use &large memory pages` | Checkbox; needs admin + `SeLockMemoryPrivilege` | — | **Dropped** | [D-12](DIVERGENCES.md#d-12--use-large-memory-pages-is-dropped) |
| OPT-26 | RAM limit | `Maximum amount of RAM memory usage allowed to unpack archives:` label + an unlabelled enabling checkbox + spin edit (initial text `4`) + `GB` | Identical control set and initial value | **1:1** | Feeds MEM-01 |
| **Tab 6 — `Language`** (`LangPage.rc`) | | | | | |
| OPT-27 | Language combo | Unsorted drop-list populated from `Lang/*.txt`; English shows as `English`, other locales as `English name (Native name)` | Kept structurally, populated from the bundle's String Catalogs; **English only at v1.0** | **Deferred** | [D-26](DIVERGENCES.md#d-26--the-language-tab-ships-structurally-with-one-entry) |
| OPT-28 | Info static | Runtime-filled translator credits / completeness block | Identical field, filled from catalog metadata | **Deferred** | |
| OPT-29 | Apply behaviour | Changing the language triggers a full menu rebuild, toolbar reload, sub-window move and lang-item reload | Identical refresh chain | **1:1** | |

---

## 15. The Explorer shell context menu → Finder integration

Windows behaviour from `Explorer/ContextMenu.cpp` and `Explorer/resource2.rc`.

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| SHL-01 | Mechanism | An in-process shell extension DLL registered per-user or per-machine, injected into `explorer.exe` | **Three surfaces shipped together**, because macOS has no single equivalent: (1) a `FIFinderSync` app extension claiming `/` (and `/Volumes` behind a preference), (2) an `NSServices` submenu, (3) App Intents-backed Quick Actions | **Adapted** | [D-11](DIVERGENCES.md#d-11--shell-extension-registration-becomes-a-finder-sync-extension-toggle) |
| SHL-02 | Cascaded vs inline | Cascaded on by default: everything inside one `7-Zip ▸` popup. Off: a separator then all verbs inline | Same preference; cascaded uses `setSubmenu(_:for:)` | **1:1** | |
| SHL-03 | Icons | `MenuLogo.bmp` attached to every item when enabled | `NSMenuItem.image` with the app's template glyphs | **1:1** | |
| SHL-04 | `Open archive` / `Open archive ▸` | Shown only when exactly one non-directory file is selected and it looks extractable. The submenu children are, verbatim, the main label then `*`, `#`, `#:e`, `7z`, `zip`, `cab`, `rar` | Same items, same order, same literal `*` / `#` / `#:e` labels | **1:1** | These map to `-t*`, `-t#`, `-t#:e`, `-t7z`, … |
| SHL-05 | `Extract files...` | Opens the Extract dialog with `baseFolder + specFolder` | Identical | **1:1** | |
| SHL-06 | `Extract Here` | Extracts into `baseFolder` | Identical | **1:1** | |
| SHL-07 | `Extract to "<name>\"` | Label from `Extract to {0}` formatted with the sub-folder name (`archive/` from `archive.zip`), or `*\` for a multi-selection | Identical, with `/` and `*/` | **1:1** | |
| SHL-08 | `Test archive` | Integrity test | Identical | **1:1** | |
| SHL-09 | Compress group | `Add to archive...`, `Add to "<name>.7z"`, `Add to "<name>.zip"`, each suppressed if the generated name equals the source name; email variants are `#ifdef EMAIL_SUPPORT` | Same three items and the same suppression rule; the email variants become a `Share…` item | **Adapted** | OPT-13 |
| SHL-10 | ≥ 16 items | Explorer's item list is reduced to the first 16 for name generation and `_` is appended to the shown name as a hint that the final name may differ | Identical cap and identical `_` hint | **1:1** | |
| SHL-11 | `CRC SHA ▸` | Placed inside `7-Zip ▸` when cascaded and the `kCRC_Cascaded` flag is set, otherwise at the top level. Children: the ten hashers, `*`, a separator, `SHA-256 -> <name>.sha256`, `Test archive : Checksum` | Identical structure, order and labels | **1:1** | Upstream comment notes CRC SHA is never hidden inside the File Manager itself |
| SHL-12 | Verb naming | `SevenZip.Open`, `SevenZip.OpenWithType.*`, `SevenZip.Checksum.Calc.<Method>`, `…Generate.SHA256`, `…Test.Hash` | Internal command identifiers mirror this taxonomy so the mapping stays auditable | **1:1** | Not user-visible |
| SHL-13 | Extension enablement | The DLL is registered at install time and works immediately | The appex registers only after the containing app has been **launched once**, and the user must enable it in System Settings; the app's onboarding says so and links to the management UI | **Adapted** | Platform requirement, not a choice |
| SHL-14 | Directory scope | Global | Only inside claimed `directoryURLs`; `/` is claimed by default, `/Volumes` behind a preference. Collisions with other broadly-claiming extensions are possible and the diagnostics panel reports them | **Adapted** | |
| SHL-15 | Work location | Extraction runs in the shell extension's host process | The appex **only** builds menus and badges; every action is handed to the app over an authenticated App-Group/XPC transport. No `7zz` is ever spawned inside the appex | **Adapted** | Security and lifetime requirement |
| SHL-16 | Shell strings | `<Folder>`, `<Archive>`, `Open archive`, `Extract files...`, `Add to archive...`, `Test archive`, `Extract Here`, `Extract to {0}`, `Add to {0}`, `You must select one or more files` | Identical strings | **1:1** | |

---

## 16. Nested-archive browsing

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| NST-01 | Level model | Each archive level pushes a `CFolderLink` onto `_parentFolders`; the panel's folder is the handler's `IFolderFolder`; `_currentFolderPrefix` accumulates `…\archive.zip\sub\` | Identical: a stack of archive levels, prefix accumulation with `/` | **1:1** | |
| NST-02 | Opening an inner archive | `OpenItemInArchive(index, tryInternal, tryExternal, editMode, useEditor, type)`; a temp directory is created with prefix **`7zO`**; where the entry can be streamed, a sub-stream is opened **without a full extraction**, otherwise the entry is extracted to the temp dir first | Same two-path model. In v1 (subprocess engine) the inner entry is extracted to a `7zO`-prefixed staging dir; from M5 the XPC engine opens it as a true sub-stream | **1:1 (M5) / Adapted (v1)** | The user-visible behaviour is identical; only the I/O path differs |
| NST-03 | Temp-dir prefixes | Two distinct prefixes: `7zE` for extraction staging (`App.cpp`) and `7zO` for open/edit staging (`PanelItemOpen.cpp`). The Browse-Temp-Files dialog scans `7zO*.tmp` | Same two prefixes, same scan target | **1:1** | |
| NST-04 | `Open Inside *` / `#` | Pass `"*"` / `"#"` as the type string, forcing the handler-selection strategy | Pass through as `-t*` / `-t#` | **1:1** | |
| NST-05 | Leaving a level | `OpenParentFolder()` pops; if the archive was modified, the write-back prompt fires first (TMP-08) | Identical | **1:1** | |
| NST-06 | Read-only propagation | `IsThereReadOnlyFolder()` walks the **entire** parent chain — if any ancestor is read-only, update commands are disabled at every nested level | Identical | **1:1** | |
| NST-07 | Context-menu guard | The 7-Zip and system menu injection is skipped inside archives (`CreateSystemMenu` is very slow inside a large ZIP) | Identical guard | **1:1** | |
| NST-08 | Failure messages | `Cannot open file '{0}' as archive` · `Cannot open encrypted archive '{0}'. Wrong password?` · `Unsupported archive type` · `Cannot open the file as {0} archive` · `The file is open as {0} archive` · `The archive is open with offset` | Identical strings | **1:1** | |

---

## 17. Temp-file open / edit / write-back

The most intricate behaviour in 7zFM (`PanelItemOpen.cpp`). Reproduced in full, deliberate leak
included.

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| TMP-01 | Staging | Create `%TEMP%\7zO<random>.tmp`, extract the single entry into it | `NSFileManager.temporaryDirectory` + `7zO<random>` staging dir | **1:1** | |
| TMP-02 | Snapshot | Record `FilePath`, `RelPath`, `FullPathFolderPrefix`, `FileIndex`, **the file's size and timestamps at extraction time**, `UsePassword`, `Password`, `ReadOnly`, owning window | Identical record | **1:1** | |
| TMP-03 | Launch | Viewer / Editor for View / Edit, otherwise `ShellExecute` | Configured Viewer / Editor, otherwise `NSWorkspace.open(_:configuration:)` | **1:1** | |
| TMP-04 | Watcher | A thread waits on the launched process handles plus an app-exit event (up to 60 handles). If a helper re-launches, it tries to find the *real* editor process by the temp file path — but only within the first **2 seconds**, and only if the file hasn't already changed. `isComplexMode` is set when the launched process died almost immediately, i.e. it probably delegated | `DispatchSource` file-system monitor (`.write`, `.attrib`, `.rename`) on the temp file **plus** `NSWorkspace.didTerminateApplicationNotification`. The 2-second delegation window is preserved as the interval during which an immediate termination is treated as a hand-off rather than a completion | **Adapted** | Same semantics, no handle-wait loop. macOS editors hand off far more often than Windows ones, so the FS watcher is the primary signal and process termination is the secondary one |
| TMP-05 | Change detection | Compare size **and** timestamps against the snapshot | Identical comparison | **1:1** | |
| TMP-06 | Read-only archive | A stop-icon box: `Cannot update file` / `'<temp path>'` / `Read-only` / `<archive folder prefix>`, and the temp file is **not** deleted | Identical message block and identical retention | **1:1** | |
| TMP-07 | Write-back prompt | `File '<relative path>' was modified.` / `Do you want to update it in the archive?`, Yes/No/Cancel. **Yes** performs the update on the **UI thread**; anything other than success shows `Cannot update file`. If the answer is No/Cancel, or nothing changed, the thread waits for app exit and then deletes the staging dir **only when the file was NOT modified** — modified-but-declined temp files are deliberately left on disk | Identical prompt, identical main-actor update (`7zz a` / `u` against the archive), and **the same deliberate retention** | **1:1** | This is why `Tools ▸ Delete Temporary Files…` exists (MT-04). It is reproduced, not "fixed" |
| TMP-08 | Leaving a modified archive | `OpenParentArchiveFolder` applies the same prompt before popping the level | Identical | **1:1** | |
| TMP-09 | Cleanup on exit | Waits `INFINITE` per watcher on a clean exit, 100 ms each on a hard exit | Same policy: awaited on `applicationShouldTerminate`, bounded on force-quit | **1:1** | |

---

## 18. Properties and Comment

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| PRP-01 | Presentation | The generic `IDD_LISTVIEW` dialog configured with title `Properties`, 2 columns, full-row select (`PanelMenu.cpp` `CPanel::Properties`) | A **non-modal inspector** with the same two-column list that follows the selection | **Adapted** | [D-27](DIVERGENCES.md#d-27--properties-is-a-non-modal-inspector) |
| PRP-02 | Plain filesystem folders | If the folder does not expose `IGetFolderArcProps`, 7zFM invokes the **shell's** own properties verb instead | ArcSeven always renders its own inspector, and offers `Get Info in Finder` in the `Finder ▸` submenu | **Adapted** | Rendering our own is strictly more consistent |
| PRP-03 | Single-item content | Every property the folder exposes for that item in the handler's declared order, then every **raw** property, then a `------------------------` separator. `kpidNtSecure` decodes to an SDDL-like string; raw blobs > 256 bytes render as `data:<size>`; `CRC`/`Checksum` ≤ 8 bytes render **UPPERCASE** hex, everything else lowercase | Identical order and identical rendering rules; the ACL analogue renders as the `ls -le` ACL text | **1:1** | |
| PRP-04 | Multi-item content | A row `"" : "<n> object(s) selected"`, then `Folders`, `Files`, `Size`, `Packed Size` totals, then a separator | Identical | **1:1** | |
| PRP-05 | Folder + archive levels | `Path` and the folder-level properties, then for each archive nesting level (outermost first) a separator followed by the fixed special set `Path, Type, Error Type, Error, Errors, Warning, Warnings, Offset, Physical Size, Tail Size` and then every declared archive property. When `kpidErrorType` is present an extra first row `Open WARNING:` → `Cannot open the file as expected archive type` is inserted. `ErrorFlags`/`WarningFlags` expand to readable text and are omitted when zero | Identical assembly, identical separators (`----------------` between levels, `------------------------` between sections) | **1:1** | |
| PRP-06 | Value truncation | Values longer than **1024** chars are truncated with `" ..."`; `\r\n` and `\n` become a space so each property is one line | Identical | **1:1** | |
| PRP-07 | List behaviour | `Enter` / `Alt+Enter` / double-click opens a read-only multi-line viewer captioned with the property name; `Ctrl+C` / `Ctrl+Insert` copies selected rows as `Name: Value\r\n`; `Ctrl+A` selects all; `Delete` removes rows only where `DeleteIsAllowed` | Same behaviours with `Return`, `⌘C` (writing `Name: Value\n`), `⌘A`, `⌫` | **Adapted** | Line endings normalised to `\n` |
| CMT-01 | Comment command | `File ▸ Comment…` requires a focused item that is not `..`, a writable archive, and is disabled for Hash folders | Identical preconditions | **1:1** | |
| CMT-02 | Silent abort | If `kpidComment` is neither `VT_BSTR` nor `VT_EMPTY`, the command **silently aborts** — so the pane opens only for handlers exposing a per-item string comment | Identical silent abort | **1:1** | Deliberately reproduced |
| CMT-03 | Dialog | The generic combo dialog titled `<relative item path> : Comment`, static `&Comment:`, value = the current comment (single line) | Identical | **1:1** | |
| CMT-04 | Write-back | `SetProperty(index, kpidComment, …)`; `E_NOINTERFACE` maps to `Operation is not supported.`, anything else to an error box titled literally `Set Comment Error` | Identical, implemented as `7zz` archive update; identical error titles | **1:1** | |
| CMT-05 | Archive-level ZIP comment | 7zFM has **no editor** for it; it surfaces read-only as the `Comment` property | Identical: read-only | **1:1** | |

---

## 19. The `..` row and selection model

| # | Feature | Windows 7zFM behaviour (source) | macOS mapping | Fidelity | Note |
|---|---|---|---|---|---|
| DOT-01 | Visibility | Shown only when Settings ▸ `Show ".." item` is on — **default off** — and **never** in the root folder | Identical, default off | **1:1** | Frequently surprising, deliberately preserved |
| DOT-02 | Name | Literally `..` | Identical | **1:1** | |
| DOT-03 | Ordering | Always first, in both directions (SRT-01) | Identical | **1:1** | |
| DOT-04 | Exclusions | Excluded from Select All / Insert / Shift+arrow, and from Copy / Move / Delete | Identical | **1:1** | |
| DOT-05 | Auto-selection | When shown and the focused position is 0, the `..` row is auto-selected on refresh | Identical | **1:1** | |
| DOT-06 | Activation | Opens the parent folder | Identical | **1:1** | |
| SEL-01 | Operated set | `Get_ItemIndices_Operated()` = the marked items, or the focused item when nothing is marked | Identical definition, used by every operation and by SB-01 | **1:1** | |
| SEL-02 | Alternative selection mode | Adds single-selection to the list control while 7-Zip maintains its own mark vector; `Insert` toggles and advances; `Shift+arrow` sweeps with the polarity of the first item touched | Identical model | **1:1** | |

---

## 20. Persistence map

Windows stores everything under `HKCU\Software\7-Zip`. ArcSeven uses `NSUserDefaults` under
`com.havokentity.ArcSeven` and **keeps the upstream key names**, so the persistence model stays
auditable against the original.

| # | Windows value | Contents | ArcSeven default key | Fidelity | Note |
|---|---|---|---|---|---|
| PST-01 | `FM\Position` | window rect + maximized flag | `FM.Position` (+ frame autosave) | **Adapted** | |
| PST-02 | `FM\Panels` | numPanels, currentPanel, splitterPos | `FM.Panels` | **1:1** | Same validation (PAN-03) |
| PST-03 | `FM\Toolbars` | toolbar bitmask | `FM.Toolbars` | **1:1** | Same bit layout (TB-09) |
| PST-04 | `FM\ListMode` | view mode per panel, one byte each | `FM.ListMode` | **1:1** | |
| PST-05 | `FM\PanelPath0/1` | last folder per panel | `FM.PanelPath0` / `FM.PanelPath1` | **1:1** | |
| PST-06 | `FM\FolderHistory` | Folders History | `FM.FolderHistory` | **1:1** | |
| PST-07 | `FM\FolderShortcuts` | the 10 favourites | `FM.FolderShortcuts` | **1:1** | |
| PST-08 | `FM\CopyHistory` | copy/move destination MRU | `FM.CopyHistory` | **1:1** | |
| PST-09 | `FM\FlatViewArc0/1` | per-panel flat-view-in-archive | `FM.FlatViewArc0` / `1` | **1:1** | |
| PST-10 | `FM\ShowDots`, `ShowRealFileIcons`, `FullRow`, `ShowGrid`, `SingleClick`, `AlternativeSelection`, `ShowSystemMenu` | Settings tab | Same names under `FM.`, except `FullRow`, whose name is reserved and never written | **Adapted** | Names read through `Support/Defaults.swift`; `FullRow` dropped per [D-29](DIVERGENCES.md#d-29--full-row-select-is-dropped-nstableview-has-no-other-mode) |
| PST-11 | `FM\Viewer`, `Editor`, `Diff` | Editor tab | `FM.Viewer`, `FM.Editor`, `FM.Diff` | **1:1** | |
| PST-12 | `FM\Columns\<FolderTypeID>` | per-folder-type column order, widths, visibility, sort column + direction | `FM.Columns.<FolderTypeID>` | **1:1** | |
| PST-13 | `Lang` | selected language file | `Lang` | **Deferred** | OPT-27 |
| PST-14 | `LargePages` | large-page toggle | — | **Dropped** | OPT-25 |
| PST-15 | `Options\…` | shell-integration flags, cascaded, icons, ElimDup, WriteZone | `Options.*`, with `WriteZone` → quarantine mode | **Adapted** | OPT-08…OPT-12 |
| PST-16 | *(none)* | — | `Shortcuts.Preset` (`finder` / `commander` / `custom`) and `Shortcuts.Custom` | **Adapted** | New key required by [D-01](DIVERGENCES.md#d-01--the-default-keymap-is-mac-native-not-f5f6f7) |

---

## 21. Deliberately preserved quirks

These look like bugs. They are the shipped behaviour, and ArcSeven reproduces them on purpose.
Each is cross-referenced above.

1. The title bar is *only* the path — no app name, no filename decoration (WIN-01).
2. The default is **one** pane, not two (PAN-02).
3. `Show ".." item` is **off** by default (DOT-01), so a fresh install shows no `..` row.
4. Folders always sort before files and `..` always sorts first — neither is inverted by descending order (SRT-01, SRT-02).
5. The View menu's sort radio falls back to "Name" for any column outside Name/Type/Date/Size/Unsorted (MV-06).
6. Toolbar buttons are never disabled on Windows — failures are reported after the click (TB-08; adapted, restorable).
7. Modified temp files are deliberately left on disk when the write-back is declined (TMP-07).
8. Two entries in the property-name table both render as `Errors` (§6.1).
9. The Extract dialog's sticky `kCurPaths` behaviour (EXT-07).
10. The BZip2 dictionary combo is labelled in KiB although bzip2's block unit is 100 000 bytes (ADD-14).
11. The dictionary-size formatter has no GB unit, so 1 GiB renders as `1024 MB` (ADD-14).
12. The `Comment` command aborts silently for handlers whose comment property is not a string (CMT-02).
13. The hard cap of 20 simultaneously-opened items (MF-02).
14. `Create File`'s label is `File Name:` while `Create Folder`'s is `Folder name:` (CMB-02).

Shipped **string typos** are the one category we fix rather than reproduce — see
[D-25](DIVERGENCES.md#d-25--shipped-string-typos-are-fixed).

---

## 22. How to use this document

- **Implementing a feature:** find its row, implement the "Windows 7zFM behaviour" column, and check the macOS mapping for the mechanism. If the row says **1:1**, any observable difference is a bug.
- **Reviewing a PR:** a change that alters an observable behaviour in a **1:1** row must either be reverted or promoted to a numbered entry in DIVERGENCES.md. There is no third option.
- **Adding a divergence:** add the numbered entry to DIVERGENCES.md first, then flip the row's verdict here and link it.
- **An UNRESOLVED row is not a licence to guess.** Run the experiment in DIVERGENCES §U, record the result, then update both documents in the same commit.
