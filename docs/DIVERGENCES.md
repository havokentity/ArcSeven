<!--
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 Rajesh D'Monte
-->

# ArcSeven — Deliberate Divergences from Windows 7zFM

ArcSeven aims to be a 1:1 reimplementation of the Windows 7-Zip File Manager (`7zFM.exe`).
It is **not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov**;
every reference to 7-Zip here names the program whose behaviour is being described.

[FIDELITY.md](FIDELITY.md) is the reference for what we reproduce. **This document is the exhaustive
list of what we deliberately do not.** If a behaviour differs from 7zFM and it is not listed here,
it is a bug — file it, don't rationalise it.

**Rules for this document**

1. Every **Adapted**, **Deferred** or **Dropped** verdict in FIDELITY.md that a user could notice has a numbered entry here.
2. Every entry states **Reversible?** honestly. "Reversible" means a user or a build flag can restore the Windows behaviour without redesigning anything. "Not reversible" means restoring it would require rearchitecting, is legally impossible, or is impossible on macOS.
3. **Unknowns are not divergences.** Where upstream behaviour could not be established from source, it is filed in [§U](#u--unresolved-needs-an-empirical-check-against-a-running-7zfm) as UNRESOLVED with the experiment that settles it. We do not guess and we do not silently pick a behaviour.
4. New divergences land **before** the code that causes them, in the same PR.

**Index**

| Category | Entries |
|---|---|
| Keyboard and input | [D-01](#d-01--the-default-keymap-is-mac-native-not-f5f6f7) · [D-02](#d-02--return-renames-by-default-and-opens-only-in-the-commander-preset) · [D-14](#d-14--shortcuts-work-app-wide-not-only-when-the-file-list-has-focus) · [D-15](#d-15--comment-is-k-not-z) · [D-21](#d-21--r-is-refresh-r-is-reveal-in-finder) · [D-28](#d-28--path-bar-focus-keys-are-remapped-to-avoid-a-collision) |
| Destructive operations | [D-03](#d-03--delete-moves-to-the-trash-by-default) |
| Formats and archive features | [D-04](#d-04--the-ntfs-group-in-the-add-options-sub-dialog-becomes-a-macos-group) · [D-05](#d-05--zstd-stays-decode-only) · [D-07](#d-07--no-windows-sfx-stub-is-bundled-so-sfx-is-off-by-default) · [D-16](#d-16--link-types-junction-and-wsl-are-dropped) · [D-17](#d-17--ntfs-alternate-data-streams-become-extended-attributes) |
| System integration | [D-06](#d-06--the-options-system-tab-becomes-launchservices-default-app-handling) · [D-08](#d-08--zoneid-propagation-becomes-comapplequarantine-propagation) · [D-11](#d-11--shell-extension-registration-becomes-a-finder-sync-extension-toggle) · [D-18](#d-18--the-system--shell-menu-becomes-a-finder--submenu) · [D-20](#d-20--the-two-root-concepts-collapse-into-one) · [D-22](#d-22--raw-physical-device-browsing--is-dropped) |
| Dropped features | [D-09](#d-09--version-control-integration-ver-edit--commit--revert--diff-is-dropped) · [D-10](#d-10--the-diagnostic-messages-dialog-is-dropped) · [D-12](#d-12--use-large-memory-pages-is-dropped) · [D-19](#d-19--the-edit-menu-column-break-becomes-a-separator) · [D-29](#d-29--full-row-select-is-dropped-nstableview-has-no-other-mode) |
| Presentation and text | [D-13](#d-13--toolbar-buttons-are-validated-not-permanently-enabled) · [D-24](#d-24--the-progress-window-is-non-modal) · [D-25](#d-25--shipped-string-typos-are-fixed) · [D-27](#d-27--properties-is-a-non-modal-inspector) |
| Correctness on macOS | [D-23](#d-23--names-are-compared-and-matched-after-nfc-normalisation) |
| Scheduling | [D-26](#d-26--the-language-tab-ships-structurally-with-one-entry) |
| **UNRESOLVED** | [U-01](#u-01--space-key-selection-toggle) · [U-02](#u-02--f8) · [U-03](#u-03--ctrlgrey--column-auto-size) · [U-04](#u-04--7z-column-set-union-vs-per-archive) · [U-05](#u-05--blake2sp-ordering-within-the-all-hashes-command) · [U-06](#u-06--hash-format-visibility-in-the-add-dialog) |

---

### D-01 — The default keymap is Mac-native, not F5/F6/F7

| | |
|---|---|
| **Windows 7zFM** | `F5` = Copy To, `F6` = Move To, `F7` = Create Folder, `F2` = Rename, `F9` = 2 Panels, `F3`/`F4` = View/Edit, `Del`/`Shift+Del` = Recycle Bin / permanent, numpad `+`/`-`/`*` = select / deselect / invert. All handled in `PanelKey.cpp` as list-view key-down cases. |
| **ArcSeven** | Mac-native defaults: `⌥⌘→`/`⇧⌥⌘→` copy/move to the other pane, `⇧⌘N` new folder, `Return` rename, `⌥⌘2` two panes, `⌘Y`/`⌘E` view/edit, `⌘⌫`/`⌥⌘⌫` delete, `⌘A`/`⇧⌘A`/`⌃⌘A` selection. A **7-Zip Classic** preset in Settings ▸ Shortcuts restores the full F-key and numpad set. |
| **Affects** | FIDELITY §10 (whole table), MF-01, MF-07…MF-12, MF-19, MF-20, MV-08, ME-01…ME-08 |

**Rationale.** On Mac hardware the function-key row is media control unless the user sets
"Use F1, F2, etc. keys as standard function keys" system-wide, and even then `F3` is Mission Control
and `F4` is Spotlight/Launchpad on many keyboards. Shipping F5 = Copy as the default means the
majority of users press it and their screen brightness changes — the single fastest way to make a
port feel broken. Separately, MacBook keyboards have **no numpad at all**, so `Grey +`/`Grey -`/`Grey *`
are unreachable by default; binding selection commands to keys that do not physically exist is not
fidelity, it is a dead feature. The muscle memory is real and worth preserving, so it is preserved
as an explicit opt-in rather than imposed on everyone.

**Reversible?** **Yes, fully, by the user.** Settings ▸ Shortcuts ▸ preset `7-Zip Classic` restores
F2/F3/F4/F5/F6/F7/F9, `Del`/`Shift+Del` and the numpad selection keys. A third `Custom` preset with a
shortcut recorder is available. The keymap is a data structure (`ShortcutMap`, persisted as
`Shortcuts.Preset` / `Shortcuts.Custom`) from the first commit precisely so that this is a preference
and never a code change. Changing the *default* preset is a one-line change if the decision is ever
revisited.

---

### D-02 — Return renames by default, and opens only in the Commander preset

| | |
|---|---|
| **Windows 7zFM** | `Enter` opens the focused item (`OnNotifyActivateItems` → `OpenSelectedItems(true)`); `F2` starts in-place rename (`PanelKey.cpp`). |
| **ArcSeven** | Default (Finder preset): `Return` starts in-place rename with the extension pre-deselected; `⌘↓` opens. Commander/Classic preset: `Return` opens and `F2` renames, exactly as on Windows. |
| **Affects** | MF-01, MF-09, KEY-01, KEY-05 |

**Rationale.** `Return` = rename and `⌘↓` = open is the single most deeply ingrained pair of
conventions in the Finder, and a file manager that inverts them causes accidental launches: a user
selects a file, presses `Return` expecting to rename it, and instead the app opens an archive or
hands a document to another application. The failure is silent and immediate, and it happens on the
very first interaction. The Commander convention is genuinely better for keyboard-driven navigation,
which is why it is one preset flip away rather than gone.

**Reversible?** **Yes, by the user.** Selecting the `7-Zip Classic` preset (or the Commander preset,
which is the same binding for these two keys) restores `Return` = open and `F2` = rename. Both
commands always have menu items with visible key equivalents, so whichever preset is active is
discoverable rather than hidden.

---

### D-03 — Delete moves to the Trash by default

| | |
|---|---|
| **Windows 7zFM** | `Delete` → `DeleteItems(toRecycleBin: !shift)`; `Shift+Delete` deletes permanently. Filesystem deletes go through `SHFileOperation` with `FOF_ALLOWUNDO`; a path at or beyond `MAX_PATH` fails with `The system cannot move a file with long path to the Recycle Bin`. |
| **ArcSeven** | `⌘⌫` moves to the Trash via `NSWorkspace.recycle(_:)`; `⌥⌘⌫` deletes permanently. Both use 7zFM's three confirmation title/message pairs verbatim. Inside an archive there is no Trash: `⌘⌫` removes the entry permanently and the confirmation text says so explicitly. |
| **Affects** | MF-12, TB-06, DEL-04, DEL-05, ADD-30 |

**Rationale.** The Recycle Bin and the Trash are the same concept, so the *semantics* are unchanged;
only the key and the API differ, which follows from [D-01](#d-01--the-default-keymap-is-mac-native-not-f5f6f7).
The genuinely new behaviour is the in-archive case. macOS has no notion of a Trash inside a `.7z`,
and silently making `⌘⌫` irreversible in one context while it is reversible in another is exactly
the kind of quiet asymmetry that loses user data. 7zFM has the same asymmetry and does not
acknowledge it; we acknowledge it in the confirmation text rather than changing the behaviour.
The `Delete files after compression` option (ADD-30) also routes through the Trash for the same
reason — that option deletes the user's originals, and a recoverable delete there is worth the
divergence from `-sdel`'s semantics.

**Reversible?** **Partly.** The Trash-vs-permanent default is a preference (Settings ▸ Settings ▸
"Delete moves items to the Trash"), and the Classic preset restores `Del` / `Shift+Del` as the keys.
The in-archive case is **not** reversible: no Trash exists there, on any platform.

---

### D-04 — The NTFS group in the Add Options sub-dialog becomes a macOS group

| | |
|---|---|
| **Windows 7zFM** | `IDD_COMPRESS_OPTIONS` has a groupbox literally titled `NTFS` with four checkboxes: `Store symbolic links`, `Store hard links`, `Store alternate data streams`, `Store file security`. Each is hidden when the selected handler does not advertise the matching flag; the groupbox hides when none apply. The Extract dialog's counterpart is `Restore file security` (NT ACLs). |
| **ArcSeven** | The group is titled **macOS** and contains: `Store symbolic links`, `Store hard links`, `Store extended attributes and resource forks`, `Store POSIX ACLs`. Extract's counterpart becomes `Restore extended attributes and ACLs`. The same per-handler hide rule applies, driven by the same handler flags. The options-summary tokens become `SL`, `HL`, `XA`, `ACL`. APFS clones are used for same-volume copy operations where possible, which is an implementation detail rather than a checkbox. |
| **Affects** | ADO-02, ADO-08, ADD-39, EXT-11, and the `NT Security` / `Alternate Stream` rows in §6.1 |

**Rationale.** Alternate data streams, NT security descriptors, NTFS hard links and NTFS junctions
are filesystem-specific concepts that do not exist on APFS/HFS+. Their nearest macOS analogues are
one-to-one in intent: ADS ↔ extended attributes (with the resource fork being the historically
important one), NT ACLs ↔ POSIX ACLs plus the mode bits, hard links ↔ hard links (which *do* exist
and map directly). Keeping the labels "NTFS" and "file security" on a Mac would name storage
concepts the user's disk does not have, and would imply we can restore Windows ACLs — which we
cannot and must not silently pretend to. Reading remains lossless: `NT Security` and
`Alternate Stream` still display in Properties and as columns for archives that carry them, so
nothing is hidden from the user; they are just never *applied* to a macOS file.

**Reversible?** **No, not meaningfully.** The Windows concepts have no macOS storage to land in. What
*is* reversible is the round-trip fidelity choice on the wire: the underlying `7zz` switches for
symlinks and hard links are unchanged, and an "archive for Windows/Linux recipients" toggle
(excluding `.DS_Store`, `__MACOSX/`, `._*` and the xattr sidecars) is offered so the same archive can
be produced with or without the Mac metadata.

---

### D-05 — zstd stays decode-only

| | |
|---|---|
| **Windows 7zFM** | zstd does not appear in the Add dialog's format list at all. `ZstdHandler.cpp` registers with `CreateArcOut = NULL`, and every zstd block in `CompressDialog.cpp` (`kZSTD`, `g_ZstdMethods`, the second "dictionary chain" combo) is commented out. Extraction and testing of `.zst` / `.tzst` work. |
| **ArcSeven** | Identical: `.zst` and `.tzst` extract and test; zstd is not offered as a creation format. |
| **Affects** | ADD-06, ADD-08 |

**Rationale.** This is a fidelity decision, not a technical limitation — Keka and others do offer
zstd compression. Enabling it here would mean designing UI that has no upstream counterpart: the
commented-out source shows a *second* dictionary-chain combo and level/word-size semantics that
differ from LZMA's, so there is no 1:1 layout to copy. Inventing one would put a first-party control
set into the dialog this project defines as a transcription of upstream's. A user who wants zstd
today is better served by an honest "not offered" than by a control we made up.

**Reversible?** **Yes, cheaply, when upstream reverses it.** The moment upstream registers an out-handler
and un-comments the dialog code, we mirror it and inherit the layout — that is the whole point of
waiting. Shipping it earlier is also possible (the bundled `7zz` would need to be a build with zstd
encoding enabled, which upstream's official binary is not), but it would then be a first-party UI
design and would be re-filed here as an *improvement*, not as fidelity.

---

### D-06 — The Options System tab becomes LaunchServices default-app handling

| | |
|---|---|
| **Windows 7zFM** | `SystemPage.rc`: `Associate 7-Zip with:` over a report list of archive extensions with two value columns (current user / all users) and two `+` bulk buttons. Editing a row writes Windows registry file-association keys; the all-users column requires administrator rights. Each cell shows one of four states: blank, another program's name, `[7-Zip]` (a different 7-Zip installation), `7-Zip` (this copy). |
| **ArcSeven** | Same tab, same list, same four-state cell rendering (`[ArcSeven]` for a different ArcSeven bundle, `ArcSeven` for this one). The mechanism is LaunchServices: state is read with `LSCopyDefaultRoleHandlerForContentType` and written with `LSSetDefaultRoleHandlerForContentType(_:role:)`, keyed on the UTI declared for each extension. The extension list is derived from the bundle's `CFBundleDocumentTypes` and `UTImportedTypeDeclarations` so it cannot drift from what the app actually claims. The **All users** column and its `+` button are removed. |
| **Affects** | OPT-03, OPT-04, OPT-05, OPT-06, OPT-07 |

**Rationale.** There is no registry, and file-type ownership on macOS is LaunchServices' job. The
four-state model maps across without loss, which is why the tab is kept rather than replaced with
something unrecognisable. The all-users column has no analogue: LaunchServices default handlers are
strictly per-user, there is no supported system-wide API, and the unsupported route (editing the
system LaunchServices database) is exactly the sort of thing that breaks on an OS update and gets an
app blamed for it. Removing a column is more honest than showing one that can never be filled in.

**Reversible?** **No** for the all-users column — the API does not exist. **Yes** for everything else,
in the sense that the tab already behaves as upstream's does.

---

### D-07 — No Windows SFX stub is bundled, so SFX is off by default

| | |
|---|---|
| **Windows 7zFM** | `Create SF&X archive` is enabled for 7z when the method is one of `{Copy, LZMA, LZMA2, PPMd}`; checking it rewrites the archive extension to `.exe` and prepends the `7z.sfx` module from the 7-Zip program directory. `7zCon.sfx`, `7zS.sfx`, `7zSD.sfx`, `7zS2.sfx` exist for console and installer variants. |
| **ArcSeven** | The checkbox is present with the identical enable rule, but is **unchecked and inoperative by default** because no Windows PE stub ships in the bundle. Settings ▸ Folders offers an "SFX module" path; pointing it at a `7z.sfx` the user has obtained enables the checkbox and produces a byte-compatible Windows self-extractor. Independently, a **macOS self-extracting `.command`** is offered as a first-party output. |
| **Affects** | ADD-28, ADD-05 (the `exe (*.exe)` filter) |

**Rationale.** Three reasons, in order. (1) The SFX modules are Windows PE executables; bundling
prebuilt third-party `.exe` payloads inside a signed, notarized macOS app means shipping code we do
not build, cannot meaningfully audit, and cannot sign, inside a bundle whose entire security story is
"everything here is signed by us". (2) Producing an `.exe` on macOS also produces a file no Mac user
can test before sending, which is a support burden with no upside for the default user.
(3) Malware scanners and mail gateways treat a freshly produced `.exe` from an unfamiliar tool
harshly, so the default-on behaviour would generate confusing failures. The capability is genuinely
useful for cross-platform delivery, which is why it is one setting away rather than absent.

**Reversible?** **Yes, by the user, per install.** Point Settings ▸ Folders ▸ SFX module at a
downloaded `7z.sfx` (or `7zCon.sfx`) and the checkbox behaves exactly as on Windows, including the
method filtering and the `.exe` extension rewrite. Nothing about the emitted archive differs.

---

### D-08 — Zone.Id propagation becomes com.apple.quarantine propagation

| | |
|---|---|
| **Windows 7zFM** | Options ▸ 7-Zip has `Propagate Zone.Id stream:` with a combo of `* No` (0, default), `Yes` (1), `For Office files` (2), plus a raw numeric entry when the stored value is ≥ 3. When enabled, the NTFS `Zone.Identifier` alternate data stream (Mark-of-the-Web) is copied from the archive onto extracted files. |
| **ArcSeven** | The same combo in the same position, relabelled `Propagate quarantine flag:` with entries `No` (default), `Yes`, and `For documents and executables`. When enabled, the archive's `com.apple.quarantine` extended attribute is written onto extracted items. The third mode applies it only to items whose type conforms to `public.executable`, `public.script`, or the Office/document UTIs. The raw-numeric escape hatch is dropped. |
| **Affects** | OPT-11, EXT-14, PST-15 |

**Rationale.** `com.apple.quarantine` is macOS's Mark-of-the-Web: Gatekeeper reads it, the "downloaded
from the internet" warning comes from it, and it is the exact same idea implemented as an xattr
rather than an ADS. Propagating it is a genuine security improvement over the many Mac archivers
that strip it silently — extracting an executable from a downloaded archive should not launder away
its provenance. The `For Office files` mode exists upstream because Office macros are the classic
attack; on macOS the equivalent risk set is broader (scripts and executables), so the mode is widened
and relabelled honestly rather than kept with a name that would under-describe what it does.

**Reversible?** **No, and it should not be** — writing an NTFS ADS on APFS is meaningless. The
*policy* is fully reversible: the default remains `No`, matching upstream, so nothing changes for a
user who does not opt in.

---

### D-09 — Version-control integration (Ver Edit / Commit / Revert / Diff) is dropped

| | |
|---|---|
| **Windows 7zFM** | When an undocumented `VerCtrlPath` registry value is set **and** a Diff path is configured **and** exactly one filesystem file smaller than 2 GiB is selected, `CFileMenu::Load` appends `Ver Edit (&1)`, `Ver Commit`, `Ver Revert`, `Ver Diff (&0)`, gated further on whether the file is read-only or writable (`VerCtrl.cpp`). |
| **ArcSeven** | Not shipped. No menu items, no setting, no registry-equivalent key. |
| **Affects** | MF-28, OPT-17 |

**Rationale.** The feature is undocumented in 7-Zip's own manual, reachable only by setting a
registry value nothing in the UI writes, and its invocation contract — what executable is launched
with what arguments — was never traced through `VerCtrl.cpp` during the source pass. Reimplementing
it would mean inventing that contract, at which point it is a first-party feature wearing 7-Zip's
labels, which is the one thing this project refuses to do. It is also effectively dead code
upstream: no user reaches it accidentally, so nothing about the everyday app is lost.

**Reversible?** **Yes, but only after archaeology.** If someone traces `VerCtrl.cpp`'s actual
invocation contract and demonstrates a working configuration against a running 7zFM, the four menu
items and their gating conditions are a small, self-contained addition — the File menu is already
built dynamically with exactly this kind of conditional append. Until then it stays out.

---

### D-10 — The Diagnostic messages dialog is dropped

| | |
|---|---|
| **Windows 7zFM** | `IDD_MESSAGES`, captioned `7-Zip: Diagnostic messages`, a resizable two-column list plus a `&Close` button. **No code path in 24.x, 25.x or 26.x instantiates `CMessagesDialog`** — errors surface in the Progress dialog's embedded message list plus the final error alert. The resource is retained but orphaned. |
| **ArcSeven** | Not shipped. Errors appear in the progress window's message list (PRG-14) and the completion alert (PRG-19), exactly as they actually do on Windows. |
| **Affects** | MSG-01 |

**Rationale.** Reimplementing an orphaned resource would produce a window no user has seen since
before 24.00. Fidelity is to the shipped *behaviour*, and the shipped behaviour is the progress-window
list. The `There are no errors` string the dialog would have shown is retained where it is actually
used, in the Test result block.

**Reversible?** **Yes, trivially**, if upstream ever wires it back up: the message model already
exists behind the progress list, so the dialog would be a second view onto the same data.

---

### D-11 — Shell extension registration becomes a Finder Sync extension toggle

| | |
|---|---|
| **Windows 7zFM** | Options ▸ 7-Zip has `Integrate 7-Zip to shell context menu` (caption gains ` (64-bit)` on 64-bit Windows) and a separate `(32-bit)` checkbox, which register/unregister an in-process shell extension DLL that `explorer.exe` loads. Plus `Cascaded context menu`, `Icons in context menu`, and the 14-row context-menu item checklist. |
| **ArcSeven** | The tab is renamed **Integration**. `Enable Finder integration` reports `FIFinderSyncController.isExtensionEnabled` and opens the system management UI via `showExtensionManagementInterface()`, with a diagnostics row that surfaces the `pluginkit -e use -u <UUID>` fallback. `Cascaded` and `Icons` map directly onto `setSubmenu(_:for:)` and `NSMenuItem.image` in the extension. The `(32-bit)` checkbox is dropped. The verb checklist is kept minus the three email rows, which become a system Share item. Because one extension is not enough coverage, ArcSeven ships **three** surfaces together: the Finder Sync appex, an `NSServices` submenu, and App Intents-backed Quick Actions. |
| **Affects** | OPT-08, OPT-09, OPT-13, SHL-01, SHL-13, SHL-14, SHL-15 |

**Rationale.** macOS has no equivalent of injecting a DLL into Finder, and Finder Sync — the nearest
thing — carries constraints that make it unreliable as a *sole* surface: it only functions inside
directories the extension claims (so `/` must be claimed, and `/Volumes` separately), only one
extension effectively controls a given directory (Adobe Creative Cloud ships two broadly-claiming
extensions that collide in the wild), some directories such as `/Applications` never work at all, the
containing app must have been launched once before the extension registers, and the System Settings
pane for managing extensions was removed in macOS 15.0/15.1 and restored in 15.2. Shipping only
Finder Sync would mean a feature that silently does nothing for a meaningful share of users.
Services always work and need no enablement; App Intents additionally surface in Shortcuts, Spotlight
and Finder's Quick Actions. Three surfaces is not gold-plating, it is the minimum for parity with a
mechanism that has no single counterpart. The extension itself does menus and badges **only** — every
action is handed to the app over an authenticated App-Group/XPC transport and no `7zz` is ever spawned
inside the appex, because extensions are long-lived and multiply-instantiated.

**Reversible?** **No** — the DLL mechanism does not exist on macOS. **Yes** for every user-facing
policy on top of it: cascaded vs inline, icons on or off, the per-verb checklist, `/Volumes` claiming,
and each of the three surfaces individually.

---

### D-12 — Use large memory pages is dropped

| | |
|---|---|
| **Windows 7zFM** | Options ▸ Settings has `Use &large memory pages`, requiring administrator rights and the `SeLockMemoryPrivilege`. Stored under `LargePages`. |
| **ArcSeven** | Not shipped. No checkbox, no setting. |
| **Affects** | OPT-25, PST-14 |

**Rationale.** macOS has no user-selectable large-page mechanism comparable to Windows' large-page
allocation. Superpages exist but are managed by the kernel's VM subsystem, not opted into per
process by a privileged token, and there is no supported knob for an application to request them.
A checkbox that cannot do anything is worse than no checkbox.

**Reversible?** **No.** There is nothing to turn on.

---

### D-13 — Toolbar buttons are validated, not permanently enabled

| | |
|---|---|
| **Windows 7zFM** | All seven toolbar buttons are created with `TBSTATE_ENABLED` and are **never disabled**, even when the action is impossible. Clicking one with an invalid selection produces a message box *after* the fact. |
| **ArcSeven** | Toolbar items participate in `validateToolbarItem(_:)` and dim when their command cannot run (nothing selected, read-only archive chain, unsupported destination). The Classic preset restores the never-disabled behaviour. |
| **Affects** | TB-08 |

**Rationale.** macOS users read a dimmed control as "not applicable here" and an enabled one as "this
will work". Presenting an enabled Extract button on a text file and then throwing an alert is a
pattern the platform's own HIG treats as an error, and it teaches users to distrust the toolbar.
The 7zFM behaviour is not a designed feature — it falls out of the toolbar being built once and never
revalidated. The *reason* for that (menu and shell-menu construction on Windows is expensive, and
upstream explicitly avoids doing work per state change) does not apply to `NSToolbar` validation.

**Reversible?** **Yes, by the user.** Classic preset (or Settings ▸ Settings ▸ "Toolbar buttons are
always enabled") restores the permanently-enabled behaviour, including the after-the-click error
alerts, which are implemented either way.

---

### D-14 — Shortcuts work app-wide, not only when the file list has focus

| | |
|---|---|
| **Windows 7zFM** | `IDR_ACCELERATOR1` contains exactly two real accelerators: `F1` (Help) and `Alt+F12` (Folders History). Everything else is handled in `CPanel::OnKeyDown` / `CMyListView::OnMessage`, so **no other shortcut fires unless the file list has keyboard focus** — with the path combo focused, `Ctrl+R`, `F5`, `Del` and the rest do nothing. The source comments explain the design: menu loading can be slow on UNC paths and for the system menu, so accelerators were deliberately avoided. |
| **ArcSeven** | Every command is a menu item with a real key equivalent, so shortcuts fire regardless of which subview has focus (subject to the normal first-responder rules — a text field still gets `⌘A`). |
| **Affects** | KEY-34, and every row in FIDELITY §10 |

**Rationale.** This is a Windows implementation artefact with a documented performance cause, not a
behaviour anyone chose. On macOS, menu key equivalents are the discoverable, accessible,
VoiceOver-announced path, and building menus is not expensive. Reproducing "your shortcut silently
does nothing because focus is in the path bar" would be reproducing a bug — and it is invisible to
diagnose, because nothing happens and nothing is reported.

**Reversible?** **No, deliberately.** There is no setting to make shortcuts stop working. If evidence
appears that some workflow depends on the focus-scoping (for example, a key that must reach the path
field instead of the list), the fix is to scope that *individual* key correctly via the responder
chain, not to reinstate the global behaviour.

---

### D-15 — Comment is ⌥⌘K, not ⌘Z

| | |
|---|---|
| **Windows 7zFM** | `Ctrl+Z` opens the Comment dialog (`ChangeComment()`) — it is **not** Undo. The File menu shows `Comme&nt...` with accelerator text `Ctrl+Z`. |
| **ArcSeven** | `Comment…` is `⌥⌘K`. `⌘Z` is Undo everywhere in the app, including in the rename field and every text field. |
| **Affects** | MF-16, KEY-15 |

**Rationale.** `⌘Z` is Undo at the operating-system level; text fields, the rename editor and every
standard control implement it whether we like it or not. Binding it to a modal dialog would either
be shadowed unpredictably depending on focus, or would break Undo where users unconditionally expect
it. This is one of the very few upstream bindings that is simply unavailable on the platform.

**Reversible?** **No.** Even the Classic preset keeps `⌥⌘K`, because `⌘Z` cannot be safely reclaimed.
The Classic preset does add `⌃Z` as an additional alias for users who want something adjacent to the
muscle memory.

---

### D-16 — Link types Junction and WSL are dropped

| | |
|---|---|
| **Windows 7zFM** | `IDD_LINK` offers five radio options in order: `Hard Link`, `File Symbolic Link`, `Directory Symbolic Link`, `Directory Junction`, `WSL`. |
| **ArcSeven** | Three options: `Hard Link`, `File Symbolic Link`, `Directory Symbolic Link`. The groupbox, dialog layout, `Link from:` / `Link to:` fields, resolved-target static, and the `Link` default button are otherwise unchanged. |
| **Affects** | MF-21 |

**Rationale.** NTFS directory junctions are reparse points with no POSIX equivalent — a directory
symlink is the closest thing and it is already offered separately, so a "Junction" radio would either
duplicate it or lie. WSL links are a Linux-subsystem-specific reparse tag that only means anything
inside WSL. The three surviving options cover everything macOS can actually create, and the
file-vs-directory symlink distinction is kept even though `symlink(2)` does not care, because it
matches upstream's control set and it makes the intent explicit in the archive.

**Reversible?** **No.** Neither link type can be created on APFS/HFS+. Reading is unaffected:
archives containing junction or WSL reparse data still display the `Link` property in Properties and
in the column set.

---

### D-17 — NTFS alternate data streams become extended attributes

| | |
|---|---|
| **Windows 7zFM** | `File ▸ Alternate streams` (`IDM_ALT_STREAMS`) opens the NTFS ADS pseudo-folder for the selection, disabled when the selection does not support them. Alt-stream destinations are permitted for Copy/Move only into an alt-streams folder open in the second pane. |
| **ArcSeven** | An **Extended Attributes** pseudo-folder listing the item's xattrs, including `com.apple.ResourceFork`, `com.apple.FinderInfo` and `com.apple.quarantine`, with the same second-pane destination rule. **Deferred to M6** — it is not in v1.0. |
| **Affects** | MF-22, CPY-06, and the `Alternate Stream` row in §6.1 |

**Rationale.** ADS and xattrs are the same idea — named side-channel data hanging off a file — and
the pseudo-folder browsing model transfers exactly, including the "open it in the other pane and copy
into it" trick. The label has to change because "alternate data streams" names an NTFS feature the
user's disk does not have. It is deferred rather than shipped in v1.0 because the write path
(creating and deleting xattrs through a folder abstraction) needs the M5 in-process engine to be
transactional in the way archive updates already are; a half-working version that can list but not
reliably write would be worse than waiting.

**Reversible?** **N/A** — this is a rename plus a schedule, not a capability removal. Reading ADS
from Windows-authored archives is unaffected today.

---

### D-18 — The System ▸ shell menu becomes a Finder ▸ submenu

| | |
|---|---|
| **Windows 7zFM** | When Options ▸ Settings ▸ `Show system menu` is on (**default off**) and the panel is not inside an archive, `CreateSystemMenu` inserts the **entire Windows Explorer context menu** as a `System` submenu at position 0 of the File/context menu, via `IContextMenu::QueryContextMenu` with `CMF_EXPLORE`. Holding Shift while opening adds Explorer's extended verbs. The in-archive guard exists because the call is very slow inside large archives. |
| **ArcSeven** | The same checkbox with the same default and the same in-archive guard, producing a **`Finder ▸`** submenu containing: Reveal in Finder, Quick Look, Open With ▸, Get Info, Tags ▸, Services ▸. |
| **Affects** | MF-25, OPT-24 |

**Rationale.** There is no API to enumerate and host Finder's context menu inside another app —
Finder is closed, and the third-party items in it come from Finder Sync extensions that only render
inside Finder itself. The menu's *purpose* is "give me the shell's own actions for this item", and
that purpose is served by the six entries above, all of which are real system services reachable
programmatically. Keeping the option's name, default and archive guard preserves the shape of the
feature even though the contents necessarily differ.

**Reversible?** **No** for hosting Finder's actual menu. **Yes** for the option itself and its
contents, which are a plain menu definition.

---

### D-19 — The Edit menu column break becomes a separator

| | |
|---|---|
| **Windows 7zFM** | The Edit menu's sixth item is `MENUITEM "", 0, MFT_MENUBARBREAK`, which renders the popup as **two side-by-side columns** with a vertical rule: selection commands on the left, by-type commands on the right. |
| **ArcSeven** | A standard `NSMenuItem.separatorItem()` in the same position, giving a single-column menu with the same grouping. |
| **Affects** | ME-06 |

**Rationale.** AppKit has no multi-column menu construct, and there is no reasonable way to fake one
that would survive VoiceOver, keyboard navigation and menu-bar layout. The bar break carries no
semantic content beyond grouping, and a separator carries exactly that grouping.

**Reversible?** **No.** The construct does not exist. Nothing is lost: item order and grouping are
identical.

---

### D-20 — The two root concepts collapse into one

| | |
|---|---|
| **Windows 7zFM** | Two *different* destinations that are easily confused: `View ▸ Open Root Folder` (`IDM_OPEN_ROOT_FOLDER`) calls `OpenRootFolder()` → the Computer / Documents / Network list, while the `\` key (handled on `WM_CHAR` in `CMyListView::OnMessage`) calls `OpenDrivesFolder()` → the drive-letter list. The `PanelKey.cpp` block that would have handled `VK_DIVIDE` / `'\'` / `VK_OEM_5` is entirely commented out, and the `OpenRootFolder()` line inside it is *also* commented out in favour of `OpenDrivesFolder()`. |
| **ArcSeven** | One root: `Computer` (`⇧⌘C`) lists mounted volumes plus Home, Documents and network shares. The `/` key opens `Go to Folder…` (`⇧⌘G`), the Finder idiom for typing a path. |
| **Affects** | MV-10, MV-11, COL-06, COL-07, KEY-25 |

**Rationale.** The Windows split exists because Windows has drive letters and a separate shell
namespace root; macOS has neither. There is one filesystem with one root and a set of mounted
volumes, so a "drives list" and a "root folder" would be the same view under two names. The `/`
key is retargeted because on macOS `/` is the root path prefix, and typing it in a file manager
overwhelmingly means "let me type a path" — which is exactly what `⇧⌘G` provides.

**Reversible?** **No, and there is nothing to restore to.** The `Computer` root retains the volume
columns upstream's drives folder used (Total Size, Free Space, Type, Label, File System, Cluster
Size), so no information is lost.

---

### D-22 — Raw physical-device browsing (`\\.\`) is dropped

| | |
|---|---|
| **Windows 7zFM** | `CRootFolder` lists `Computer`, `Documents`, `Network` and `\\.\` — the last giving low-level access to physical drives, and requiring administrator rights. |
| **ArcSeven** | The root lists `Computer`, `Documents` and `Network`. There is no raw-device entry. |
| **Affects** | COL-07 |

**Rationale.** The macOS equivalent would be browsing `/dev/rdisk*`, which requires root, is blocked
for the system volume by System Integrity Protection regardless of privilege, and would push a
non-sandboxed, Developer-ID-signed consumer app into asking for administrator authorisation for a
feature almost no one uses. The archive-handler value it provides upstream — opening a raw disk as an
MBR/GPT/NTFS/FAT image — is still available: opening a disk **image file** (`.dmg`, `.iso`, `.vhd`,
`.img`) uses exactly the same handlers.

**Reversible?** **In principle**, behind an explicit privileged-helper design that is out of scope
and not planned. SIP limits would remain regardless.

---

### D-21 — ⌘R is Refresh, ⇧⌘R is Reveal in Finder

| | |
|---|---|
| **Windows 7zFM** | `Ctrl+R` = `OnReload()`, refresh the listing preserving the focused item. There is no "reveal" concept. |
| **ArcSeven** | `⌘R` = Refresh (matching upstream's `Ctrl+…` → `⌘…` mapping); `⇧⌘R` = Reveal in Finder. |
| **Affects** | MV-15 |

**Rationale.** A genuine two-way collision: `Ctrl+R` maps naturally to `⌘R` for Refresh, while `⌘R`
in the Finder means "Show Original / Reveal". Refresh wins the unmodified key because it is an
existing 7zFM command with an existing binding and it is used far more often in a file manager that
polls nothing; Reveal is a ArcSeven addition and takes the modified key. Documented here so the choice
is not re-litigated in a future PR.

**Reversible?** **Yes** — both are ordinary menu items and either can be rebound in the Custom
shortcut preset.

---

### D-23 — Names are compared and matched after NFC normalisation

| | |
|---|---|
| **Windows 7zFM** | `CompareFileNames_ForFolderList` compares UTF-16 code units directly (case-insensitively, with the natural-numeric rule). Windows filesystems do not normalise, and neither does 7-Zip. |
| **ArcSeven** | The identical comparator, applied to names normalised to **NFC** first. The same normalisation is applied to wildcard mask matching (`Select…` / `Deselect…`), to type-select, and when matching archive entry names against on-disk names. Bytes written into an archive are the archive's own, unmodified. |
| **Affects** | SRT-06, ME-04 |

**Rationale.** APFS and HFS+ hand back **decomposed** (NFD-ish) names, while archives created on
Windows carry **precomposed** (NFC) names. Without normalising before comparison, `café.txt` from a
ZIP and `café.txt` on disk sort into different places, fail to match a `caf*` mask inconsistently,
and — worst — an overwrite check can conclude "no collision" for two names that the filesystem
considers the same file. That last case is silent data loss. This is one of the highest-frequency
real bug classes in Mac archivers and reproducing the Windows comparator byte-for-byte would import
it deliberately.

**Reversible?** **No, and it must not be.** Normalisation is confined to *comparison, sorting and
matching*. It never changes what is stored: entry names go into archives exactly as received, and
extracted files are created with the archive's bytes, so round-tripping an archive through ArcSeven does
not silently re-normalise anyone's filenames.

---

### D-24 — The Progress window is non-modal

| | |
|---|---|
| **Windows 7zFM** | `IDD_PROGRESS` is a modal dialog. The `&Background` button lowers the process priority and marks the title, but the dialog itself still owns input. |
| **ArcSeven** | The progress window is non-modal: the panes stay usable, multiple operations can run, and the window carries `NSDockTile` progress plus a completion notification when the app is not frontmost. All ten value fields, the status line, the hidden-until-first-error message list, the `Background`↔`Foreground` and `Pause`↔`Continue` caption swaps, the cancel confirmation and the `Cancel`→`&Close` transition are unchanged. |
| **Affects** | PRG-22, PRG-15, PRG-16 |

**Rationale.** The `&Background` button is upstream conceding that users want to keep working during
a long operation; on Windows it does as much as a modal dialog allows. macOS has no reason for the
concession — a non-modal window with dock progress is the platform norm, and it makes the queue of
operations (`⌥⌘0`) coherent rather than a second modal stack. Password and overwrite prompts remain
modal *to their own operation*, presented as sheets on the progress window, which preserves the
upstream behaviour of the password dialog being raised over the progress dialog.

**Reversible?** **Yes in principle** (a preference could make the window application-modal) but it is
not offered, because a modal window and the operation queue cannot coexist sensibly.

---

### D-25 — Shipped string typos are fixed

| | |
|---|---|
| **Windows 7zFM** | Several shipped strings contain errors: `File {0} is already exist` (`IDS_FILE_EXIST`), `Split to &volumes,  bytes:` (double space, `SplitDialog.rc`). Related identifier-level oddities that are not user-visible: `IDS_OPENNING` (double N), `ShowButtonsLables`, and `IDS_PROP_C0MMENTED` (digit zero). |
| **ArcSeven** | User-visible strings are corrected: `File {0} already exists`, `Split to volumes, bytes:`. Non-user-visible identifier oddities are irrelevant here and are noted in FIDELITY §6.1 only where they explain a name. Two entries in the property table that both render as `Errors` are **not** "fixed" — that is a semantic collision between two distinct properties, not a typo, and it is reproduced. |
| **Affects** | SPL-01, and the `IDS_FILE_EXIST` string wherever it appears |

**Rationale.** This is the one category where fidelity loses. A typo carries no behaviour, breaks no
workflow, and cannot be depended on; reproducing it just makes the app look unfinished to every user
who reads it. Anything with observable behaviour attached — the double `Errors` name, the KiB-labelled
bzip2 dictionary, the missing GB unit in the dictionary formatter — is reproduced faithfully, because
those affect what users see in data, not just how a label reads.

**Reversible?** **Yes, trivially** — they are strings in a catalog. There is no reason to.

---

### D-26 — The Language tab ships structurally with one entry

| | |
|---|---|
| **Windows 7zFM** | Options ▸ Language: an unsorted drop-list populated from `.txt` files in the `Lang` folder (English shows as `English`, other locales as `English name (Native name)`), plus a runtime-filled info static with translator credits and completeness. Changing it triggers a full menu rebuild and toolbar reload. |
| **ArcSeven** | The tab and both controls are present in the same position with the same refresh chain, but the list contains only **English** at v1.0. It is populated from the bundle's String Catalogs, not from loose `.txt` files. |
| **Affects** | OPT-27, OPT-28, PST-13 |

**Rationale.** 7-Zip ships roughly ninety translations. Seeding them from the upstream language files
is attractive but only partially valid: many strings map, but Mac-specific terminology diverges
(Finder, Trash, Settings rather than Options) and a machine-merged catalog would produce a UI that is
half-translated and confidently wrong. Keeping the tab present means the structure is honest about
where localisation will live, and macOS's own per-app language preference continues to work
regardless. This is scheduling, not a decision against localisation.

**Reversible?** **N/A — it is a schedule.** Adding a language adds a row; the tab needs no
redesign. Contributions are welcome and the tab exists to receive them.

---

### D-27 — Properties is a non-modal inspector

| | |
|---|---|
| **Windows 7zFM** | `Alt+Enter` opens a modal, scrollable read-only list (the generic `IDD_LISTVIEW` configured with title `Properties`) for the current selection. For a plain filesystem folder that does not expose `IGetFolderArcProps`, 7zFM instead invokes the **shell's own** properties verb. |
| **ArcSeven** | `⌘I` toggles a non-modal inspector that follows the selection and updates live. Content, order, separators, the truncation rule, and the `⌘C` / `Return` / `⌘A` behaviours are unchanged. ArcSeven always renders its own inspector; `Get Info in Finder` is a separate item in the `Finder ▸` submenu. |
| **Affects** | PRP-01, PRP-02 |

**Rationale.** Property inspection is a browsing activity: users step through files comparing sizes,
CRCs and timestamps, and a modal dialog forces open/close/reopen for every item. A live inspector is
also how ⌘I behaves in the Finder, so the binding matches expectation. Rendering our own panel for
filesystem folders instead of delegating to the system removes an inconsistency that exists upstream —
on Windows the panel you get depends on which folder type you are in, and the two look nothing alike.

**Reversible?** **Yes** — the inspector can be presented as a modal sheet if it is ever wanted; the
content model is identical either way.

---

### D-28 — Path-bar focus keys are remapped to avoid a collision

| | |
|---|---|
| **Windows 7zFM** | `Alt+F1` focuses and drops open the **left** panel's path combo, `Alt+F2` the **right** one (`PanelKey.cpp`). |
| **ArcSeven** | `⌘L` focuses and drops open the **focused** pane's path bar; `⌥⌘L` does the same for the **other** pane. The Classic preset binds `⌥F1` / `⌥F2` to the left and right panes respectively. |
| **Affects** | PB-06, KEY-22 |

**Rationale.** The literal transliteration `⌥⌘1` / `⌥⌘2` collides with `⌥⌘2` for the two-panel toggle
(MV-08), which is the more prominent and more frequently used binding. `⌘L` is the platform idiom for
"focus the location field" and generalises correctly to a two-pane layout by acting on the focused
pane, which is also what a user reaching for it actually means. This entry exists so the collision is
recorded rather than rediscovered: an earlier architecture sketch listed both bindings at `⌥⌘1`/`⌥⌘2`.

**Reversible?** **Yes** — Classic restores per-pane function-key bindings, and the Custom preset can
bind anything.

---

### D-29 — Full row select is dropped: NSTableView has no other mode

| | |
|---|---|
| **Windows 7zFM** | `Options ▸ Settings ▸ Full row select`, **default off**, sets `LVS_EX_FULLROWSELECT` on the report-mode list view. With it off, only the Name column highlights and only a click in that column selects the row; the rest of each row is dead space you can start a rubber-band drag in. With it on, a click anywhere in the row selects it and the whole row highlights. |
| **ArcSeven** | The checkbox is **removed**. `NSTableView` behaves as though the option were permanently on, and the key `FM.FullRow` is reserved but never written. |
| **Affects** | OPT-20, PST-10 |

**Rationale.** There is no per-cell selection mode on `NSTableView` to switch *out of*. A click
anywhere in a row selects that row, and the highlight spans the row, on every
`selectionHighlightStyle` and every `style` AppKit offers; `.none` suppresses the highlight
drawing entirely rather than confining it to one column, which is a different setting with a
different meaning. So neither position of the checkbox describes anything the list could
actually do, and the off position — the shipped default — describes the one thing it certainly
never does.

The checkbox is gone rather than left inert on purpose. A control that stores a value nothing
acts on is worse than an absent one: it looks like it worked, so the unchanged behaviour reads
as a bug somewhere else entirely, and the setting gets flipped back and forth to no effect.
That was true of all seven switches on this pane until the five that *can* be honoured were
wired up; this is the one that cannot be.

The key name survives in `SettingsKey` with no property behind it, on the same terms as
`Options.WriteZone` (see [D-08](#d-08--zoneid-propagation-becomes-comapplequarantine-propagation)):
the fidelity ledger audits `HKCU\Software\7-Zip\FM\FullRow` by name whether or not ArcSeven
ever gives it a value, and whoever revisits this will want the same spelling.

**Reversible?** **No.** Restoring it would mean drawing and hit-testing the list by hand
instead of using `NSTableView`, to reproduce a mode whose purpose on Windows — keeping the
other columns free for rubber-band selection — has no counterpart here.

---

## U — UNRESOLVED: needs an empirical check against a running 7zFM

These are **not decisions**. Each is a question the source pass could not answer, recorded with the
experiment that settles it. Until an entry is resolved, ArcSeven does the thing described under
"Interim behaviour", and that behaviour is marked **UNRESOLVED** in FIDELITY.md rather than **1:1**.

**Procedure for resolving one:** run the experiment against a current 7zFM (24.09 or later) on
Windows, record the observed behaviour and the version tested, then update FIDELITY.md and this
document **in the same commit**, converting the entry either to a plain FIDELITY row (if we now match)
or to a numbered `D-` entry (if we deliberately do not).

---

### U-01 — Space key selection toggle

**Question.** Does `Space` toggle the focused item's selection in the shipped 7zFM?

**What the source says.** There is **no `VK_SPACE` case anywhere** in `PanelKey.cpp` or `Panel.cpp`.
Space should therefore fall through to the list-view control's own incremental type-ahead search.
Several widely-copied third-party shortcut lists nevertheless claim Space toggles selection, which is
the Norton Commander / Far Manager convention users may genuinely expect.

**Why it matters.** If Space *does* toggle, it is a core selection primitive we are missing. If it
does not, binding it would break type-ahead — and ArcSeven currently binds Space to Quick Look, the macOS
convention, which would then collide with a real upstream behaviour.

**Interim behaviour.** `Space` = Quick Look (macOS convention). Type-ahead search is bound to plain
character keys as usual, so nothing is lost either way.

**Experiment.** In a folder with several files, focus the list, ensure Alternative selection mode is
**off**, and press `Space`. Then repeat with Alternative selection mode **on**. Record for each: does
the focused row's selection state change? Does the focus advance? Does an incremental search buffer
appear (type `Space` then a letter and observe whether it matches a name containing a leading space)?

---

### U-02 — F8

**Question.** Is `F8` bound to Delete in the shipped 7zFM?

**What the source says.** `PanelKey.cpp` has **no `VK_F8` case at all**. Several published shortcut
lists map F8 to Delete, which is the Norton Commander convention.

**Why it matters.** If F8 deletes, the Classic preset must include it — omitting a destructive
binding that users have muscle memory for is a real hazard, and so is adding one that upstream does
not have.

**Interim behaviour.** `F8` is **unbound in both presets**. Delete is `⌘⌫` (default) / `Del` (Classic).

**Experiment.** In a scratch folder, focus the list, select a file, and press `F8`. Record whether a
delete confirmation appears, and if so which of the three confirmation titles (DEL-01/02/03) is used.
Repeat with `Shift+F8` to check for a permanent-delete variant.

---

### U-03 — Ctrl+[Grey +] column auto-size

**Question.** Does `Ctrl` + numpad `+` auto-size all columns, and is that 7-Zip's code or the list
control's built-in behaviour?

**What the source says.** The official manual documents it as "Adjust optimal column width for items".
But in `PanelKey.cpp` the `VK_ADD` branch with Ctrl held returns without calling any handler, which
implies the effect — if any — comes from the `SysListView32` control itself, not from 7-Zip.

**Why it matters.** `NSTableView` has **no equivalent built-in**, so if the behaviour exists it must be
implemented explicitly: measure the widest rendered cell per column within the visible range (or the
whole model, which is O(n) and unacceptable for a 200k-entry archive) and set the column width.
The scope of the measurement is itself a decision that depends on what upstream actually does.

**Interim behaviour.** Not implemented. Column widths are set by COL-02 defaults, by dragging, and by
per-folder-type persistence.

**Experiment.** In a Details-view folder containing both very short and very long names, press
`Ctrl` + numpad `+`. Record: do column widths change? Which columns? Does the Name column size to the
longest name in the **whole** folder or only to what is on screen (test by scrolling to a long name
far down the list first, then scrolling back to the top before pressing the key)?

---

### U-04 — 7z column set: union vs per-archive

**Question.** When browsing a `.7z`, does the panel show the union of the candidate property list
(with blanks where a property is absent) or only the properties actually present in that archive?

**What the source says.** `7zProperties.cpp` provides an ordered candidate map, but the 7z handler
advertises **only the properties actually present in the opened archive**, so the visible column set
should vary per file. This is inferred from the handler's advertising logic, not observed.

**Why it matters.** It determines whether a user sees a stable column layout across all `.7z` files or
a set that changes per archive — and it interacts with per-folder-type column persistence (COL-15),
which keys on the folder type ID, not on the individual archive.

**Interim behaviour.** Per-archive dynamic set, matching the handler's advertising logic. FIDELITY
COL-09 is marked **1:1 pending U-04**.

**Experiment.** Open two `.7z` files in 7zFM: one plain (no encryption, no anti-items, default
method) and one with encrypted entries and a non-default method. Compare the column sets in the
header right-click menu and the visible columns in each. Then open the plain one again and check
whether columns persisted from the richer archive reappear as empty columns.

---

### U-05 — BLAKE2sp ordering within the all-hashes command

**Question.** Where does BLAKE2sp appear in the output of `File ▸ CRC ▸ *`?

**What the source says.** `*` iterates registered hashers **sorted ascending by numeric hasher ID**.
Confirmed IDs: CRC32 = 0x001, CRC64 = 0x004, SHA256 = 0x00A, SHA1 = 0x201, CKSUM = 0x203 (not linked
into the GUI build), MD5 = 0x208, XXH64 = 0x211, SHA384 = 0x222, SHA512 = 0x223, SHA3-256 = 0x231.
**BLAKE2sp's ID could not be found** — no `REGISTER_HASHER` for it is enumerable in the mirror.
The commonly cited value is 0x202, which would place it between SHA1 and CKSUM, but that is unverified.

**Why it matters.** Only for the row order of the `*` result list. Every individual hash command is
unaffected, and the digests themselves are unaffected.

**Interim behaviour.** Row order follows the output order of `7zz h -scrc*` from the bundled binary,
which is produced by the same registration table — so ArcSeven is self-consistent with the engine it
ships, whatever the ID turns out to be. The **menu** order is fixed and verbatim (HSH-02) and is not
in question.

**Experiment.** Either (a) select `File ▸ CRC ▸ *` in 7zFM on a small file and record the row order,
or (b) run `7z h -scrc* <file>` on Windows and record the column order. Both derive from the same
sorted iteration.

---

### U-06 — Hash format visibility in the Add dialog

**Question.** Is the `Hash` archive format ever selectable in the Add-to-Archive dialog's format
combo through normal use, or only when pre-selected by the shell `CRC SHA` verb?

**What the source says.** The population loop skips a handler when `ai.Flags_HashHandler()` is true
**unless** its index equals the pre-selected format index. So `Hash` should be invisible unless the
dialog was opened with it already chosen — which the `CRC SHA ▸ SHA-256 -> <name>.sha256` verb does.

**Why it matters.** It decides whether "produce a `.sha256` checksum file" is a first-class output
format in the Add dialog or a checksum-menu-only capability. Both are defensible; guessing would
either add a format upstream hides or hide one it exposes.

**Interim behaviour.** Hidden from the normal format list; reachable from the checksum verbs and from
`File ▸ CRC ▸ SHA-256 → file`. FIDELITY ADD-07 is marked **1:1** with this flag attached.

**Experiment.** Open the Add dialog from the toolbar (not from a `CRC SHA` verb) on a selection of
files and enumerate the Archive format combo. Then invoke the shell verb
`CRC SHA ▸ SHA-256 -> <name>.sha256`, open the resulting dialog if one appears, and enumerate the
combo again. Record whether `Hash` is present in each case, and whether it is present when a
`.sha256` file name is typed manually into the archive-name field.

---

## Addendum — decisions made while building M2 (the AppKit shell)

These were settled against the running app, not on paper.

### D-M2-1. Size columns show exact grouped byte counts, not "1.2 MB"

7zFM's Size column is a raw count with digit grouping, and ArcSeven matches it. The
temptation on macOS is `ByteCountFormatter` and "48 KB", but in an archive manager the
whole point of the Size and Packed Size columns is to compare them against each other.
Rounded values make that comparison meaningless — `50,000` vs `40,680` tells you
something; "50 KB" vs "41 KB" tells you much less. Implemented with `FormatStyle`
rather than `NumberFormatter`, which is not `Sendable` and cannot be a shared static
under Swift 6.

**Reversible?** Yes — a Settings toggle, once the Settings pane grows one.

### D-M2-2. Directories report no size at all, rather than zero

7-Zip stores `Size = 0` for directory entries. Rendering that literally puts a "0" in
every folder row and, worse, clumps every folder at one end of a size sort. Directories
return `nil` for both Size and Packed Size, so the cell is blank and the sort places
them via the "missing sorts last" rule.

**Reversible?** No reason to.

### D-M2-3. The panel opens focused but with NOTHING selected

The list takes first responder so the arrow keys work immediately — a file manager that
ignores the keyboard until you click feels broken.

It does **not** pre-select a row, and that distinction is load-bearing. Every operation
follows 7zFM's rule that an empty selection means "act on everything": Extract with
nothing selected extracts the whole archive, Test tests every member. An earlier build
auto-selected the first row for keyboard convenience and thereby made that rule
unreachable — testing a 12-member archive reported "7 items verified" because the
first folder happened to be selected. An empty selection is meaningful state.

7zFM distinguishes the *focus rectangle* from *marked* items (Space / Insert). ArcSeven
currently has only `NSTableView` selection, which plays the "marked" role. A separate
focus-vs-marked model is deferred; see the Space-key open question in this document.

**Reversible?** The behaviour is deliberate, but the focus/marked split should land.

### D-M2-4. Toolbar actions not yet implemented say so

Add / Test / Copy / Move / Delete present an explicit "not implemented yet" sheet naming
the milestone. A button that silently does nothing reads as a bug; one that says what it
is waiting for does not.

**Reversible?** Removed as each action lands.

---

## Build-system note: the `module-guard` idiom

`Package.swift` builds six modules (`ArchiveCore`, `FMKit`, `FMUI`, `Dialogs`,
`SettingsUI`, `Support`); the Xcode target generated from `project.yml` compiles the
same files into **one** module. Xcode cannot consume a local Swift package rooted at the
project's own directory — the generated `packageProductDependencies` come out empty — so
the two build systems genuinely disagree about module boundaries.

Intra-project imports are therefore written as:

```swift
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
```

True under SwiftPM, false under Xcode where the types are already in scope. One copy of
every source file, both build systems working, and `swift test` exercises exactly the
sources the app ships. Grep for `module-guard` to find every instance.

**Any new file that imports a sibling module must use this form**, or the app target
fails with "Unable to resolve module dependency".

## D-0.1.4-1 — "Extract Here" decides where to put things

**Windows 7zFM.** `Extract Here` extracts into the current folder, unconditionally. A
scattering archive scatters.

**ArcSeven.** `Extract Here` inspects the archive first. One top-level item — a folder, or
a single file — extracts loose, because the archive already provides its own containment
and wrapping it produces `project-1.0/project-1.0/…`. Two or more top-level items are
wrapped in a folder named after the archive.

**Why.** The two failure modes are not symmetric. An unwanted wrapper is one drag to undo.
Forty loose files landing in Downloads, mixed with everything already there, cannot be
undone by hand — nothing afterwards distinguishes what just arrived. And the person
clicking cannot know which kind of archive it is before it opens; the command is chosen
from habit, not from knowledge of the root-entry count.

An unreadable listing — encrypted headers, a corrupt archive — wraps, for the same reason.

Three commands, in the Finder submenu and in Services:

| Command | Wrapper folder |
| --- | --- |
| `Extract Here` | Only when the archive would otherwise scatter |
| `Extract Loose` | Never |
| `Extract to Subfolder` | Always |

Windows 7zFM's own `Extract Here` is the unconditional one, so `Extract Loose` is the
faithful behaviour and `Extract Here` is the divergence. It keeps the name because it is
the right default for a command people click from habit, and because the archive it is
pointed at is usually self-contained, where the two agree exactly.

**On the name.** `Extract Loose`, not "Extract Without Folder": 7-Zip already uses "without
folder structure" for `-e`, which flattens the paths *inside* the archive so `src/a.txt`
and `docs/a.txt` collide as `a.txt`. That is `ExtractPathMode.noPaths` and a different
setting entirely. Every one of these three preserves the archive's internal structure; they
differ only in whether a wrapper is created around it.

Until 0.1.4 both Services verbs called the same code and both wrapped, so `Extract Here`
was the one that lied.

`-spe` (`eliminateRootDuplication`) is 7-Zip's own partial answer and remains available; it
only fires when the root folder's name matches the archive's, so it misses `archive.zip`
containing `src/`.

## D-0.1.6-1 — the overwrite prompt offers only answers it can honour

**Windows 7zFM.** `Confirm File Replace` appears per file, so `Yes` overwrites that one
file and the next collision asks again.

**ArcSeven.** The subprocess engine has no interactive channel once `7zz` is running, so a
decision has to become one `-ao*` switch for the whole extraction. Conflicts are therefore
resolved before the child is spawned, and the sheet offers only the answers that describe
what will actually happen:

| Collisions found | Buttons |
| --- | --- |
| Exactly one | `Yes`, `No`, `Cancel` — they mean what they say |
| More than one | `Yes to All`, `No to All`, `Auto Rename`, `Cancel` |

`Return` is bound to the safe answer, never the destructive one.

**Why.** Through 0.1.5 all six buttons were shown in every case and `Yes` was mapped to
`-aoa`. A sheet naming a single file, answered with the button that means "this one",
overwrote every colliding file in the run — silently, and with no way to discover which
files had been replaced. The buttons existed to be honest about a per-file decision the
engine cannot make; withdrawing them is the fix, because the alternative is a button that
means something other than what it says.

A true per-file prompt needs the in-process engine, and is not scheduled.
