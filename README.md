<!--
SPDX-FileCopyrightText: 2026 Rajesh D'Monte
SPDX-License-Identifier: GPL-3.0-or-later
-->

# ArcSeven

**A native macOS reimplementation of the Windows 7-Zip File Manager (`7zFM.exe`), plus the Mac-native features it never had.**

---

## What this is / what this is not

**What this is.** A clean-room reimplementation of the 7-Zip File Manager's *user interface* — its
two-pane layout, its column model, its sort comparator, its dialogs, its menus, its status-bar
formulas — written from scratch in Swift 6 and AppKit. Behaviour is specified by reading the
upstream resource scripts and implementation sources (`CPP/7zip/UI/FileManager/resource.rc`,
`PropertyName.rc`, `PanelKey.cpp`, `PanelSort.cpp`, `CPP/7zip/UI/GUI/CompressDialog.rc`, …) at
[`github.com/ip7z/7zip`](https://github.com/ip7z/7zip), describing what they do, and reimplementing
it. No upstream code is copied into this repository. See
[CONTRIBUTING.md](CONTRIBUTING.md#clean-room-rule-non-negotiable).

**What this is not.**

- **This is not 7-Zip.** It is not a port, not a fork, not an official build, and not a rebranding.
- **It is not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov.**
- **The compression engine is not ours.** ArcSeven bundles the *stock, unmodified, upstream* `7zz`
  console binary in `ArcSeven.app/Contents/Helpers/` and drives it as a **separate process** over
  argv/stdout. We do not link, embed, patch, or vendor 7-Zip code. `7zz` and ArcSeven are two
  programs distributed together as an aggregate — which is exactly what keeps ArcSeven's GPL licensing
  valid while RAR support is present (see [unRAR restriction](#unrar-restriction)).

---

## Status

> **Pre-alpha — milestone M0 (Foundations). There is no shippable app yet.**

M0 is scaffolding and de-risking only: repository layout, licensing and compliance files,
the `ArchiveEngine` protocol and its `7zz` subprocess implementation, the `l -slt` listing parser,
the golden-file test corpus, and the sign → notarize → staple CI pipeline. **No user interface
exists.** The first genuinely usable build is M1 (single-pane browser + extract), tagged `v0.1`.

The full milestone roadmap, the 72-row fidelity matrix against Windows 7zFM, and the module
breakdown live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Deliberate departures from the
Windows original are recorded in [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md).

Nothing in the tables below is implemented today. The **Milestone** column says when each item is
scheduled, so the table doubles as the plan of record.

---

## Features

### 1:1 with Windows 7zFM

Behaviour reproduced exactly — same semantics, same defaults, same quirks. *Fidelity is about
semantics, not pixels:* we do not reproduce Win32 dialog-unit geometry, modal property sheets, or
F-key defaults that are hostile on Mac hardware.

| Feature | Fidelity notes | Milestone |
|---|---|---|
| **Two-pane manager** with 4 px splitter, position stored as a ratio out of `1<<16`, proportional on resize | Default is **one** pane — `kNumDefaultPanels = 1`, which is 7zFM's real default, not the two panes the manual implies | M2 |
| **Archive-as-folder browsing, including nested archives** — `Open Inside`, `Open Inside *` (`-t*`), `Open Inside #` (`-t#`), `Open Outside` | Same `7zO`-prefixed temp-dir model; the title bar accumulates `…/outer.7z/inner.zip/` | M1–M2 |
| **Full column model** — the ~100 property names from `PropertyName.rc`, per-folder-type column sets | Name = 160 px, everything else = 100 px; dates left-aligned, integers right, unknown types centered; header menu with **Name (index 0) greyed**; order/width/visibility persisted per folder-type ID | M1 |
| **The exact sort comparator** | `..` first → folders first (both immune to descending) → sort PROPID → cascade `sortProp → kpidName → kpidPrefix` → stable enumeration-order fallback → *then* negate. Natural numeric name compare, case-insensitive, leading zeros stripped, run length first — deliberately **not** Finder's collation | M1 |
| **Per-pane path bar + 4-part status bar** at 220 / 320 / 420 / flex | 7zFM's exact formulas and empty-string rules: `"<n> / <total> object(s) selected"`, operated-size, focused-item size, focused-item mtime | M1 |
| **View modes** Large Icons / Small Icons / List / Details (`⌘1`–`⌘4`), Details default, per-pane persistence | 1:1 | M1 |
| **Flat View** with separate state for disk and archive; `..` row (default off, never in root) | 1:1 | M2 |
| **Extract dialog** with path modes, overwrite modes and password | Includes the sticky-`kCurPaths` quirk: a caller-supplied `kCurPaths` survives if the user leaves *Full pathnames* selected | M1 |
| **Overwrite dialog** — 6 buttons, 4-line per-file information block | 72-character midpoint elision, quote-wrap on trailing space, dual icon slots | M1 |
| **Progress window** — all ten value fields, Background / Pause / Cancel with caption swaps | Error list hidden until the first error; `Cancel` becomes `Close` on completion | M1 |
| **Add to Archive dialog**, complete | Per-format level masks (7z 0–9, Zip 0/1/3/5/7/9, GZip 1/5/7/9, BZip2 1/3/5/7/9, xz 1–9, tar/wim 0), per-format method arrays with the `"*  "` auto prefix, the LZMA/PPMd/BZip2/Deflate dictionary and word-size enumerations, solid block size, thread count with memory-driven auto-reduction, the **memory-usage estimator reproduced formula-for-formula**, `-mmemuse`, the space-separated volume-size grammar where `-` terminates parsing, free-text Parameters with `-m` stripping and method-override detection, update mode, path mode, SFX, AES-256 and encrypted headers | M3 |
| **In-place archive update** — add, delete, rename, mkdir inside an open archive | 1:1 | M3 |
| **Temp-file open/edit write-back** | Including the deliberate quirk that modified-but-declined temp files are *left on disk* — which is precisely why `Tools ▸ Delete Temporary Files…` exists | M3 |
| **Test archive** | Exact OK message block: `Archives:` / `Packed Size:` / `Folders:` / `Files:` / `Size:` / `There are no errors` | M3 |
| **Checksum submenu**, 11 entries in exact order | CRC-32, CRC-64, XXH64, MD5, SHA-1, SHA-256, SHA-384, SHA-512, SHA3-256, BLAKE2sp, `*`; uppercase digests for ≤ 8 bytes, lowercase above, `-<extra>` group suffix | M3 |
| **Benchmark window** | Dictionary, threads, passes, compress/decompress current + resulting, CPU usage, rating, total rating, log column, Restart/Stop — driving `7zz b` | M3 |
| **Split file / Combine files** on arbitrary files | Same volume-size grammar and confirmation | M3 |
| **Properties** | Exact assembly order: item props → `----------------` → folder props → `------------------------` → per-archive-level props; `⌘C` copies `Name: Value` lines | M2 |
| **Archive comment** | Same silent-abort rule for non-`VT_BSTR`/`VT_EMPTY`, same `Set Comment Error` title | M3 |
| **Favorites (10 slots) and Folders History** | Same `-` rendering for empty slots, same midpoint ` ... ` elision past 100 characters | M2 |
| **Selection** — Select All / Deselect All / Invert / Select… / Deselect… by wildcard mask / by type | All six commands kept; numpad `+`/`-`/`*` bindings live in the Classic preset only | M2 |
| **Alternative selection mode** (Norton marks, `Insert` toggles and advances, `Shift`+arrow sweeps) | Same model, same default (off) | M2 |
| **Options panes** — Folders (working folder), Editor (Viewer / Editor / Diff paths), Settings | Every default preserved, including *Show ".." off*, real file icons off, full row select off, grid lines off, single click off | M4 |
| **Defaults keys mirror `HKCU\Software\7-Zip\FM`** | `NSUserDefaults` under `com.havokentity.ArcSeven` using the *same key names and value semantics*, so persistence is auditable against the Windows original | M1+ |
| **RAR is read-only** | 7zFM cannot create RAR either. See [unRAR restriction](#unrar-restriction) | M1 |
| **"7-Zip Classic" keymap preset** | Opt-in preset restoring F5 / F6 / F7 / F8 / F9 muscle memory. Mac-native shortcuts are the default, because function keys are `fn`-key hostages on Mac keyboards and `Return` means *rename*, not *open* | M2 |

### macOS additions

Every one of these is **additive** — none changes a 1:1 behaviour.

| Feature | What it does | Milestone |
|---|---|---|
| **Drag out of an archive without extracting first** | `NSFilePromiseProvider`, with **solid-archive batch coalescing**: the first `writePromiseTo:` callback gathers every pending promise in the drag session, runs one `7zz x` into a staging directory, and satisfies each promise from staging. The naive per-callback implementation is O(n · archive_size) and appears to hang forever | M2 |
| **Quick Look, both directions** | `QLPreviewPanel` on Space inside the app, plus a Finder **preview extension** that renders the archive *listing* — header parse only, never decompression, file closed before render, with size caps | M1 / M4 |
| **App Intents Quick Actions** | Finder Quick Actions for Open archive, Extract Here, Extract to "name", Extract to…, Add to "name.7z", Add to archive…, Test archive, Compute checksum. **Authenticated transport only** — App Group inbox with a per-request nonce, or `NSXPCConnection` with `setCodeSigningRequirement(_:)` validating the Team ID. Never an unauthenticated URL scheme naming a pasteboard | M4 |
| **Shortcuts / Siri automation** | A real `AppShortcutsProvider`: `CompressFiles`, `ExtractArchive`, `ListArchiveContents` (with an `AppEntity`), `TestArchive`, `ConvertArchive`, `HashFiles`, `ExtractMatchingEntries` | M6 |
| **Archive diff** | Left pane archive A, right pane archive B or a folder. Compares the path set, size, mtime and **CRC-32 — which `7zz l -slt` already reports, with zero extraction**. Colours rows added / removed / changed / identical, filters to differences, offers one-way `Sync ▸`. Nothing on the Mac does this, and it is the only feature that makes the second pane *structurally* necessary | M6 |
| **Persistent, pausable operation queue** | Per-item ETA, throughput, reorder, cross-launch persistence. Honest about limits in the UI: resume is per-entry for non-solid / ZIP / tar and block-restart for solid 7z — the 7-Zip API cannot do byte-level resume | M6 |
| **Keychain + Touch ID passwords** | Keyed on a *content fingerprint* (SHA-256 of the first N KB + size) rather than a path, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `SecAccessControl` with `.userPresence`. Offered, never silently auto-filled on a just-downloaded archive | M5 |
| **Live filter inside archives** | `⌘F` with a This-Folder / Entire-Archive scope toggle — subsumes numpad mask selection and delivers Flat View in a discoverable form | M6 |
| **Window tabs alongside panes** | Two panes × N tabs, the layout no Mac archiver offers today | M6 |
| **Convert / recompress and batch operations** | Extract All / Test All / Convert All / Re-encrypt All across a multi-archive selection, feeding the queue. 7-Zip has no such command at all | M6 |
| **Spotlight importer** | Indexes entry names inside archives into `kMDItemTextContent`, capped, encrypted archives skipped. Must be a legacy `.mdimporter` — `CSImportExtension` has never worked on macOS | M6 |
| **Dock tile progress + completion notifications** | `NSDockTile` progress; a notification when the app is not frontmost | M1+ |
| **Apple Silicon thread tuning** | The most measurable, least-exploited win. QoS `.background` confines threads to E-cores permanently (measured: 0.56 s at QoS 33 vs 4.4 s at QoS 9 on a 1 GB compress) — so never `.background`. LZMA2 encode threads default to the **P-core count**, not `activeProcessorCount`; dictionary × threads is budgeted against `physicalMemory`; back off on `thermalState`; long jobs are wrapped in `beginActivity` or App Nap collapses throughput | M1+ |
| **macOS correctness nobody else gets fully right** | `com.apple.quarantine` propagation to extracted files · NFC↔NFD normalisation (APFS hands you decomposed names, Windows ZIPs carry precomposed) · legacy CP932/CP936/CP949 detection · iCloud `.icloud` placeholder materialisation before compressing, so you do not archive a 0-byte stub · resource-fork/xattr round-trip fidelity **plus** a "clean for Windows/Linux recipients" toggle (`.DS_Store`, `__MACOSX/`, `._*`) · `clonefile(2)` for same-volume copies · `:`↔`/` mapping | M1+ |
| **Content-aware compression defaults** | Already-compressed selection → store; many small text files → solid on with a larger dictionary; one huge file → solid off; ZIP for sharing → exclude Mac metadata and warn on Zip64. Plus named presets | M6 |
| **macOS self-extracting `.command`** | In addition to 7-Zip's Windows `7z.sfx` output, which is still useful to produce from a Mac | M3 |
| **Signed, notarized, stapled, auto-updating** | Developer ID signature, hardened runtime, notarization + stapling, Sparkle 2, Homebrew Cask | M1+ |
| **Full VoiceOver and full-keyboard-access support** on the file list | Because a dense virtual table is exactly where every archiver drops accessibility | M1+ |
| **CLI companion** | `arcseven compress` / `extract` / `convert`, sharing the GUI's presets, installable from the menu | M6 |

---

## Requirements

|  |  |
|---|---|
| **macOS** | 14.0 Sonoma or later |
| **Architecture** | Universal 2 — Apple Silicon (`arm64`) and Intel (`x86_64`) |
| **To build** | Xcode 26 (macOS 26 SDK), Swift 6 with strict concurrency, [XcodeGen](https://github.com/yonaskolb/XcodeGen), [SwiftLint](https://github.com/realm/SwiftLint) |

The Xcode/Swift target and module name is **`ArcSeven`** — Swift module names cannot begin with a
digit. The user-facing app is **ArcSeven**. The bundle identifier root is `com.havokentity.ArcSeven`.

---

## Building

```bash
git clone https://github.com/havokentity/ArcSeven.git
cd ArcSeven

# 1. Fetch the upstream 7zz binary + license texts, and install build tooling.
#    Verifies the 7zz SHA-256 against THIRD_PARTY_LICENSES/7-Zip/VERSION.txt.
Scripts/bootstrap.sh

# 2. Generate ArcSeven.xcodeproj from project.yml.
xcodegen generate

# 3. Build.
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven -configuration Debug build
```

Run the tests with:

```bash
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven test
```

`Scripts/bootstrap.sh` never modifies the downloaded `7zz`. Anything it fetches lands in `vendor/`,
which is git-ignored — the binary is a build input, not a tracked artefact.

Release builds are Developer ID signed with `Developer ID Application: Rajesh DMonte (HAMH7N3PJR)`,
hardened-runtime enabled, notarized and stapled. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §7 for the per-release compliance checklist.

---

## License

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
`ArcSeven.app/Contents/Helpers/`, and invokes it as an independent process via command-line arguments.
ArcSeven does not link against, embed, or modify any 7-Zip code. The two are separate programs
distributed together as an aggregate.

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
along with the line that does the real work: `Modifications: NONE`.

Full texts live in [`THIRD_PARTY_LICENSES/`](THIRD_PARTY_LICENSES/) and in
[`NOTICE`](NOTICE); both are copied into `ArcSeven.app/Contents/Resources/Legal/` so that someone who
downloads only the DMG can read every notice without visiting GitHub.

You may replace the bundled binary with your own build of `7zz` at
**Settings ▸ Advanced ▸ 7-Zip binary path**.

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

**Consequently: RAR is extract-only in ArcSeven.** ArcSeven reads RAR archives by invoking the bundled
`7zz`; it cannot create them, and there is no "create RAR" affordance anywhere in the user
interface. This is not a missing feature we intend to add later — the Windows 7-Zip File Manager
cannot create RAR archives either, for the same reason.

**Why this matters architecturally.** A use restriction is not a copyleft condition; it is an
*additional restriction*, which GPLv3 §10 forbids ("You may not impose any further restrictions on
the exercise of the rights granted or affirmed under this License") and GPLv3 §7 classifies as a
"further restriction". Fedora's licensing determination is blunter: the unRAR license "has
use-restrictions that make it GPL-Incompatible and non-free." Linking RAR-capable 7-Zip code
*into* a GPL-3.0 application would therefore be a violation. Running the stock `7zz` as a separate
process is mere aggregation and is fine — pipes, argv and `fork`/`exec` are the FSF's own examples
of communication between two separate programs.

This is why the engine boundary is a hard architectural rule rather than a preference: **RAR-capable
code never enters the GPL boundary.** The planned M5 in-process XPC engine will link a `7z.dylib`
built **without the RAR handlers**; `.rar` will continue to route to the `7zz` subprocess forever.

---

## Trademarks

**ArcSeven is not affiliated with, endorsed by, or sponsored by the 7-Zip project or Igor Pavlov.**

"7-Zip" is referenced here solely and descriptively, to state compatibility and to identify the
software whose behaviour is being reimplemented — never possessively and never as an official
designation. ArcSeven is an independent work by Rajesh D'Monte. It ships no 7-Zip artwork, icon, or
trade dress, and it is not "7-Zip for Mac".

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
relink a modified library, which a sandboxed, store-signed binary cannot allow. So ArcSeven ships as a
Developer ID–signed, notarized, stapled DMG plus a Homebrew Cask — which, as a bonus, keeps the app
out of the App Sandbox, an environment fundamentally at odds with a whole-disk two-pane file
manager. The signature is a convenience for *our* build, not a lock on yours: you can always build,
sign and run your own modified copy.

---

## Related projects

The field is not empty, and this project would be dishonest to pretend otherwise. If one of these
already does what you need, use it.

- **[ShichiZip](https://github.com/idawnlight/ShichiZip)** — LGPL-2.1, Swift + Objective-C++ over
  the upstream 7-Zip C++ tree. **The closest existing thing to this project by a wide margin**, and
  the one you should evaluate first. It already ships dual panes, Finder/Commander shortcut presets,
  `NSFilePromiseProvider` drag-out-of-archive, a Quick Look preview extension, four App
  Intents–backed Finder Quick Actions, a benchmark window, folder history, ten favourite slots, full
  codec control, in-place archive modification, and Dock-icon progress. ArcSeven's honest differentiators
  against it are Shortcuts/Siri automation, a Spotlight importer, window tabs, live in-archive
  filtering, Keychain/Touch ID passwords, a persistent pausable queue, convert/recompress, archive
  diff, and code signing + notarization + auto-update.
- **[Keka](https://www.keka.io/)** — the best-loved Mac archiver, and the reason most people do not
  need this app. It is **not open source**: the source was closed years ago, and `aonez/Keka` is the
  website, translations and issue tracker. It is also, deliberately, *not a file manager* — it cannot
  browse inside an archive at all, which is the single most-requested thing it does not do. Keka is
  the model for macOS-native polish; it is not prior art for the file-manager half.
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
boilerplate. Contributions are inbound = outbound under `GPL-3.0-or-later`, with a DCO sign-off and
no CLA. Bug reports and fidelity discrepancies against Windows 7zFM are especially welcome.
