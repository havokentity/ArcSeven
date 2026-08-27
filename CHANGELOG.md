<!--
SPDX-FileCopyrightText: 2026 Rajesh D'Monte
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Changelog

All notable changes to ArcSeven are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each version's section is what the in-app updater shows: `Scripts/appcast.sh` lifts it
straight out of this file and embeds it in the appcast, so anything written here is read by
users in the update dialog.

The milestone numbering has drifted from [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §2 —
vendoring and engine verification took a milestone of their own, so the shipped M2 is what §2
calls M1.

## [Unreleased]

Nothing yet.

## [0.1.6] - 2026-08-27

The largest correctness release so far. Three of these lose data, and one made every
non-default compression setting fail outright.

### Fixed

- **Deleting one member could delete several.** `*` and `?` are legal in a macOS filename
  and 7-Zip matched member names as wildcards, so deleting `note*.txt` also removed
  `noteA.txt` and `noteB.txt` — exit 0, no warning. Extraction had the mirror flaw.
- **"Ask before overwrite" overwrote everything.** `Yes` meant *this file* but applied to
  the whole run, so a sheet naming one file could replace fifty.
- **Extraction had no size ceiling.** It now asks before an archive that declares an
  alarming expansion — 64 GiB, 300× the archive, or more than the free space.
- **Every explicit dictionary size failed**, writing no archive. PPMd word size, the tar
  dialect, `Keep broken files` and `Eliminate duplication of root folder` were broken too.
- **The Settings window was write-only** — until you first opened it, three keys read as the
  *opposite* of their default. Six File List toggles, "Remember in Keychain", the live
  Properties inspector, double-clicking a `.app`, two dead Services items and six Quick Look
  formats that could only refuse: all now work, or are gone.
- **Compliance:** Sparkle's MIT licence was never shipped, the LGPL provenance record
  carried placeholders where its checksums belong, and a release missing the Sparkle signing
  key silently broke auto-update for every existing install.

### Added

- Colour-coded toolbar buttons, **Help ▸ Acknowledgements & Licences**, and `Extract Loose`
  beside `Extract Here` and `Extract to Subfolder`.

**Note:** nested archives browse but are one-way — `..` from inside one lands in the temp
directory. 392 tests, up from 274. Full detail in the commit history.

## [0.1.5] - 2026-08-26

### Added

- **"Extract Loose"**, which never creates a wrapper folder, alongside the existing
  "Extract Here" (wraps only when the archive would otherwise scatter) and "Extract to
  Subfolder" (always wraps). All three now appear in the Finder right-click submenu, which
  previously offered only "Extract Here" — the other two existed in the Services menu
  alone, which is not where anyone looks.

  Named "Extract Loose" rather than "Extract Without Folder" on purpose: 7-Zip already uses
  "without folder structure" for `-e`, which flattens paths *inside* the archive so
  `src/a.txt` and `docs/a.txt` collide as `a.txt`. All three of these preserve the
  archive's internal structure and differ only in the wrapper.

### Fixed

- **The update dialog showed the whole GitHub release page** — nav bar, Sign in button and
  all — inside its release-notes pane. The appcast set `sparkle:releaseNotesLink` to the
  release page URL, and Sparkle fetches that into a web view; it also takes precedence over
  any embedded notes. The notes are now embedded in the appcast as markdown, taken straight
  from this file, so the dialog shows what changed and nothing else, without a network
  fetch.

## [0.1.4] - 2026-08-26

### Changed

- **"Extract Here" now extracts here.** It never did: it and "Extract to Subfolder" were
  two Services menu items calling the same code, and both wrapped the contents in a folder
  named after the archive. The destination is now chosen by looking at the archive — a
  single top-level item extracts loose, since the archive already provides its own folder
  and wrapping it produces `project-1.0/project-1.0/`; two or more top-level items are
  wrapped, since extracting them loose scatters them across the enclosing folder with no
  way to tell afterwards what just arrived. An archive whose listing fails is wrapped.
  See [`docs/DIVERGENCES.md`](docs/DIVERGENCES.md) D-0.1.4-1.
- "Extract to Subfolder" is now a distinct command that always wraps.

### Fixed

- **The Compress sheet would have crashed on open.** Adding the passphrase-exposure notice
  in 0.1.3 indexed a fourth element of a three-element array. Caught before release by the
  new `DialogsTests`; recorded here because the fix is what the test target is for.
- **Sparkle's MIT licence was never shipped.** `Sparkle.framework` has been linked and
  embedded since 0.1.0 while the compliance tree listed it as "not yet vendored", so no
  copy of its licence reached the app, the disk image or the repository. MIT requires the
  notice to accompany all copies.
- Three claims in `NOTICE` that were not true: that it was reproduced under
  **Help ▸ Acknowledgements** (there was no Help menu — there is now, and it reveals the
  bundled legal folder), the source-tarball filename pattern, and a grammatical slip.

### Added

- **Colour-coded toolbar buttons.** Each action draws as a rounded badge in its own colour
  with a white glyph. Delete is the only red in the toolbar, so the destructive button is
  never found by muscle memory alone. All system colours, so dark mode, Increase Contrast
  and a changed accent colour stay correct.
- **Help ▸ Acknowledgements & Licences**, which reveals `Contents/Resources/Legal/`.
- `FMUITests`, and preflight guards for two things that had silently broken before: the
  updater being wired to nothing, and the two `FinderRequest.swift` copies drifting apart
  on the wire format the Finder extension and the app share.

## [0.1.3] - 2026-08-26

### Fixed

- **The auto-updater was never switched on.** `Sparkle.framework` has been embedded,
  signed and notarised in every release since 0.1.0, and 0.1.2 added a valid signing key
  and a published, correctly signed appcast. None of it ran: nothing ever constructed
  `UpdaterController`, so `SPUStandardUpdaterController` was never created, and no
  "Check for Updates…" menu item existed to reach it. `start()`'s own documentation said
  "Call this from `applicationDidFinishLaunching`", and nothing did. Every piece was
  correct in isolation, which is why it survived being configured twice.

- **A member name could lie about its extension.** Names are attacker-controlled, and
  nothing escaped them: `invoice<U+202E>gnp.exe` rendered as `invoice exe.png`, because
  everything after a right-to-left override is drawn reversed. The name really did end in
  `.exe`. Control characters and bidi overrides are now escaped to visible `\u{XXXX}` in
  the file panel and the Properties inspector. Ordinary right-to-left letters are left
  alone — an Arabic or Hebrew filename still renders as itself.

### Added

- The Compress sheet now says that a password is briefly visible to other users signed in
  to this Mac while the archive is being created. This is unavoidable with a subprocess
  engine: `7zz a` has no stdin prompt, so the passphrase must go on the command line.
  Reading an encrypted archive is unaffected.
- `DialogsTests`, which the repo had no equivalent of. Dialogs are built imperatively from
  arrays of views, where a wrong index compiles cleanly and traps when the sheet opens.
- `ExtractionContainmentTests`, which builds hostile archives at the byte level and
  asserts nothing is written outside the destination.

### Changed

- `docs/SECURITY.md` now describes the protections that exist. Four of its nine sections
  claimed ArcSeven-side mitigations that were never implemented — most importantly §3,
  which described decompression-bomb ceilings that do not exist and are not scheduled.
  Path-traversal and symlink containment are real but are 7-Zip's, not ArcSeven's.

## [0.1.2] - 2026-08-26

**The auto-updater works for the first time.** Every earlier build shipped without a feed
URL, so this update has to be installed by hand; from here on the app can update itself.

### Fixed

- **Auto-update was never configured.** `SUFeedURL`, `SUEnableAutomaticChecks` and
  `SUScheduledCheckInterval` sat in the Quick Look extension's `Info.plist`. Sparkle reads
  its configuration from the host app, so nothing there was ever consulted and the app had
  no feed to check. The keys were present and correctly spelled the whole time, just
  attached to the wrong target. Preflight now asserts this against the built bundle.
- **Encrypted multi-volume archives always reported failure.** With `-v`, 7zz writes
  `archive.7z.001`, `.002`, … and never `archive.7z`, but the encryption check re-listed
  the base name and got `errno=2 : No such file or directory`. The archive had been
  written correctly, and encrypted correctly, and the user was told it failed.
- **Large selections could not be extracted or tested.** Member paths went on `argv`,
  where `ARG_MAX` fails the spawn with an opaque `E2BIG`. They now move to a list file
  past a threshold, and stay on `argv` below it.
- The progress sheet is now dismissed from a `defer`. It is modal, and the only way out
  of a stuck one is force-quitting.

### Added

- `SUPublicEDKey`, so updates are verified. Sparkle refuses anything it cannot verify, so
  until now the updater had no key and would have failed closed.

### Changed

- Running and reporting moved to `MainWindowController+Running.swift`; the original file
  crossed the 500-line limit.

## [0.1.1] - 2026-08-25

**Security and data-loss fixes. 0.1.0 has been withdrawn — do not use it.**

### Fixed

- **Extraction destroyed existing files without asking.** "Ask before overwrite" — the
  default — silently overwrote. `-y` is required to keep the child process from blocking
  on a prompt it has no terminal for, but `-y` answers *yes* to overwrite questions, and
  the `.ask` case emitted no `-ao*` switch to override it. It now maps to `-aos` (skip),
  so the engine fails safe even if the UI's pre-scan misses a conflict.
- **The overwrite pre-scan missed most conflicts.** It ignored selected *directories*
  entirely, so extracting a selected folder never prompted; and it always probed the
  member's full path, so "no pathnames" extraction — which flattens everything onto the
  destination root — checked addresses the files would never be written to. Both are
  fixed, and directory selections now expand to their member files.
- **Quarantine was never propagated.** `docs/SECURITY.md` §6 stated that
  `com.apple.quarantine` is carried from the archive onto every extracted file. The code
  to do it existed and was correct, but nothing ever called it, so extracting a
  downloaded archive produced unquarantined files — a Gatekeeper bypass for anything
  shipped inside an archive. It is now wired into extraction and covered by tests.

### Changed

- `ExtractRequest.selectedEntries` documented itself as being passed through an
  `@listfile`. It is passed as argv. The comment now says so, and notes the `ARG_MAX`
  ceiling that follows from it; the listfile is tracked for 0.1.2.

## [0.1.0] - 2026-08-25

First release: a notarised, stapled, universal (arm64 + x86_64) DMG, with the 7-Zip 26.02
corresponding-source tarball attached to the same release per LGPL-2.1 §4. Everything below —
previously grouped under `Unreleased` by milestone — ships in this version.

Pre-alpha. The app builds, launches, opens an archive from Finder, browses it and extracts from it.
The Add / Test / Copy / Move / Delete dialogs are written but not yet reachable from the toolbar.
197 tests across 15 suites pass.

---

### M2 — The AppKit shell

The first build that does something for a person. Verified by running it and reading the screen.

**Added**

- **`PanelViewController`** — 7zFM's `CPanel`: path bar, view-based `NSTableView`, status bar.
  Driven by an explicit data source rather than bindings, so cells exist for visible rows only and
  a reload is O(visible), not O(entries). That is the only approach that stays responsive at the
  row counts archives reach.
- **`MainWindowController`** — `NSSplitViewController` shell, 7zFM's seven toolbar buttons in its
  order (Add / Extract / Test / Copy / Move / Delete / Info), window title tracking the focused
  panel, a second panel that can be toggled on. Extract and Info are implemented; the remaining
  buttons present an explicit "not implemented yet" sheet naming the milestone, because a button
  that silently does nothing reads as a bug.
- **`ProgressSheetController`, `MainMenuBuilder`, `EngineLocator`**, and an explicit `main.swift`.
- **`SortEngine`** implementing 7zFM's real ordering: `..` pinned first, folders above files in
  **both** directions (reversing reverses within each group — the rule reimplementations usually
  get wrong), natural numeric name comparison, deterministic tiebreak.
- **`FileSystemFolderProvider` and `ArchiveFolderProvider`.** The archive is listed **once** and
  navigation is pure computation over that snapshot, because `7zz l -slt` returns the whole archive
  and there is no list-one-directory operation. Directories with no entry of their own are
  synthesised, or archives written by `zip -D` open empty.
- **`ColumnModel`**, per-folder-type column sets, and the persistence stores `FavoritesStore`,
  `FolderHistoryStore` and `PanelPreferences` (implemented and tested; no UI reads them yet).
- **`Support`** — `PathSafety` (zip-slip guard), `PathNormalizer`, `Quarantine`, `TrashService`,
  `ThreadPlanner`, `ByteFormatting`.
- **Dialogs**, written and compiling but not yet wired: Add-to-Archive (controller and model),
  Extract, Overwrite, Password, Properties inspector.
- **`SettingsUI`** — six panes plus the settings window chrome.
- **Live navigation test suite** that builds a real nested `.7z` with the vendored `7zz` and walks
  the provider tree the way the panel does, confirming natural ordering (`file1`, `file2`, `file3`,
  `file10`, `file20`) end to end.

**Changed**

- `Package.swift` grew from the two AppKit-free modules to six library targets plus `SupportTests`,
  so `swift build` covers everything the Xcode project compiles.
- Size columns show exact grouped byte counts rather than `ByteCountFormatter`'s "1.2 MB". In an
  archive manager the point of Size and Packed Size is comparing them against each other, and
  rounding destroys that. Implemented with `FormatStyle`, since `NumberFormatter` is not `Sendable`
  and cannot be a shared static under Swift 6. (`docs/DIVERGENCES.md` D-M2-1.)
- The panel opens with the first real row selected and focused. 7zFM opens with no selection; on
  macOS a list that ignores the arrow keys until you click it reads as broken. (D-M2-3.)

**Fixed** — every one of these was found by running the app, not by a test

- **The window opened at 278×85.** Assigning `contentViewController` **resizes the window to the
  view's fitting size**, discarding the `contentRect` passed to `NSWindow.init`. With autolayout
  content that has no intrinsic height, that collapses the window. The content size is now set
  *after* the assignment, and both panes carry a minimum thickness so a pane cannot be dragged to
  zero width and become unrecoverable.
- **Finder-launched URLs were dropped.** `application(_:open:)` fires **before**
  `applicationDidFinishLaunching`, so double-clicking a `.7z` — the most important way anyone will
  ever open this app — silently did nothing. URLs are now queued and replayed once the window
  exists.
- **`7zz` was copied to the wrong bundle subpath.** It landed at `ArcSeven.app/Helpers/7zz` instead
  of `Contents/Helpers/7zz`, because XcodeGen's `destination: wrapper` is the bundle *root*. That
  would have failed `codesign --verify --deep --strict` at release. `EngineLocator` compounded it
  by relying on `Bundle.url(forAuxiliaryExecutable:)`, which only searches `Contents/MacOS` and
  returned `nil`; the path is now spelled out.
- **The path bar was hidden behind the toolbar.** `.fullSizeContentView` extends the content view
  under the title bar; the panel's top edge is now anchored to the safe area.
- Folders rendered `0` in the Packed Size column, which also clumped every folder at one end of a
  size sort. Directories now report no size at all. (D-M2-2.)
- The file list took no keyboard focus on open, so the arrow keys did nothing until you clicked a
  row.

**Build system**

- **The `module-guard` idiom.** `Package.swift` builds six modules; the Xcode target compiles the
  same files into one, because Xcode cannot consume a local Swift package rooted at the project's
  own directory — `packageProductDependencies` come out empty. Intra-project imports are therefore
  wrapped in `#if canImport(…)`, true under SwiftPM and false under Xcode. One source tree, both
  build systems, and `swift test` exercises exactly the sources the app ships. **Any new file
  importing a sibling module must use this form** or the app target fails to build. See
  `docs/DIVERGENCES.md`, "Build-system note".

**Tests** — 197 across 15 suites, up from 40.

---

### M1 — Vendored `7zz`, and the engine verified against it

Adds the pinned upstream submodule, builds it, and drives the actual binary from the test suite.
Four defects surfaced that byte-fixture tests could not have caught.

**Added**

- **`vendor/7zip`** as a git submodule pinned to ip7z/7zip **26.02**
  (`f9d78aff31a5f2521ae7ddbdc97c4a8855808959`), verified pristine.
- **`vendor/build-7zz.sh`** produces a universal `arm64` + `x86_64` `7zz` from unmodified upstream
  source using upstream's own makefiles: `lipo`'d, checksummed, provenance-stamped, both slices
  verified to execute. It refuses to build a modified tree. The output is git-ignored — it is
  reproducible, not a committed artefact.
- **`Tests/ArchiveCoreTests/LiveEngineTests.swift`**, which encodes every correction below against
  the real binary and **skips itself when `vendor/bin/7zz` is absent**, so a bare checkout still
  passes `swift test`. Re-run it on every upstream version bump — that is the whole reason it
  exists.
- **`docs/ENGINE-PROTOCOL.md` Appendix A**, which records the corrections and **overrides the body
  of that document** wherever the two disagree. The body was researched against 7-Zip 18.05; the
  appendix was verified against the vendored 26.02.

**Fixed** — corrections to the CLI contract, verified against 26.02 rather than 18.05

- **A bare `-p` means an EMPTY password**, and suppresses the prompt. It does not read stdin, which
  is what the research described. Passing it with a passphrase on stdin fails with exit 2 and
  "Cannot open encrypted archive. Wrong password?".
- **Omitting *both* `-y` and `-p` makes `7zz` prompt and read the passphrase from stdin**, with no
  TTY required — confirmed with the child in its own session via `setsid`. Read operations (`l`,
  `t`, `x`, `e`, `d`, `rn`, `h`) now use that path, so extraction passphrases never reach argv and
  are never visible in `ps`. Because `-y` is absent there, every such invocation must pass an
  explicit `-ao*` overwrite mode so no other prompt can block the child.
- **Creating an archive with a piped password silently produces an UNENCRYPTED archive and exits
  0.** There is no prompt on the creation path at all. Creation must use `-p<pw>` on argv, and
  `verifyEncryption(of:password:)` earned its place immediately by catching exactly this.
- **`-mem=` is ZIP-only.** Passing it to the `.7z` handler is
  `System ERROR: E_INVALIDARG : One or more arguments are invalid`. `.7z` supports AES-256 and
  nothing else, so the cipher is implicit. Header encryption (`-mhe=on`) remains `.7z`-only.
- **The version banner is preceded by a blank line**, so any check using `head -n 1` gets `""`.
  `vendor/build-7zz.sh` had this bug and now matches the first line containing `7-Zip`.

**Fixed** — two host-side concurrency defects, both of which would have shipped

- **Blocking pipe reads ran on the Swift cooperative thread pool.** `Task.detached` still uses that
  pool and `FileHandle.availableData` blocks, so a few concurrent operations exhausted it and
  deadlocked the process. `ProcessRunner` now reads on dispatch queues, which grow a thread per
  blocked work item.
- **`Process.waitUntilExit()` deadlocks when called from a queue** with several processes in
  flight; a sampled backtrace pinned it. Replaced with `terminationHandler` plus a completion gate,
  because the exit notification and pipe EOF race in either order.

**Tests** — 40 across 6 suites, stable over five consecutive runs.

---

### M0 — Foundations

Scaffolding, compliance and the engine layer. No user interface.

**Added**

- **Repository scaffold** matching the architecture document: `Sources/ArchiveCore` (engine,
  parsers, models; no AppKit), `Sources/FMKit` (file-manager domain; no views), `Sources/FMUI`,
  `Sources/Dialogs`, `Sources/SettingsUI`, `Sources/Support`, `Sources/App`, plus
  `Extensions/QuickLookPreview` and `Extensions/QuickActions`, and `Tests/`.
- **Licensing and compliance files** — verbatim `GPL-3.0` `LICENSE`; `NOTICE` carrying the 7-Zip
  attribution triple, the unRAR statement and the source offer; `THIRD_PARTY_LICENSES/7-Zip/` with
  upstream's `license.txt`, the full LGPL-2.1 text, and `VERSION.txt` recording the bundled `7zz`
  version, both SHA-256 checksums, the upstream source URL and `Modifications: NONE`.
  SPDX headers on every first-party file.
- **`README.md`, `CONTRIBUTING.md`** (inbound = outbound, DCO sign-off, the clean-room rule and the
  cite-file-and-line workflow that replaces copying), **`docs/ARCHITECTURE.md`** (milestone
  roadmap, the 72-row fidelity matrix, module breakdown, risk register, per-release compliance
  checklist), **`docs/DIVERGENCES.md`**, **`docs/ENGINE-PROTOCOL.md`**, **`docs/FIDELITY.md`**,
  **`docs/SHORTCUTS.md`**, **`docs/RELEASING.md`**, **`docs/SECURITY.md`**.
- **`ArchiveCore`: the engine boundary.** The `ArchiveEngine` protocol, written with a single
  implementation from the first commit so the future in-process engine can be swapped in without
  touching the UI. `SevenZipCLIEngine` spawns the bundled `7zz`, passes paths via an `@listfile`
  with `-scsUTF-8`, and cancels by killing the process group rather than abandoning the read loop.
- **`ArchiveCore`: output parsing.** `StreamTokenizer` — `7zz` paints progress with **backspaces**,
  not carriage returns, verified empirically rather than assumed. `SLTParser` — a ten-hyphen state
  machine that splits on the *first* `" = "` so paths containing `" = "` survive. `ProgressParser`
  for transient progress rows and `-bb3` member lines. `ExitCodeMapper` — exit 1 is
  success-with-warnings; 255 is overloaded and disambiguates a real cancellation from a prompt that
  found stdin closed.
- **`Scripts/bootstrap.sh`** — toolchain checks, submodule pin, `7zz` build, XcodeGen install
  (asking first), project generation. **`project.yml`** generating `ArcSeven.xcodeproj`: module name
  `ArcSeven`, bundle identifier root `com.havokentity.ArcSeven`, deployment target macOS 14.0,
  Universal 2, macOS 26 SDK, Swift 6 language mode with complete strict concurrency and
  warnings-as-errors.
- **CI**, wired up now rather than on release day. `ci.yml` runs three jobs on every push and pull
  request: `swift build` + `swift test` (no Xcode project, no signing, so fork PRs that never see
  repository secrets still run it), `swiftlint lint --strict`, and an XcodeGen job that regenerates
  the project, validates the generated property lists and lists the targets.
- **Release pipeline** in `release.yml`, never yet exercised: bootstrap → universal Release build →
  sign (inner Mach-O binaries first, hardened runtime everywhere) → notarise → staple → DMG →
  notarise and staple the DMG → verify (`codesign --verify --deep --strict`; `spctl -a -vvv -t exec`
  must report `source=Notarized Developer ID`; `stapler validate`; architecture check) → build the
  7-Zip corresponding-source tarball → checksums → sign the update and generate the Sparkle appcast
  → publish. GitHub issue templates for bug reports and for **fidelity discrepancies against
  Windows 7zFM**.

**Fixed** — both found by the tests, before any of it ran against a real archive

- `SLTParser` treated CRLF input as a single line. In Swift `"\r\n"` is one `Character`, so
  `split(separator: "\n")` never splits it. Now splits on `isNewline`.
- Encrypted-archive creation could silently produce plaintext, since `7zz` exits 0 when `-p` is
  dropped. Creation now verifies the result is actually encrypted — a guard that proved itself in
  M1.

**Tests** — 33 across 5 suites; `swift build` clean with zero warnings.

---

### Notes

- ArcSeven drives the **stock, unmodified upstream `7zz`** as a subprocess and links no 7-Zip code.
  This is what keeps the project's `GPL-3.0-or-later` licensing valid while RAR support is present:
  the unRAR use restriction is a *further restriction*, which GPLv3 §7 classifies as such and §10
  forbids imposing, so RAR-capable code must never enter the GPL boundary. The planned in-process
  engine will be built **without the RAR handlers**, and `.rar` will continue to route to the `7zz`
  subprocess.
- **RAR is extract-only**, permanently, and there is no "create RAR" affordance anywhere. The
  Windows 7-Zip File Manager cannot create RAR archives either.
- ArcSeven is **not affiliated with, endorsed by, or sponsored by** the 7-Zip project or Igor
  Pavlov.

[Unreleased]: https://github.com/havokentity/ArcSeven/commits/master
