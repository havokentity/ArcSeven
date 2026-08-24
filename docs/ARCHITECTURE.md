# ArcSeven — Architecture

> Generated from a 10-agent research pass over the upstream 7-Zip sources (`ip7z/7zip`), the
> macOS 26 SDK, and the existing macOS archive-manager field. Decisions here are settled;
> see [DIVERGENCES.md](DIVERGENCES.md) for deliberate departures from Windows 7zFM.

> **⚠️ Naming placeholder.** This document uses `ArcSeven` and the bundle identifier `com.havokentity.arcseven` throughout. Substitute the final name before committing. The product name must not contain "7-Zip", "7Zip" or "7z"; compatibility is stated in the tagline, never in the identifier.

---

# ArcSeven — Architecture

**A 1:1 reimplementation of the Windows 7-Zip File Manager (7zFM) for macOS.**
Not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov.

| | |
|---|---|
| **License** | `GPL-3.0-or-later` (first-party). Bundled 7-Zip remains LGPL-2.1-or-later / BSD-2 / BSD-3 / unRAR-restricted, as a separate program. |
| **Language / UI** | Swift 6 (strict concurrency) + AppKit. SwiftUI islands via `NSHostingController` for settings and sheets only. |
| **Minimum OS** | macOS 14.0 Sonoma. Built against the macOS 26 SDK with Xcode 26. |
| **Architectures** | Universal 2 (`arm64` + `x86_64`). |
| **Engine** | Bundled unmodified upstream `7zz` (subprocess) → in-process `7z.dylib` in an XPC service from M5. |
| **Distribution** | Developer ID signed + notarized + stapled DMG, Homebrew Cask, Sparkle 2 auto-update. **No Mac App Store.** |
| **Reference spec** | `github.com/ip7z/7zip`, branch `main`, 7-Zip 26.02. The `.rc` resource scripts are the authoritative behavioral specification. |

---

## 1. Design principles

1. **The `.rc` files are the spec.** Every caption, menu order, accelerator label, column name, default value and dialog control set is transcribed from `CPP/7zip/UI/FileManager/resource.rc`, `PropertyName.rc`, `SettingsPage2.rc`, `CPP/7zip/UI/GUI/CompressDialog.rc`, `ExtractDialog.rc`, `OverwriteDialog.rc`, `ProgressDialog2*.rc`. When behavior and intuition disagree, the source wins.
2. **Fidelity is about semantics, not pixels.** We reproduce 7zFM's *behavior* exactly — its sort comparator, its status-bar formulas, its column defaults, its dialog control sets, its quirks. We do **not** reproduce Win32 dialog-unit geometry, modal property sheets, or F-key defaults that are broken on Mac hardware.
3. **Native or nothing.** `NSTableView`, `NSToolbar`, `NSMenu`, `NSPathControl`, semantic colors, Liquid Glass, VoiceOver. The reason every existing cross-platform archiver loses Mac users is that it looks like a port.
4. **The engine is behind a protocol from commit one.** `ArchiveEngine` is written in M0 with one implementation and swapped in M5 without touching a line of UI.
5. **RAR-capable code never enters the GPL boundary.** The subprocess is aggregation; the linked dylib is not.
6. **Ship signed and notarized from M1.** PeaZip's `xattr -dr com.apple.quarantine` instruction and ShichiZip's bare unsigned `.zip` releases are product failures we start ahead of.

---

## 2. Milestone roadmap

### M0 — Foundations *(2–3 weeks)*
No UI. De-risk the two assumptions everything rests on.

- Repo, `LICENSE` (verbatim GPL-3.0), `NOTICE`, `THIRD_PARTY_LICENSES/`, `CONTRIBUTING.md` with inbound=outbound + DCO + *"do not paste 7-Zip/unRAR source into this repo"*, SPDX headers, `reuse lint` in CI.
- **Phase 0 spike:** signed + hardened + notarized throwaway bundle that spawns `7zz` and extracts a user-selected archive from an **external volume** to a user-selected destination. Confirm `lipo -info 7zz` → `x86_64 arm64`. Confirm the 26.02 progress encoding is still backspace-based.
- `ArchiveCore.framework`: `ArchiveEngine` protocol, `SevenZipCLIEngine`, the byte-oriented stream reader (splits on `\b`/`\n`/`\r`), the `l -slt` state-machine parser, exit-code mapping (1 = success-with-warnings), process-group cancellation.
- **Golden-file test corpus:** 7z (solid + non-solid), zip, tar.gz, rar, encrypted body, encrypted headers, multi-volume, 200k-entry archive, UTF-8 filenames (`café_日本.txt`), NFD-vs-NFC pairs, CP932 legacy zip, deliberately corrupted archive, filename-with-newline. Every parser change re-runs these.
- CI: build → test → sign → DMG → notarize → staple → verify (`codesign --verify --deep --strict`, `spctl -a -vvv -t exec` must report `source=Notarized Developer ID`, `stapler validate`) → release. Wire this up **now**, not on release day.

**Exit:** `swift test` green against the corpus; a notarized DMG of a hello-world app installs and launches clean on a second Mac.

---

### M1 — Usable single-pane browser + extract *(4–6 weeks)* → **v0.1 public**
The first genuinely useful build.

