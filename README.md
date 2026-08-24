<!--
SPDX-FileCopyrightText: 2026 Rajesh D'Monte
SPDX-License-Identifier: GPL-3.0-or-later
-->

# ArcSeven

A native macOS reimplementation of the Windows 7-Zip File Manager (`7zFM.exe`), written from
scratch in Swift 6 and AppKit.

**This is not 7-Zip.** It is not a port, not a fork, not an official build, and not a rebranding.
It is a clean-room reimplementation of 7zFM's *user interface* — its column model, its sort
comparator, its dialogs, its status-bar formulas — that drives the real, unmodified 7-Zip console
binary as a subprocess. It is not affiliated with, endorsed by, or sponsored by the 7-Zip project
or Igor Pavlov. See [Trademarks](#trademarks).

---

## Status

**Pre-alpha. Milestone M2 is complete. There is no release, and nothing has been published.**

What that means in practice: the app builds, launches, opens an archive from Finder and lets you
browse and extract it. It is not yet a file manager. The Add / Test / Copy / Move / Delete dialogs
are written and tested as code but are only being wired to the toolbar now, so the buttons that
have no implementation behind them say so explicitly instead of doing nothing.

Do not use this on data you care about yet.

- 197 tests across 15 suites pass.
- Four commits: initial, M0 (engine layer + compliance tree), M1 (vendored `7zz`, engine verified
  against the real binary), M2 (the AppKit shell).
- The roadmap, the 72-row fidelity matrix against Windows 7zFM and the module breakdown live in
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Deliberate departures from the Windows original
  are in [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md). The `7zz` command-line contract, including
  the corrections found by running the real binary, is in
  [`docs/ENGINE-PROTOCOL.md`](docs/ENGINE-PROTOCOL.md).

---

## What works today

Verified by running the app and reading the screen, not by assuming.

- **Launching and opening.** Double-clicking a `.7z` in Finder opens it. So does `File ▸ Open…`,
  `open -a ArcSeven <path>`, and dropping a path on the Dock icon.
- **Filesystem browsing.** The window opens on your home directory. Double-clicking a folder
  descends into it; double-clicking a recognised archive descends *into the archive*.
- **Archive interior browsing, including nested directories.** The archive is listed once with
  `7zz l -slt` and every directory level is pure computation over that one snapshot — there is no
  "list one directory" operation in 7-Zip, and spawning a process per click would be both slow and
  wrong. Directories that have no entry of their own (anything written by `zip -D`, most `tar`
  streams) are synthesised, or such archives open empty.
- **The list.** A view-based `NSTableView` driven by an explicit data source, with a per-folder-type
  column set. Cells exist for visible rows only, which is the only thing that stays responsive at
  the row counts archives reach.
- **7zFM's sort order, not Finder's.** `..` pinned first; folders above files in *both* directions
  (reversing reverses within each group); natural numeric name comparison, so `file1`, `file2`,
  `file3`, `file10`, `file20`; a deterministic tiebreak. Click a column header to sort by it.
- **Path bar and status line.** Folder/file counts and byte totals for the level, plus a selection
  summary. Sizes are exact grouped byte counts, not "1.2 MB" — see
  [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md) D-M2-1 for why.
- **Extract.** Pick a destination, watch a progress sheet, get a completion summary with a
  *Reveal in Finder* button. Exit code 1 is treated as **success with warnings** — never a failure —
  and the warnings are shown rather than swallowed.
- **Get Info** on an open archive: path, format, file and folder counts, size, physical size,
  compression ratio, solid, encrypted.
- **A second panel** can be toggled on. It browses the filesystem; copy and move between panes do
  not exist yet.
- **Keyboard.** Arrow keys move the selection, `⌘↓` opens it, `⌘↑` goes to the enclosing folder.
  The list takes focus when a folder loads, so the arrow keys work before you click anything.
  (Plain `Return` is not bound yet — use `⌘↓` or double-click.)
- **The engine.** `SevenZipCLIEngine` drives the bundled `7zz`: paths passed via an `@listfile`
  with `-scsUTF-8`, progress parsed from a backspace-delimited stream, `l -slt` parsed by a
  state machine, cancellation by killing the process group. Passphrases for read operations go
  on **stdin**, never argv, so they are never visible in `ps`.

Current key equivalents are hard-coded. The keymap engine with Finder / Commander / Classic
presets is not built yet.

---

## Not yet

Honest list. Everything here is either unwritten or written-but-not-reachable.

**Written, being wired up now**

- **Add to Archive.** `Sources/Dialogs/CompressDialogController.swift` and `CompressDialogModel.swift`
  exist — per-format level masks, method arrays, dictionary and word-size enumerations, the memory
  estimator, volume-size grammar. Nothing on the toolbar reaches them yet.
- **Test, Copy, Move, Delete.** Same state.
- **Extract, Overwrite, Password and Properties dialogs.** Written. Extraction today uses a plain
  `NSOpenPanel` and a fixed auto-rename overwrite mode instead of the real Extract dialog.
- **Settings.** Six panes exist under `Sources/SettingsUI`; the window is not reachable from the
  menu bar yet.
- **Persistence.** `FavoritesStore`, `FolderHistoryStore` and `PanelPreferences` are implemented and
  tested in `Sources/FMKit/Stores`. No UI reads or writes them, so nothing survives a relaunch —
  not column widths, not the sort, not the window's folder.
- **Drag out of an archive.** `Sources/FMUI/DragController.swift` implements the
  `NSFilePromiseProvider` path — nothing is decompressed until a drop actually completes. The panel
  does not offer it yet. Dragging *into* a panel is not written at all.

**Not written**

- **Nested archives.** Inside an archive, only directories are navigable. Opening an archive that
  is *inside* another archive does not work.
- **Opening a member.** No Quick Look, no viewer, no temp-file open/edit write-back.
  `engine.readEntry(_:)` already streams a member's bytes without touching disk; nothing calls it.
- **Password prompting in the browse path.** The engine handles passwords correctly; the UI does
  not prompt. An archive with encrypted headers currently reports "could not open" instead of
  asking.
- **View modes.** Details only — no Large Icons / Small Icons / List, no Flat View.
- **Rename, Create Folder, Create File, select-by-mask, alternative selection mode, in-place
  archive update, benchmark, checksums, split/combine, archive comment, SFX.**
- **System integration.** Both app-extension targets exist in `project.yml` and are embedded by the
  app target, but they are shells: `Extensions/QuickActions` is an `Info.plist` and an entitlements
  file with no code, and `Extensions/QuickLookPreview` has only just started (a model and a
  byte-reading layer, no `QLPreviewingController`). Nothing is registered with the system yet — no
  Quick Look preview, no Finder Quick Actions, no Services, no Shortcuts, no Spotlight importer.
- **Support services on the extract path.** `Quarantine` and `ThreadPlanner` are implemented and
  tested but extraction does not call them yet, so quarantine is not propagated to extracted files
  and thread counts are not tuned.
- **Distribution.** The sign → notarize → staple → verify pipeline is wired in
  `.github/workflows/release.yml` and has never produced a release. No DMG, no Sparkle appcast, no
  Homebrew Cask. Replacing the bundled `7zz` with your own build is a planned setting that does not
  exist; today the app looks for `Contents/Helpers/7zz` and falls back to `vendor/bin/7zz` in a
  development checkout.

---

## How it works

**ArcSeven does not contain 7-Zip.** It ships the 7-Zip console program `7zz` — a build of
**unmodified upstream source** — as a separate executable at
`ArcSeven.app/Contents/Helpers/7zz`, and drives it as a subprocess over argv, stdin and stdout.
No 7-Zip code is linked, embedded, patched or copied into this repository.

That is a licensing constraint, not a style preference. 7-Zip's RAR decompression derives from
unRAR, whose licence carries a **use restriction** (see [unRAR restriction](#unrar-restriction)).
A use restriction is not a copyleft condition; it is an *additional restriction*, which GPLv3 §7
classifies as a "further restriction" and §10 forbids imposing. Linking RAR-capable 7-Zip code
into a GPL-3.0 application would therefore be a violation. Running the stock `7zz` as a separate
program is mere aggregation — pipes, argv and `fork`/`exec` are the FSF's own examples of
communication between two separate programs. So the engine boundary is a hard architectural rule:
**RAR-capable code never enters the GPL boundary.**

**Vendoring.** `vendor/7zip` is a git submodule pinned to [ip7z/7zip](https://github.com/ip7z/7zip)
**26.02** (`f9d78aff31a5f2521ae7ddbdc97c4a8855808959`). `vendor/build-7zz.sh` builds it with
upstream's own makefiles — `cmpl_mac_arm64.mak` and `cmpl_mac_x64.mak`, zero patches — `lipo`s the
two slices into a universal binary, executes both slices, checksums the result and writes a
provenance stamp. It **refuses to build a modified tree** without an explicit, loud override. The
output lands in the git-ignored `vendor/bin/`: a reproducible build input, not a committed artefact.

**The engine layer** (`Sources/ArchiveCore`) is written against the `ArchiveEngine` protocol from
the first commit, with `SevenZipCLIEngine` as the only implementation, so a future in-process
engine can be swapped in without touching the UI. Exit code 1 is success-with-warnings. Exit 255 is
overloaded and disambiguated by output. Cancellation signals the process group, then drains and
reaps — never kill and walk away.

**Corrections found by driving the real 26.02 binary**, recorded in
[`docs/ENGINE-PROTOCOL.md`](docs/ENGINE-PROTOCOL.md) Appendix A, which overrides the body of that
document wherever the two disagree:

- A bare `-p` means an **empty** password and suppresses the prompt. It does not read stdin.
- Omitting **both** `-y` and `-p` makes `7zz` prompt and read the passphrase from stdin, with no
  TTY required. Read operations use that path, and must therefore pass an explicit `-ao*` so no
  other prompt can block the child.
- **`-mem=` is ZIP-only.** The `.7z` handler rejects it with `E_INVALIDARG`; 7z is AES-256
  implicitly.
- **Creation has no prompt at all.** Piping a passphrase to `7zz a` silently produces an
  **unencrypted** archive and exits 0. Creation puts `-p<pw>` on argv and every created archive is
  verified afterwards.

**Modules.** `ArchiveCore` (engine, parsers, models — no AppKit) · `FMKit` (file-manager domain —
no views) · `Support` (zip-slip guard, path normalisation, quarantine, trash, thread planning) ·
`FMUI` (the window and panel) · `Dialogs` · `SettingsUI` · `App`.

---

## Requirements

|  |  |
|---|---|
| **macOS (to run)** | 14.0 Sonoma or later |
| **macOS (to build)** | 15.0 or later, because Xcode 26 needs it |
| **Architecture** | Universal 2 — Apple Silicon (`arm64`) and Intel (`x86_64`) |
| **Toolchain** | Xcode 26 (macOS 26 SDK), Swift 6 strict concurrency, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftLint](https://github.com/realm/SwiftLint) |

The Swift module and Xcode target are named **`ArcSeven`** — Swift module names cannot begin with a
digit. The bundle identifier root is `com.havokentity.ArcSeven`.

---

## Building

```bash
git clone --recurse-submodules https://github.com/havokentity/ArcSeven.git
cd ArcSeven
Scripts/bootstrap.sh
```

`Scripts/bootstrap.sh` does six things and is idempotent: checks Xcode, Swift, the SDK and git
against the project minimums; configures and pins the `vendor/7zip` submodule; runs
`vendor/build-7zz.sh`; installs XcodeGen if missing — **asking first, never silently**; generates
`ArcSeven.xcodeproj` from `project.yml`; prints next steps.

The same thing by hand:

```bash
./vendor/build-7zz.sh                 # universal 7zz -> vendor/bin/7zz  (also: --check, --clean)
xcodegen generate                     # project.yml -> ArcSeven.xcodeproj
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven -configuration Debug build
```

`ArcSeven.xcodeproj` is generated and never committed. Re-run `xcodegen generate` after changing
`project.yml` or adding a source file, and never patch the project file by hand.

If `7zz` has not been built, the app tells you so on launch and quits — a missing helper is a build
problem, not a user error.

### Tests

```bash
swift test
```

197 tests across 15 suites. This runs `ArchiveCoreTests`, `FMKitTests` and `SupportTests` from
`Package.swift` — **no Xcode project, no code signing, no app bundle**, which is exactly what CI
exercises on every push, including pull requests from forks that never see repository secrets.

Two of the suites are live: *Live 7zz engine* and *Live archive navigation* build real archives
with the vendored binary and drive them end to end. Both carry an `.enabled(if:)` trait that
**skips the suite when `vendor/bin/7zz` has not been built**, so a bare checkout still passes. Run
`./vendor/build-7zz.sh` to include them — and re-run them on every upstream version bump, which is
the whole reason they exist.

`swift build` compiles all six library modules, AppKit ones included. What it cannot produce is the
app itself — `Sources/App`, the bundle, the `7zz` copy phase and the two extensions exist only in
the Xcode project:

```bash
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven build
```

---

## Build systems: the `module-guard` idiom

**Read this before adding a file.** The project is compiled by two build systems that genuinely
disagree about module boundaries:

- `Package.swift` builds **six** modules — `ArchiveCore`, `FMKit`, `Support`, `Dialogs`,
  `SettingsUI`, `FMUI`.
- The Xcode target generated from `project.yml` compiles the same files into **one** module.

This is not laziness. Xcode cannot consume a local Swift package rooted at the project's own
directory — the generated `packageProductDependencies` come out empty — so the app target has to
compile the sources directly. Keeping both build systems pointed at the same directories means
there is exactly one copy of every source file, and `swift test` exercises precisely the sources
the app ships.

Every intra-project import is therefore written as:

```swift
#if canImport(ArchiveCore)   // module-guard
import ArchiveCore
#endif
```

True under SwiftPM; false under Xcode, where the types are already in scope. Apply it to
`ArchiveCore`, `FMKit`, `FMUI`, `Dialogs`, `SettingsUI` and `Support` — **not** to `AppKit`,
`Foundation` or anything else from the SDK.

**A new file that imports a sibling module without this form fails the app target** with
"Unable to resolve module dependency". Grep for `module-guard` to find every instance.

---

## Roadmap

Landed, one commit each:

| | |
|---|---|
| **M0** | Foundations — compliance tree, `ArchiveCore`, the `7zz` command-line contract |
| **M1** | Vendored `7zz` 26.02 as a pinned submodule; engine verified against the real binary |
| **M2** | The AppKit shell — window, panel, sort, path bar, status bar, browse and extract |

Immediately next: connecting the dialogs that already exist — Add, Test, Copy, Move, Delete, the
real Extract and Overwrite dialogs, password prompting, the Properties inspector, and the Settings
window.

After that, in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §2's order: full file manager →
full authoring → settings and system integration (**v1.0**) → an in-process engine over a
`7z.dylib` built without the RAR handlers → archive diff, convert/recompress, a persistent queue,
tabs, Shortcuts and Spotlight.

**The numbering has drifted from that document.** §2 scheduled the browser-and-extract build as M1
and the full file manager as M2; in practice the vendoring and engine-verification work earned a
milestone of its own, so the shipped M2 is what §2 calls M1. The architecture document remains the
plan of record for what each milestone *contains*.

---

## Licence

**ArcSeven is free software, licensed under the
[GNU General Public License, version 3 or (at your option) any later version](LICENSE)** —
SPDX: `GPL-3.0-or-later`.

Copyright (C) 2026 Rajesh D'Monte.

> This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
> without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
> See the GNU General Public License for more details. You should have received a copy of the
> GNU General Public License along with this program. If not, see
> <https://www.gnu.org/licenses/>.

Every first-party source file carries `SPDX-License-Identifier: GPL-3.0-or-later`.

### The bundled 7-Zip binary (`7zz`)

ArcSeven ships the **7-Zip console program `7zz`, unmodified, as a separate executable** in
`ArcSeven.app/Contents/Helpers/`, and invokes it as an independent process via command-line
arguments. ArcSeven does not link against, embed, or modify any 7-Zip code. The two are separate
programs distributed together as an aggregate.

As 7-Zip's own `license.txt` requires of binary redistributors, and as its FAQ asks:

1. **This product uses parts of the 7-Zip program.**
2. **7-Zip is licensed under the GNU LGPL** (version 2.1 or later), with portions under the
   BSD 3-clause and BSD 2-clause Licenses, and with the "unRAR license restriction" applying to
   the RAR decompression code.
3. **7-Zip source code is available from <https://www.7-zip.org>.**

7-Zip Copyright (C) 1999–2025 Igor Pavlov.

**Source offer for the LGPL binary we redistribute.** LGPL-2.1 §4 is satisfied by "equivalent
access to copy the source code from the same place": the exact upstream source archive matching the
`7zz` in each release (e.g. `7z2602-src.tar.xz`) is attached as an asset to the **same GitHub
Release** that carries the `.dmg`. We mirror the tarball ourselves rather than merely linking to
7-zip.org, so the offer cannot rot. The exact version, both SHA-256 checksums and the upstream URL
are recorded in [`THIRD_PARTY_LICENSES/7-Zip/VERSION.txt`](THIRD_PARTY_LICENSES/7-Zip/VERSION.txt),
along with the line that does the real work: `Modifications: NONE`. No release has been published
yet; the mechanism is wired into `.github/workflows/release.yml` and will be exercised by the first
one.

Full texts live in [`THIRD_PARTY_LICENSES/`](THIRD_PARTY_LICENSES/) and in [`NOTICE`](NOTICE); both
are copied into `ArcSeven.app/Contents/Resources/Legal/` so that someone who downloads only the DMG
can read every notice without visiting GitHub.

---

## unRAR restriction

7-Zip's RAR decompression engine derives from the unRAR program, all copyrights to which are owned
by Alexander Roshal. Its license carries a **use restriction**, quoted here verbatim from
<https://www.7-zip.org/license.txt> because that license requires the statement to appear in the
documentation of anything that redistributes the code:

```
unRAR license restriction
-------------------------

The decompression engine for RAR archives was developed using source
code of unRAR program.
All copyrights to original unRAR code are owned by Alexander Roshal.

The license for original unRAR code has the following restriction:

  The unRAR sources cannot be used to re-create the RAR compression algorithm,
  which is proprietary. Distribution of modified unRAR sources in separate form
  or as a part of other software is permitted, provided that it is clearly
  stated in the documentation and source comments that the code may
  not be used to develop a RAR (WinRAR) compatible archiver.
```

**Consequently: RAR is extract-only in ArcSeven.** ArcSeven reads RAR archives by invoking the
bundled `7zz`; it cannot create them, and there is no "create RAR" affordance anywhere in the user
interface. This is not a missing feature we intend to add later — the Windows 7-Zip File Manager
cannot create RAR archives either, for the same reason.

Fedora's licensing determination is blunter than ours: the unRAR license "has use-restrictions that
make it GPL-Incompatible and non-free." That is why the subprocess boundary described in
[How it works](#how-it-works) is architecture rather than preference. The planned M5 in-process
engine will link a `7z.dylib` built **without the RAR handlers**; `.rar` will continue to route to
the `7zz` subprocess forever.

---

## Trademarks

**ArcSeven is not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov.**

"7-Zip" is referenced here solely and descriptively, to state compatibility and to identify the
software whose behaviour is being reimplemented — never possessively and never as an official
designation. ArcSeven is an independent work by Rajesh D'Monte. It ships no 7-Zip artwork, icon, or
trade dress, and it is not "7-Zip for Mac".

Behaviour is specified by reading the upstream resource scripts and implementation sources
(`CPP/7zip/UI/FileManager/resource.rc`, `PropertyName.rc`, `PanelKey.cpp`, `PanelSort.cpp`,
`CPP/7zip/UI/GUI/CompressDialog.rc`, …) at
[`github.com/ip7z/7zip`](https://github.com/ip7z/7zip), describing what they do, and reimplementing
it. No upstream code is copied into this repository. See
[CONTRIBUTING.md](CONTRIBUTING.md#clean-room-rule-non-negotiable).

"7-Zip" and "WinRAR" are the property of their respective owners. All other trademarks are the
property of their respective owners.

---

## Why not the Mac App Store

Because the GPL and Apple's store terms are incompatible, and no amount of paperwork fixes it.
Every Mac App Store app is licensed to the user under Apple's Licensed Application EULA, which
grants a "nontransferable" license and states that "you may not transfer, redistribute or
sublicense the Licensed Application", subject further to Usage Rules that cap installs to a set of
approved devices. Redistribution is the *core* freedom the GPL grants and GPLv3 §10 specifically
forbids imposing further restrictions on it — this is exactly the argument the FSF used to have GNU
Go pulled in 2010, and why VLC was removed in 2011 and only returned after relicensing. Downgrading
to GPL-2.0 buys nothing, since GPLv2 §6 says materially the same thing; and the bundled LGPL `7zz`
raises the same problem from the other direction, because LGPL-2.1 §6 requires that users be able to
relink a modified library, which a sandboxed, store-signed binary cannot allow.

So ArcSeven will ship as a Developer ID–signed, notarized, stapled DMG plus a Homebrew Cask —
which, as a bonus, keeps the app out of the App Sandbox, an environment fundamentally at odds with
a whole-disk two-pane file manager. The signature is a convenience for *our* build, not a lock on
yours: you can always build, sign and run your own modified copy.

---

## Related projects

The field is not empty, and this project would be dishonest to pretend otherwise. ArcSeven is
pre-alpha; every project below is finished software you can use today. **If one of these does what
you need, use it.**

- **[ShichiZip](https://github.com/idawnlight/ShichiZip)** — LGPL-2.1, Swift + Objective-C++ over
  the upstream 7-Zip C++ tree. **The closest existing thing to this project by a wide margin**, and
  the one to evaluate first. It already ships dual panes, Finder/Commander shortcut presets,
  `NSFilePromiseProvider` drag-out-of-archive, a Quick Look preview extension, four App
  Intents–backed Finder Quick Actions, a benchmark window, folder history, ten favourite slots, full
  codec control, in-place archive modification and Dock-icon progress — that is, most of what
  ArcSeven has scheduled for M2 through M4. ArcSeven's *intended* differentiators against it are
  Shortcuts/Siri automation, a Spotlight importer, window tabs, live in-archive filtering,
  Keychain/Touch ID passwords, a persistent pausable queue, convert/recompress, archive diff, and
  signing + notarization + auto-update. None of those exist yet.
- **[Keka](https://www.keka.io/)** — the best-loved Mac archiver, and the reason most people do not
  need this app. It is **not open source**: the source was closed years ago, and `aonez/Keka` is the
  website, translations and issue tracker. It is also, deliberately, *not a file manager* — it
  cannot browse inside an archive at all, which is the single most-requested thing it does not do.
  Keka is the model for macOS-native polish; it is not prior art for the file-manager half.
- **[The Unarchiver](https://theunarchiver.com/)** — proprietary since the 2017 MacPaw acquisition;
  only the [XADMaster](https://github.com/MacPaw/XADMaster) engine and the `unar`/`lsar` CLI tools
  remain LGPL-2.1. Unbeatable at *opening obscure formats*, and cannot create archives at all. Its
  companion Archive Browser, which did browse archives, is discontinued.

Also worth naming: **[PeaZip](https://peazip.github.io/)** (LGPL-3.0, real Cocoa macOS builds, but
shipped unsigned so users must strip the quarantine attribute by hand),
**[muCommander](https://www.mucommander.com/)** (GPL, JVM, true F5/F6 two-pane),
**[Double Commander](https://doublecmd.sourceforge.io/)** (GPL-2.0, Free Pascal/Lazarus, WCX packer
plugins), and the commercial natives **BetterZip 6**, **Commander One**, **ForkLift 4** and
**Archiver 4**.

---

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) first — in particular the clean-room rule, which is not
boilerplate, and the `module-guard` requirement above, which will break your build if you skip it.
Contributions are inbound = outbound under `GPL-3.0-or-later`, with a DCO sign-off and no CLA. Bug
reports and fidelity discrepancies against Windows 7zFM are especially welcome.