- One window, `NSSplitViewController` with a **single visible pane** (`NumPanels = 1` is 7zFM's actual default — `kNumDefaultPanels = 1`).
- `NSTableView`, view-based, `NSTableViewDataSource`, **fixed `rowHeight`, never `usesAutomaticRowHeights`**, cell reuse via `makeView(withIdentifier:)`. Details view (`⌘4`) only.
- **Exact column model:** widths Name = 160, all others = 100. Alignment per `GetColumnAlign` (dates left-aligned despite being FILETIME; integers right; everything else left; unknown types centered). Header right-click show/hide menu with **index 0 (Name) grayed**. Drag reorder always on (`LVS_EX_HEADERDRAGDROP` is unconditional). Per-folder-type persistence keyed on `GetFolderTypeID()`.
- **Exact sort comparator:** `..` first (immune to descending) → folders before files (immune to descending) → sort PROPID → cascade `sortProp → kpidName → kpidPrefix` (max 3 iterations) → stable fallback to enumeration order → *then* negate for descending. Natural numeric name compare (`file2` < `file10`, leading zeros stripped, run length first), case-insensitive. Clicking a new column resets to ascending **except** Size / Packed Size / Created / Accessed / Modified, which start descending.
- Per-pane **path bar** (`NSPathControl` + editable combo with folder-hierarchy dropdown + up button) and **4-part status bar** at 220/320/420/flex with 7zFM's exact formulas: `"<n> / <total> object(s) selected"`, total size of operated items (empty when none), focused item size, focused item mtime.
- **Toolbar:** Add, Extract, Test | Copy, Move, Delete, Info. SF Symbols, `NSToolbarItemGroup` grouping (archive group / standard group) so Liquid Glass renders as two capsules, not seven.
- Filesystem browsing, volumes root, archive-as-folder including **nested archives** (`Open Inside`, `Open Inside *` → `-t*`, `Open Inside #` → `-t#`, `Open Outside`).
- **Extract dialog** (exact control set), **Overwrite dialog** (all six buttons + the 4-line info block with 72-char midpoint elision), **Password dialog**, **Progress window** (all ten value fields, Background/Pause/Cancel with caption swaps, error list hidden until first error, `Cancel`→`&Close` on completion).
- Menu bar skeleton: File / Edit / View / Favorites / Tools / Help + the macOS app menu (About, Settings ⌘,, Quit).
- In-app **Quick Look** (`QLPreviewPanel`, Space) with per-file / combined-selection / solid-archive size caps.
- Signed, notarized DMG. Sparkle wired but pointed at a staging appcast.

**Exit:** open a 200k-entry `.7z`, scroll at 120 Hz, sort by any column, extract with correct overwrite and password handling, cancel mid-extract cleanly.

---

### M2 — Full file manager *(4–6 weeks)*
The second pane and everything that makes it a manager.

- **Two panes**, `NSSplitView` `dividerThickness = 4`, ratio-based position persisted (7zFM stores a ratio out of `1 << 16`, proportional on resize). `⌥⌘2` / `F9` in Classic. Default off; remember the choice.
- `Tab` switches panes; window title follows the focused pane's `_currentFolderPrefix` verbatim (empty → the literal app name), plus `representedURL` for real filesystem paths.
- Copy / Move to the other pane with the exact `CCopyDialog` including the multi-line info block (`Folders: n size / Files: n size / Size: sum / <prefix> / <relative paths…>`), the self-copy guard, the destination-pane routing rule (copy *into* an archive open in the other pane), and the `Confirm File Copy` prompt.
- Delete (Trash / permanent), Rename (in-place, Return), Create Folder, Create File — all with 7zFM's exact confirmation titles and message texts.
- Favorites (10 slots), Folders History, Flat View (separate state for disk and archive), Auto Refresh (FSEvents instead of a polling timer), Select/Deselect by mask and by type, Invert, **Alternative selection mode** (Norton marks, Insert, Shift+arrows) as an option.
- **Properties** as a non-modal live inspector (`⌘I`) with 7zFM's exact assembly order: item props → `----------------` → folder props → `------------------------` → per-archive-level props, `⌘C` copies `Name: Value` lines, Return expands a truncated value in a read-only viewer.
- **Drag & drop**: between panes, from Finder, and **out to Finder via `NSFilePromiseProvider`** with solid-archive batch coalescing (see §6).
- Keymap engine: `.finder` / `.commander` / `.custom` presets with a shortcut recorder.

**Exit:** F5/F6-equivalent copy and move between panes work against filesystem *and* archive destinations; promise drag of 500 files out of a 2 GB solid archive completes in one decompression pass.

---

### M3 — Full authoring *(4–6 weeks)*
Everything that writes.

- **Add-to-Archive dialog**, complete: archive path (folder prefix as static text above, filename in the combo, `...` browse with per-format filter list), format picker (7 creatable formats with the `oneFile`/`kKeepName` gating rules), level (per-format `LevelsMask`: 7z = 0–9, Zip = 0/1/3/5/7/9, GZip = 1/5/7/9, BZip2 = 1/3/5/7/9, xz = 1–9, Tar/wim = 0 only), method (per-format arrays, `"*  "` auto prefix with item-data −1), dictionary (the exact LZMA/PPMd/BZip2/Deflate enumerations), word size, solid block size (with `Non-solid` and `Solid` entries), threads (with the memory-driven auto-reduction), the **memory-usage estimator reproduced formula-for-formula** plus the `-mmemuse` limit combo, split-to-volumes (with 7-Zip's space-separated multi-size grammar where `-` terminates parsing, hence `650M - CD` parses as one value), the free-text Parameters field with `-m` stripping and **method-override detection** (`0=BCJ2` for 7z / `m=` for others suppresses the dialog's own method/dict/word properties), update mode, path mode, SFX, encryption group (7z and zip only; `Encrypt file names` 7z only; AES-256 / ZipCrypto).
- **Options sub-dialog**, adapted: the "NTFS" group becomes a **"macOS"** group (symbolic links, hard links, extended attributes / resource forks, POSIX ACLs), plus the Time group (timestamp precision combo, mtime/ctime/atime "explicitly set" mini-checkboxes, set-archive-time-to-latest, preserve-source-atime).
- OK-time validation in 7zFM's exact order: zip ASCII password check → zip+AES length ≤ 99 → password match → **memory-limit refusal with the exact five-line message** → path resolution → volume parsing → persistence.
- In-place archive update: add, delete, rename, mkdir inside an open archive.
- **Temp-file open/edit write-back**: extract to a `7zO`-prefixed temp dir, snapshot size+timestamps, watch via `DispatchSource` + `NSWorkspace.didTerminateApplicationNotification`, on change prompt *"File '{0}' was modified. Do you want to update it in the archive?"*, write back on the main actor, and — faithfully — **leave modified-but-declined temp files on disk**, which is why `Tools ▸ Delete Temporary Files…` exists.
- Split file / Combine files, Comment (`Ctrl+Z` → `⌥⌘K`), **CRC submenu in exact order** (CRC-32, CRC-64, XXH64, MD5, SHA-1, SHA-256, SHA-384, SHA-512, SHA3-256, BLAKE2sp, `*`), Checksum information window with the uppercase-for-≤8-byte / lowercase-for->8-byte digest rule and the `-<extra>` group suffix, Test, **Benchmark** window (driving `7zz b`), Memory-usage-request dialog.

**Exit:** create an AES-256 7z with encrypted headers, split into volumes, at a non-default dictionary and thread count, and have `7z l -slt` on Windows report byte-identical settings.

---

### M4 — Settings + system integration *(3–4 weeks)* → **v1.0**
- All six Options tabs, adapted (see fidelity matrix rows 39–44).
- `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` for Tier A + Tier B formats; **export nothing** (`org.7-zip.7-zip-archive` is system-declared and belongs to Igor Pavlov — import it). `LSHandlerRank = Alternate` for system types so you don't fight Archive Utility on install.
- LaunchServices default-handler management (the "System" tab's macOS equivalent).
- **Finder Quick Actions** (App Intents-backed extensions): Open archive, Extract Here, Extract to "name", Extract to…, Add to "name.7z", Add to archive…, Test archive, Compute checksum ▸. **Authenticated transport only** — App Group inbox with a per-request nonce and replay protection, or `NSXPCConnection` with `setCodeSigningRequirement(_:)` validating the peer Team ID. Never an unauthenticated URL scheme naming a pasteboard.
- **Services** menu with a nested `ArcSeven/…` submenu as the always-works fallback; Share extension.
- **Quick Look preview extension** (`QLPreviewingController`) rendering the archive *listing* in Finder — header parsing only, never decompression, file closed before render.
- `com.apple.quarantine` propagation to extracted files (the macOS analogue of NanaZip's Mark-of-the-Web propagation).
- Sparkle 2 live, Homebrew Cask submitted (`brew audit --cask --online` and `--new` clean, `livecheck` + `zap` stanzas).

**Exit:** clean-install on a virgin Mac → double-clicking a `.7z` opens ArcSeven with the right icon; right-click in Finder shows the extract actions; Sparkle offers an update.

---

### M5 — In-process engine *(4–6 weeks)*
- `ArchiveEngineXPC`: an XPC service linking a universal `7z.dylib` built from `Bundles/Format7zF`, **with the RAR handlers stripped** (GPL-clean); `.rar` continues to route to `SevenZipCLIEngine`.
- Hand-written Objective-C++ bridge over `IInArchive` / `IOutArchive` / `IArchiveExtractCallback` / `IArchiveUpdateCallback` / `ICryptoGetTextPassword`, isolated to `.mm` files that never import CoreServices (`GUID` collision), with explicit tested 4-byte-`wchar_t` ↔ UTF-16 conversion at every boundary including non-BMP.
- Port `Agent` + `AgentProxy` + `IFolder.h` for the archive-as-folder proxy tree (5 trivial compile fixes).
- Byte-level progress, `E_ABORT` cancellation, random-access single-entry extraction streamed straight into Quick Look, passwords that never touch `ps`.
- **Keychain + Touch ID** for remembered archive passwords, keyed on a content fingerprint (SHA-256 of the first N KB + size), `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `SecAccessControl` with `.userPresence`. Offer, never auto-fill silently on a just-downloaded archive.

**Exit:** open a 4 GB solid archive, scrub the listing instantly, Quick Look an entry with no temp file, and see a smooth byte-accurate progress bar with instant cancel.

---

### M6 — Beyond Windows *(ongoing)*
Ordered by differentiation × cost. See §5.

**Lead with archive diff.** It is the only feature that makes the second pane *structurally necessary*, it is nearly free because 7-Zip already reports per-entry CRC32 in `l -slt`, and nothing on the Mac does it.

Then: convert/recompress, batch operations, a persistent pausable operation queue, window tabs alongside panes, live filter inside archives, App Intents / Shortcuts / Spotlight (`AppShortcutsProvider` + legacy `.mdimporter`), CLI companion, Tier C UTIs, localization.

---

## 3. Fidelity matrix

**Verdict key:** **1:1** = identical behavior and strings · **adapted** = same capability, macOS-native mechanism or key · **dropped** = not shipped, with reason.

### Window, chrome, panes

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 1 | Title bar = focused pane's `_currentFolderPrefix` verbatim, with trailing separator; empty → literal `7-Zip` | Same string exactly, plus `representedURL` on real FS paths for the ⌘-click path popup | **1:1 +** |
| 2 | In-window menu bar (File/Edit/View/Favorites/Tools/Help) | macOS menu bar. Adds an app menu; `Tools ▸ Options` → `Settings… ⌘,`; `Help ▸ About` → app menu | **adapted** (mandatory) |
| 3 | Two-panel mode, `F9`, default **one** pane (`kNumDefaultPanels = 1`) | `⌥⌘2` (+ `F9` in Classic). Same default: one pane. Last-focused pane survives the collapse | **1:1** (key adapted) |
| 4 | Splitter 4 px, position stored as a ratio out of `1<<16`, proportional on resize | `NSSplitView`, `dividerThickness = 4`, same ratio math, autosaved | **1:1** |
| 5 | Per-pane ReBar: up-button + editable `ComboBoxEx` with icon'd folder hierarchy dropdown; `Alt+F1`/`Alt+F2` focus + drop | Per-pane path bar: segmented up-button + `NSPathControl`/editable combo with the same hierarchy dropdown; `⌥⌘1`/`⌥⌘2` | **1:1** (key adapted) |
| 6 | Per-pane 4-part status bar at 220/320/420/flex with exact formulas | `NSStackView` of 4 fields, identical widths, identical formulas and empty-string rules | **1:1** |
| 7 | Toolbar: Add / Extract / Test ‖ Copy / Move / Delete / Info; **never disabled**, failure reported after the click | Same seven items, SF Symbols, grouped into two `NSToolbarItemGroup`s. **Improvement:** proper `validateToolbarItem` enable state (Classic option restores never-disabled) | **adapted** |
| 8 | Toolbar bitmask: both toolbars visible, 24×24 buttons, text shown | Same defaults, same View ▸ Toolbars submenu (Archive / Standard / Large Buttons / Show Buttons Text) | **1:1** |
| 9 | `MFT_MENUBARBREAK` splits the Edit popup into two columns | `NSMenuItem.separatorItem()` — no such construct on macOS | **dropped** (cosmetic) |

### File list

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 10 | Virtual `SysListView32`, owner-data | `NSTableView` + `NSTableViewDataSource`, fixed row height, viewport-bounded reuse | **1:1** |
| 11 | View modes Large Icons / Small Icons / List / Details, `Ctrl+1..4`, Details default, per-pane persistence | `⌘1..4`; `NSTableView` for Details+List, `NSCollectionView` for the icon modes; same default and persistence | **1:1** |
| 12 | Columns from the folder's own PROPID list; ~100 property names in `PropertyName.rc` | Same full name table transcribed verbatim, same per-folder-type column sets (FSFolder / FSDrives / RootFolder / Zip / 7z) | **1:1** |
| 13 | Name = 160 px, all others = 100 px; date columns left-aligned, integers right, `VT_EMPTY`/`VT_I1`/`VT_FILETIME`/`VT_BSTR` left, others centered | Identical | **1:1** |
| 14 | FS default-visible: Name, Size, Modified, Created, Comment, Folders, Files, Path Prefix. Hidden: Accessed, Metadata Changed, Attributes, Packed Size, iNode, Links, Link | Identical, with `Mode`/`User`/`Group` available for POSIX | **1:1** |
| 15 | Header right-click column menu; **Name (index 0) grayed**; toggling on appends far right; toggling off the sort column resets to Name ascending | `NSTableHeaderView` menu, identical rules | **1:1** |
| 16 | Column drag-reorder always enabled; order/width/visibility/sort persisted per folder-type ID | `allowsColumnReordering` + `autosaveName`/`autosaveTableColumns`, keyed on the same type ID | **1:1** |
| 17 | Sort comparator: `..` first → folders first (both immune to descending) → PROPID → cascade to Name → Prefix → stable → negate | Identical, ported line-for-line | **1:1** |
| 18 | Natural numeric name compare, case-insensitive, leading zeros stripped, run-length first | Identical (explicitly *not* Finder's collation, and *not* Explorer's either) | **1:1** |
| 19 | New column → ascending, **except** Size / Packed Size / Created / Accessed / Modified → descending. Same column toggles | Identical | **1:1** |
| 20 | Unsorted mode = raw enumeration order (`Ctrl+F7`) | Identical (`⌃⌘7`) | **1:1** |
| 21 | `..` row, **default OFF**, never in root, always sorts first, excluded from selection/copy/delete | Identical, same default | **1:1** |
| 22 | Flat View, separate state for disk vs archive, makes `Path Prefix` meaningful | Identical + **improvement**: `⌘F` live filter with a This-Folder / Entire-Archive scope toggle, where Entire-Archive *is* flat view | **1:1 +** |
| 23 | Auto Refresh via `SetTimer` polling | FSEvents / `DispatchSource`; same menu toggle, same suspension around modal ops | **adapted** |
| 24 | View ▸ timestamp-precision submenu (`2017` placeholder relabeled to today's date; DAY/MIN/SEC/NTFS/NS radio + UTC toggle) | Identical, including the runtime relabel and the UTC checkbox | **1:1** |

### Navigation and opening

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 25 | `Enter` open · `Shift+Enter` open outside · `Alt+Enter` properties · dbl-click; **hard cap of 20 items** (`Too many items`) | `⌘↓` open · `⌥⌘↓` open outside · `⌘I` properties · dbl-click. Same 20-item cap and message. `Return` = rename (Finder convention) | **adapted** |
| 26 | `Open Inside` (`Ctrl+PgDn`) / `Open Inside *` / `Open Inside #` / `Open Outside` | Same four commands; `*`/`#` map to `-t*` / `-t#` | **1:1** |
| 27 | Nested archives via `7zO`-prefixed temp dirs and sub-streams; title accumulates `…\outer.7z\inner.zip\` | Identical model (M5 uses `Agent`/`AgentProxy` for true sub-stream nesting); same temp-dir prefix | **1:1** |
| 28 | Temp-file edit write-back prompt; **modified-but-declined temp files deliberately left on disk** | Identical, including the deliberate leak — which is why row 44 exists | **1:1** |
| 29 | `Backspace` up · `Tab` switch pane · `Alt+Up` same folder in other pane · `Alt+Left/Right` focused subfolder in other pane | `⌘↑` up (`⌫` alias) · `Tab` · `⌥⌘↑` · `⌥⌘←/→`. Note `⌃Tab` is reserved for window tabs | **1:1** (keys adapted) |
| 30 | Two different "root" concepts: menu `Open Root Folder` (Computer/Documents/Network) vs the `\` key (drive-letter list) | One `Computer` root listing volumes + Home/Documents/Network shares. `/` key → `Go to Folder ⇧⌘G` | **adapted** |
| 31 | Folders History `Alt+F12`; Favorites: 10 slots, `Alt+0..9` open / `Alt+Shift+0..9` set, `-` for empty, >100-char paths elided at the midpoint with ` ... ` | `⌥⌘Y` history; `⌃⌥0..9` / `⇧⌃⌥0..9` bookmarks; identical elision and empty-slot rendering | **1:1** (keys adapted) |
| 32 | Selection: `Select All` / `Deselect All` / `Invert` / `Select…` / `Deselect…` (wildcard mask) / by Type — bound to numpad `+`/`-`/`*` | All six commands kept with menu items and `⌘`-shortcuts. Numpad bindings live in the Classic preset only (MacBooks have no numpad). **Improvement:** `⌘F` filter + `⌘A` subsumes mask selection | **adapted** |
| 33 | Alternative selection mode (Norton marks, `Insert` toggles + advances, `Shift+arrow` sweeps) | Same option, same model, same default (off) | **1:1** |

### Operations

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 34 | `F5` copy / `F6` move to other pane; `Shift+` = within current folder (pre-filled with the bare name) | `⌘C`/`⌘V` + `⌥⌘V` move, **plus** directional `⌥⌘→`/`⌥⌘←` "Copy to Other Pane" and `⇧⌥⌘→`/`⇧⌥⌘←` "Move to Other Pane". `F5`/`F6` in Classic. Same four semantics | **1:1** (keys adapted) |
| 35 | Copy/Move dialog: editable combo + history + `...`, multi-line info block, self-copy guard, destination-pane routing, `Confirm File Copy` when copying into an archive | Identical, as a window-attached sheet with the destination pre-filled from the other pane | **1:1** |
| 36 | `Del` → Recycle Bin, `Shift+Del` → permanent; three confirmation title/message pairs | `⌘⌫` → Trash, `⌥⌘⌫` → permanent, same three messages. **Inside an archive there is no Trash** — `⌘⌫` removes the entry permanently, with distinct confirmation wording | **adapted** |
| 37 | `F2` in-place rename | `Return` (Finder convention), in-place, extension pre-deselected. `F2` in Classic | **adapted** |
| 38 | `F7` Create Folder / `Ctrl+N` Create File, with `New Folder`/`New File` defaults and exact error titles | `⇧⌘N` / `⌃⌘N`, identical dialogs, defaults and errors | **1:1** (keys adapted) |
| 39 | Split file / Combine files, with the exact volume-size grammar and confirmation | Identical | **1:1** |
| 40 | Comment (`Ctrl+Z`), per-entry only; silently aborts for non-`VT_BSTR`/`VT_EMPTY` | `⌥⌘K` (⌘Z must remain Undo). Same abort rule, same `Set Comment Error` title | **1:1** (key adapted) |
| 41 | Properties (`Alt+Enter`): scrollable read-only list, exact assembly order and separators, `Ctrl+C` copies `Name: Value`, Return expands truncated values | `⌘I`, same content and order, but as a **non-modal live inspector** that follows the selection | **1:1 +** |
| 42 | CRC submenu, 11 items, exact order | Identical, plus the `Checksum information` window with the exact digest-case rules | **1:1** |
| 43 | Test archive | Identical, with the exact OK message block (`Archives:` / `Packed Size:` / `Folders:` / `Files:` / `Size:` / `There are no errors`) | **1:1** |
| 44 | `Tools ▸ Delete Temporary Files…` scanning `7zO*.tmp` | Identical, scanning the app's temp dir | **1:1** |
| 45 | `Tools ▸ Benchmark` (dictionary, threads, passes, compress/decompress current+resulting, CPU usage, rating/usage, total rating, CPU/feature/system lines, log column, Restart/Stop) | Same window driving `7zz b`; **improvement:** reports the P-core / E-core split | **1:1 +** |
| 46 | `Benchmark 2` (total mode) — Windows CE only, `#ifdef`'d out on desktop | Not present on desktop Windows either | **dropped** |
| 47 | `File ▸ Diff` (external tool, gated on a configured Diff path) | Same, defaulting to `opendiff`; **plus** a built-in archive-vs-archive diff (§5) | **1:1 +** |
| 48 | Version-control extras (`Ver Edit`/`Commit`/`Revert`/`Diff`, gated on an undocumented `VerCtrlPath` registry value) | — | **dropped**: undocumented, invocation contract never traced through `VerCtrl.cpp`, effectively dead |
| 49 | `Link…` — Hard Link, File Symbolic Link, Directory Symbolic Link, Directory Junction, WSL | Hard Link, File Symbolic Link, Directory Symbolic Link retained. **Junction and WSL dropped** — no macOS analogue | **adapted** |
| 50 | `Alternate streams` (NTFS ADS pseudo-folder) | Extended-attributes / resource-fork pseudo-folder (`com.apple.ResourceFork`, `com.apple.FinderInfo`, arbitrary xattrs) | **adapted** |

### Dialogs

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 51 | Add to Archive: every control in §M3 above | Identical control set, order, labels, defaults, enumerations, gating rules and validation order — natively laid out, not DLU-scaled | **1:1** |
| 52 | Compress Options sub-dialog: "NTFS" group (symlinks / hard links / alternate data streams / file security) + Time group | "macOS" group (symbolic links / hard links / extended attributes & resource forks / POSIX ACLs) + the identical Time group. **NT security dropped** | **adapted** |
| 53 | Extract dialog, incl. the sticky-`kCurPaths` quirk (a caller-supplied `kCurPaths` survives if the user leaves `Full pathnames` selected) | Identical, quirk included | **1:1** |
| 54 | Overwrite dialog: 6 buttons, 4-line per-file block, 72-char midpoint elision, quote-wrap on trailing space, dual icon slots | Identical (second icon slot uses the real bundle/app icon where it differs) | **1:1** |
| 55 | Password dialog + Show Password | Identical + **Keychain/Touch ID** "Remember this password" | **1:1 +** |
| 56 | Progress dialog: 10 value fields, exact formatting thresholds, status verbs, hidden-until-first-error message list, Background↔Foreground, Pause↔Continue, Cancel→Close | Same content and behavior, but **non-modal**, plus `NSDockTile` progress and a completion notification when not frontmost. Background uses `DispatchQoS`/`setpriority` instead of `IDLE_PRIORITY_CLASS` | **adapted** |
| 57 | Memory-usage-request dialog (`IDD_MEM`) | Identical | **1:1** |
| 58 | Diagnostic messages dialog (`IDD_MESSAGES`) | — | **dropped**: no code path instantiates it in 24.x–26.x; errors surface in the progress list |
| 59 | About dialog (logo, version, build date, copyright, `www.7-zip.org`, OK) | macOS About panel + a Legal/Acknowledgements pane carrying GPL notices, the 7-Zip triple, and the unRAR paragraph (GPLv3 §5(d) Appropriate Legal Notices) | **adapted** |
| 60 | SFX creation (`7z.sfx`, a Windows `.exe`) | Retained — it produces a Windows self-extractor, which is still useful output from a Mac. **Improvement:** also offer a macOS self-extracting `.command` | **1:1 +** |
| 61 | RAR: read-only (7zFM cannot create RAR either) | Read-only, via the bundled `7zz` subprocess only, never linked | **1:1** |

### Settings and system integration

| # | Windows 7zFM | macOS mapping | Verdict |
|---|---|---|---|
| 62 | Options ▸ **System** (per-extension file associations, current-user / all-users columns, admin rights) | UTI table + `LSSetDefaultRoleHandler`. Same list-of-extensions UI; the four-state cell (blank / other app / other install / this app) maps cleanly | **adapted** |
| 63 | Options ▸ **7-Zip** (shell context-menu integration, 32/64-bit, cascaded, icons, ElimDup, Zone.Id propagation, 14-item context-menu checklist) | Toggles for Finder Quick Actions, Services, Share extension, cascaded-vs-flat, plus the same per-verb checklist. **Zone.Id → `com.apple.quarantine` propagation.** `ElimDup` kept verbatim | **adapted** |
| 64 | Options ▸ **Folders** (working folder: system temp / current / specified, removable-only) | Identical | **1:1** |
| 65 | Options ▸ **Editor** (Viewer / Editor / Diff paths) | Identical; Diff still unlocks `File ▸ Diff` and the "super mode" extras | **1:1** |
| 66 | Options ▸ **Settings** (Show ".." off, real file icons off, full row select off, grid lines off, single click off, alternative selection off, show system menu off, large pages, RAM limit) | All identical including every default. **`Use large memory pages` dropped** — no macOS equivalent | **1:1 minus one** |
| 67 | Options ▸ **Language** (from `Lang/*.txt`) | Kept structurally, backed by String Catalogs; English-only at v1.0 | **adapted** |
| 68 | `System ▸` submenu injecting the full Explorer shell context menu | `Finder ▸` submenu: Reveal in Finder, Quick Look, Open With ▸, Get Info, Tags, Services ▸ | **adapted** |
| 69 | Explorer shell extension (Open archive ▸, Extract files…, Extract Here, Extract to "…\", Test, Add to archive…, Add to "….7z", Add to "….zip", CRC SHA ▸) | Finder Quick Actions + Services with the same verb set and the same `<Folder>` / `<Archive>` name-generation rules | **adapted** |
| 70 | Registry persistence under `HKCU\Software\7-Zip\FM` (Position, Panels, Toolbars, ListMode, PanelPath0/1, FolderHistory, FolderShortcuts, CopyHistory, FlatViewArc0/1, Columns\<TypeID>, …) | `NSUserDefaults` under `com.havokentity.arcseven`, **same key names and same value semantics**, so the persistence model is auditable against the Windows original | **adapted** |
| 71 | `F1` and `Alt+F12` are the only real accelerators; every other shortcut fires **only when the list view has focus** | **dropped**: all shortcuts are menu-backed and work app-wide. This is a bug on Windows, not a feature | **dropped** |
| 72 | Shipped string typos: `"File {0} is already exist"`, `"Split to &volumes,  bytes:"` (double space) | Fixed. Recorded in `docs/DIVERGENCES.md` | **adapted** |

---

## 4. Module breakdown

```
ArcSeven.app
├── Contents/MacOS/ArcSeven ................ AppKit host
├── Contents/Helpers/7zz ................... bundled upstream binary (unmodified, signed)
├── Contents/Frameworks/ArchiveCore.framework
├── Contents/Frameworks/Sparkle.framework
├── Contents/XPCServices/ArchiveEngine.xpc . M5 in-process engine (no RAR)
├── Contents/PlugIns/QuickLookPreview.appex
├── Contents/PlugIns/QuickActions*.appex ... App Intents-backed Finder actions
└── Contents/Library/Spotlight/ArcSeven.mdimporter  (M6)
```

**`ArchiveCore`** — engine-agnostic, no AppKit.
`ArchiveEngine` protocol · `SevenZipCLIEngine` (process spawn, process-group cancel, `@listfile`+`-scsUTF-8`) · `SevenZipXPCEngine` (M5) · `StreamTokenizer` (backspace-aware byte reader) · `SLTParser` (ten-hyphen state machine, dictionary-per-item) · `ExitCodeMapper` (1 = warning) · `ArchiveListing` / `ArchiveEntry` models · `HashService` · `BenchmarkService` · `FormatCatalog` (7 creatable formats, level masks, method arrays, dictionary/word/solid/thread enumerations) · `MemoryEstimator` (7-Zip's exact formula) · `VolumeSizeParser` (space-separated, `-` terminates).

**`FMKit`** — the file-manager domain, no views.
`FolderProvider` protocol · `FileSystemFolder` · `VolumesFolder` · `RootFolder` · `ArchiveFolder` (nested via `_parentFolders` chain) · `XattrFolder` · `HashFolder` · `PanelModel` (selection, focus, marks, flat mode) · `SortEngine` (the exact comparator) · `ColumnModel` (PROPID table, widths, alignment, visibility, per-type persistence) · `HistoryStore` · `FavoritesStore` (10 slots) · `CopyHistoryStore` · `TempManager` (`7zO` prefix, edit-watch, deliberate-leak policy) · `OperationCoordinator`.

**`FMUI`** — AppKit.
`MainWindowController` · `PanelViewController` (table + path bar + status bar) · `FileListTableController` (data source, type-select, reuse) · `IconGridController` (`NSCollectionView` for modes 0–1) · `PathBarView` · `StatusBarView` · `ToolbarController` · `MenuController` (menu construction, dynamic File menu, Favorites rebuild, timestamp submenu relabel, check/radio state) · `ShortcutMap` (`.finder` / `.commander` / `.custom` + recorder) · `DragController` (`NSFilePromiseProvider` out, `NSFilePromiseReceiver` in) · `QuickLookController`.

**`Dialogs`** — one controller per 7zFM dialog: Compress, CompressOptions, Extract, Overwrite, Password, Progress, Properties, Benchmark, Split, Combine, Link, Comment, Memory, SelectMask, CreateFolder, CreateFile, BrowseTempFiles.

**`SettingsUI`** — SwiftUI in `NSHostingController`: System, Integration, Folders, Editor, Settings, Language, Shortcuts, Advanced (engine binary path).

**`Integration`** — `QuickLookPreview` (header-only listing render, sandboxed, pure-Swift parser — no `7zz` spawn), `QuickActions` (App Intents, authenticated App-Group/XPC transport), `ServicesProvider`, `AppShortcutsProvider` (M6), `SpotlightImporter` (M6, legacy `.mdimporter` — `CSImportExtension` has never worked on macOS).

**`Support`** — `Defaults` (the registry-key map) · `PathNormalizer` (NFC/NFD, `:`↔`/`, legacy code pages via `UniversalDetector`) · `Quarantine` · `TrashService` · `APFSClone` (`clonefile(2)`) · `ICloudMaterializer` (`startDownloadingUbiquitousItem`) · `ThreadPlanner` (P/E core topology via `hw.perflevel0/1.logicalcpu`, QoS, thermal backoff, `beginActivity`).

---

## 5. Improvements over the Windows original

Ordered by differentiation × feasibility. Every one is additive — none changes a 1:1 behavior.

1. **Archive diff — lead with this.** Left pane = archive A, right pane = archive B (or a folder). Compare path set + size + mtime + **CRC32, which `l -slt` already gives you, with zero extraction**. Color rows added/removed/changed/identical, filter to differences, offer `Sync ▸` to copy differences one way. Nothing on the Mac does this, and it is the only feature that makes the second pane structurally necessary.
2. **Drag out of an archive without extracting first** — `NSFilePromiseProvider`, with **solid-archive batch coalescing**: on the first `writePromiseTo:` callback, gather every pending promise in the drag session, run one `7zz x` into a staging dir, then satisfy each promise from staging. The naive per-callback implementation is O(n · archive_size) and will appear to hang forever.
3. **Quick Look, both directions** — Space in-app, plus a Finder preview extension that renders the archive *listing* (header parse only, file closed before render, size caps).
4. **Apple Silicon thread tuning** — the most measurable, least-exploited win. QoS `.background` confines threads to E-cores permanently: 0.56 s at QoS 33 vs 4.4 s at QoS 9 on a 1 GB compress. Never `.background`. Default LZMA2 encode threads to the **P-core count**, not `activeProcessorCount`. Budget dictionary × threads against `physicalMemory`. Back off on `thermalState`. Wrap long jobs in `beginActivity` or App Nap collapses throughput.
5. **Keychain + Touch ID passwords**, keyed on a content fingerprint rather than a path.
6. **Persistent, pausable operation queue** (`⌥⌘0`) with per-item ETA, throughput, reorder, and cross-launch persistence. Be honest in the UI: resume is per-entry for non-solid/ZIP/tar and block-restart for solid 7z — the 7-Zip API cannot do byte-level resume.
7. **Convert / Recompress** as a first-class command on a selection of archives. 7-Zip has no such command at all.
8. **Batch operations** — Extract All / Test All / Convert All / Re-encrypt All across many selected archives, feeding the queue.
9. **Live filter inside archives** (`⌘F`, This-Folder / Entire-Archive scope) — subsumes numpad mask selection *and* delivers Flat View in a discoverable form.
10. **Window tabs alongside panes.** Two panes × N tabs is the layout no Mac archiver offers. ForkLift has tabs without archiver depth; ShichiZip explicitly sets `tabbingMode = .disallowed`.
11. **App Intents / Shortcuts / Siri / Spotlight** — `CompressFiles`, `ExtractArchive`, `ListArchiveContents` (with a real `AppEntity`), `TestArchive`, `ConvertArchive`, `HashFiles`, `ExtractMatchingEntries`, registered via `AppShortcutsProvider`. A weekend of work, and ShichiZip has none.
12. **Spotlight importer** indexing entry names inside archives (`kMDItemTextContent`, capped, encrypted archives skipped). Must use the **legacy `.mdimporter`** — `CSImportExtension` has never worked on macOS.
13. **Dock tile progress** + completion notification when not frontmost.
14. **macOS correctness nobody else gets fully right:** quarantine propagation · NFC↔NFD normalization (APFS hands you decomposed names, Windows ZIPs carry precomposed — this is a top-tier real bug class) · legacy CP932/CP936/CP949 detection via `UniversalDetector` · iCloud `.icloud` placeholder materialization before compressing (otherwise you archive a 0-byte stub) · resource-fork/xattr round-trip fidelity **and** a "clean for Windows/Linux recipients" toggle (`.DS_Store`, `__MACOSX/`, `._*`) · `clonefile(2)` for same-volume copies · case-sensitivity-agnostic APFS handling · `:`↔`/` mapping.
15. **Content-aware compression defaults** — already-compressed selection → store; many small text files → solid on, larger dictionary; one huge file → solid off; ZIP for sharing → exclude Mac metadata and warn on Zip64. Plus named presets.
16. **Signed, notarized, stapled, Sparkle-updating, Homebrew Cask** — which puts you ahead of PeaZip *and* ShichiZip on day one.
17. **CLI companion** (`arcseven compress/extract/convert`) sharing the GUI's presets, installable from the menu.
18. **Full VoiceOver and full-keyboard-access support** on the file list.

---

## 6. Risks and mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | **App Sandbox blocks arbitrary-directory browsing.** The single most likely thing to force an architecture rethink. | Critical | **Ship non-sandboxed, Developer ID.** Prove child-process file access from a signed, hardened, notarized bundle against an external volume in the **M0 Phase-0 spike**, before any UI exists. Sandbox only the appexes. |
| 2 | **Subprocess output is a human-facing UI, not a contract** — backspace erasure, format-dependent `-slt` keys, the undocumented `-ba`, filenames containing newlines. All behavior here was verified against 7-Zip **18.05**, not 26.02. | High | Golden-file parser suite in CI. Pin the bundled version. Re-run the suite on every bump. Cross-check `-slt` item count against the `l` summary. Verify in M0 that 26.02 still uses backspace and not `\r`. Long-term: M5 removes the parser entirely for the read path. |
| 3 | **Solid-archive N² on promise drag and Quick Look multi-select.** Dragging 500 files out of a 2 GB solid `.7z` naively re-scans 2 GB five hundred times. | High | Coalesce per drag session behind a `DispatchGroup` gate; `maxConcurrentOperationCount = 1` on the promise queue; single batch extraction to a staging dir; sweep abandoned staging on launch. M5 makes this structural. |
| 4 | **unRAR / GPL incompatibility.** Linking the RAR decoder into a GPL-3.0 work is a violation (GPLv3 §7/§10; Fedora: *"GPL-Incompatible and non-free"*). | High | RAR touches only the unmodified `7zz` subprocess (aggregation). The M5 dylib is built **without** RAR handlers; `.rar` routes to the CLI engine. `CONTRIBUTING.md` forbids pasting 7-Zip/unRAR source into the repo. unRAR paragraph verbatim in `NOTICE`, `README.md`, and the in-app Acknowledgements. Never expose a "create RAR" affordance. |
| 5 | **Password on create leaks into `ps`.** `-p` must be on argv; piping on stdin silently produces an **unencrypted** archive with exit 0. | High | Document with a loud code comment so nobody "fixes" it. Move only the creation path in-process at M5 to close it. If a hard security promise is made about encrypted archives, promote M5's `IOutArchive` work ahead of the rest of M5. |
| 6 | **`NSTableView` at 100k rows.** | Medium | Fixed `rowHeight`, never `usesAutomaticRowHeights`; `NSTableViewDataSource` over a `ContiguousArray` of structs; `reloadData(forRowIndexes:columnIndexes:)` for progressive fills; hand-rolled `NSTableCellView`, not `NSHostingConfiguration`, in the file list. **Prove 120 Hz scroll at 100k rows in M1 before writing archive code.** |
| 7 | **Notarization fails on a nested binary.** | Medium | Sign inside-out (helpers → frameworks → appexes → app), `--options runtime --timestamp` on every Mach-O, never `--deep` to sign. Verification gate in CI before publish. On failure, `notarytool log <id>` names the offender. |
| 8 | **Xcode/CI keychain hang.** `codesign` blocks on an invisible authorization dialog. | Medium | `security set-key-partition-list -S apple-tool:,apple:,codesign:` after import. Ephemeral keychain, `if: always()` cleanup deleting the `.p12` and `.p8`. |
| 9 | **Liquid Glass shatter on macOS 26.** Every ungrouped toolbar item gets its own glass capsule. | Medium | `NSToolbarItemGroup` for the archive and standard groups; `NSGlassEffectContainerView` where elements should merge; honor `accessibilityDisplayShouldReduceTransparency`. |
| 10 | **`wchar_t` (4 bytes) and `GUID` collisions in the M5 bridge.** Failure mode is silent memory corruption, not a compile error. | Medium (M5) | Explicit tested UTF-32↔UTF-16 conversion at every boundary, including non-BMP. 7-Zip headers only in `.mm` files that never import CoreServices, behind a narrow pure-`.h` facade. Vendor headers pinned to the exact dylib version, checked in CI. |
| 11 | **M5 decoder crash takes down the app.** ~50 attacker-controlled binary formats parsed in C++. | Medium (M5) | The in-process engine lives in an **XPC service**, never the main app. This is non-negotiable and is why Phase A is the default. |
| 12 | **FinderSync / Quick Action collisions and unstable management UI.** Adobe Creative Cloud ships two broadly-claiming FinderSync extensions; macOS 15.0/15.1 removed the Finder Extensions pane entirely. | Low–Medium | Prefer **Quick Actions + Services** over FinderSync (we need menus, not sync badges). Ship a diagnostics panel reporting `isExtensionEnabled` with a `pluginkit -e use -u <UUID>` fallback. |
| 13 | **Confused-deputy in the extension transport** (the exact bug ShichiZip shipped as issue #5). | Medium | App-Group inbox with a per-request nonce and replay protection, **or** `NSXPCConnection` + `setCodeSigningRequirement`. Never an unauthenticated URL scheme naming a pasteboard. |
| 14 | **Trademark / affiliation.** `ArcSeven` puts the mark in the product-identifier position and fails nominative fair use prong 3. | Medium | Rename before the first push. No "7-Zip" in app name, bundle ID, DMG volume name or repo name. Compatibility stated in the tagline plus an explicit non-affiliation line in README, NOTICE and the About panel. |
| 15 | **ShichiZip already occupies this space** (932★, LGPL-2.1, Homebrew + MacPorts, active). | Medium | Differentiate on the nine gaps it has — Shortcuts, Spotlight, tabs, live filter, Keychain, operation queue, convert, batch, **diff** — plus signing/notarization/auto-update, plus the 1:1 fidelity contract it deliberately does not have. |
| 16 | **Exit code 8 (out of memory)** was never reproduced and is reachable with large dictionaries on constrained machines. | Low | Handle defensively; surface the memory-request dialog (row 57) rather than a generic failure. |
| 17 | **Universal-binary assumption.** The official macOS tarball is almost certainly fat, but this was not directly verified. | Low | `lipo -info 7zz` in M0; add a `lipo -create` build step if thin. |

---

## 7. Compliance checklist (every release)

- [ ] DMG signed inside-out, hardened runtime on every Mach-O, notarized, stapled
- [ ] Bundled `7zz` byte-identical to upstream; SHA-256 recorded in `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` with `Modifications: NONE`
- [ ] `7z<ver>-src.tar.xz` attached to the **same** GitHub Release as the DMG *(LGPL-2.1 §4 discharge — "equivalent access from the same place")*
- [ ] Source tarball / signed git tag published for ArcSeven itself *(GPLv3 §6)*
- [ ] `LICENSE`, `NOTICE`, `THIRD_PARTY_LICENSES/` present inside `.app/Contents/Resources/Legal/`
- [ ] About panel shows copyright, "no warranty", "may convey under the GPL", and a link to the license *(GPLv3 §5(d))*
- [ ] Acknowledgements pane carries the unRAR paragraph **verbatim**
- [ ] No "7-Zip" in app name, bundle ID, DMG volume name, or repo name
- [ ] No "create RAR" affordance anywhere in the UI
- [ ] `codesign --verify --deep --strict` · `spctl -a -vvv -t exec` reports `source=Notarized Developer ID` · `stapler validate` · `reuse lint` — all green