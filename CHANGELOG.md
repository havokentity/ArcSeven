<!--
SPDX-FileCopyrightText: 2026 Rajesh D'Monte
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Changelog

All notable changes to ArcSeven are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Milestone tags (M0–M6) refer to the roadmap in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) §2.
No release has been published yet; the first public build will be `v0.1` at the end of M1.

## [Unreleased]

### Added

**Milestone M0 — Foundations.** Scaffolding and de-risking only. There is no user interface, and
nothing here is installable.

- **Repository scaffold** — module directory layout matching the architecture document:
  `Sources/ArchiveCore` (engine, parsers, models; no AppKit), `Sources/FMKit` (file-manager domain;
  no views), `Sources/FMUI` (AppKit), `Sources/Dialogs`, `Sources/SettingsUI`, `Sources/Support`,
  `Sources/App`, plus `Extensions/QuickLookPreview` and `Extensions/QuickActions`, and `Tests/`
  with `ArchiveCoreTests`, `FMKitTests` and `Fixtures`.
- **Licensing and compliance files** — verbatim `GPL-3.0` `LICENSE`; `NOTICE` carrying the 7-Zip
  attribution triple, the unRAR statement and the source offer; `THIRD_PARTY_LICENSES/7-Zip/` with
  the upstream `license.txt`, the full LGPL-2.1 text, and `VERSION.txt` recording the bundled `7zz`
  version, both SHA-256 checksums, the upstream source URL and `Modifications: NONE`.
- **`README.md`** — scope, non-affiliation, the unRAR extract-only restriction, the Mac App Store
  rationale, and an honest survey of prior art (ShichiZip, Keka, The Unarchiver and the wider field).
- **`CONTRIBUTING.md`** — inbound = outbound `GPL-3.0-or-later` with no CLA; DCO sign-off via
  `git commit -s`; the clean-room rule forbidding any 7-Zip, unRAR, p7zip or NanaZip source in this
  repository, with the cite-file-and-line workflow that replaces it; Swift 6 strict-concurrency and
  SwiftLint style rules; and the requirement that every behavioural divergence from Windows 7zFM be
  recorded in `docs/DIVERGENCES.md`.
- **`docs/ARCHITECTURE.md`** — the settled design: milestone roadmap M0–M6, the 72-row fidelity
  matrix against Windows 7zFM, the module breakdown, the improvements-over-Windows list, the risk
  register, and the per-release compliance checklist. Supporting rationale documents for the
  license, stack, backend and fork-or-fresh decisions.
- **`docs/DIVERGENCES.md`** — the register of deliberate departures from Windows 7zFM, classified as
  *adapted*, *dropped*, *fixed* or *improved*, each with its upstream file/line citation.
- **SPDX headers** on every first-party file (`GPL-3.0-or-later`), with `reuse lint` wired into CI.
- **`ArchiveCore`: the engine boundary.** The `ArchiveEngine` protocol, written with a single
  implementation from the first commit so that the M5 in-process XPC engine can be swapped in
  without touching the UI. `SevenZipCLIEngine` spawns the bundled `7zz`, passes paths via an
  `@listfile` with `-scsUTF-8`, and cancels by killing the process group rather than abandoning the
  read loop.
- **`ArchiveCore`: output parsing.** A byte-oriented stream reader that splits on `\b`, `\n` and
  `\r` — 7-Zip's progress output is backspace-delimited, verified empirically against 7zz rather
  than assumed — a `l -slt` state-machine parser keyed on the ten-hyphen separator, and an exit-code
  mapper that treats status `1` as *success with warnings*, not failure.
- **Golden-file test corpus** in `Tests/Fixtures`, with its generator script: 7z solid and
  non-solid, zip, tar.gz, rar, encrypted body, encrypted headers, multi-volume, a 200k-entry
  archive, UTF-8 filenames (`café_日本.txt`), NFD-vs-NFC pairs, a legacy CP932 zip, a deliberately
  corrupted archive, and a filename containing a newline. Every parser change re-runs the whole
  corpus.
- **Phase 0 spike** — a signed, hardened, notarized throwaway bundle that spawns `7zz` and extracts
  a user-selected archive from an external volume to a user-selected destination, confirming that
  `lipo -info 7zz` reports `x86_64 arm64`, that spawning a co-signed bundled helper needs no
  `com.apple.security.cs.*` entitlement, and that the progress encoding is unchanged in 26.02.
- **`Scripts/bootstrap.sh`** — fetches the pinned upstream `7zz` universal binary and the upstream
  license texts into the git-ignored `vendor/`, verifies the SHA-256 against
  `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt`, and installs the build tooling (XcodeGen, SwiftLint).
  It never modifies the downloaded binary.
- **XcodeGen `project.yml`** generating `ArcSeven.xcodeproj` — target and Swift module name
  `ArcSeven`, bundle identifier root `com.havokentity.ArcSeven`, deployment target macOS 14.0,
  Universal 2 (`arm64` + `x86_64`), built against the macOS 26 SDK with Xcode 26, Swift 6 language
  mode with complete strict concurrency and warnings-as-errors.
- **CI pipeline**, wired up now rather than on release day: build → test → SwiftLint → `reuse lint`
  → sign (inner Mach-O binaries first, hardened runtime everywhere) → DMG → notarize → staple →
  verify (`codesign --verify --deep --strict`, `spctl -a -vvv -t exec` must report
  `source=Notarized Developer ID`, `stapler validate`) → release. Signing identity:
  `Developer ID Application: Rajesh DMonte (HAMH7N3PJR)`. GitHub issue templates for bug reports and
  for **fidelity discrepancies against Windows 7zFM**.

### Notes

- ArcSeven drives the **stock, unmodified upstream `7zz`** as a subprocess and links no 7-Zip code.
  This is what keeps the project's `GPL-3.0-or-later` licensing valid while RAR support is present:
  the unRAR use restriction is a *further restriction* forbidden by GPLv3 §10, so RAR-capable code
  must never enter the GPL boundary. The planned M5 in-process XPC engine will be built **without
  the RAR handlers**, and `.rar` will continue to route to the `7zz` subprocess.
- **RAR is extract-only**, permanently, and there is no "create RAR" affordance anywhere. The
  Windows 7-Zip File Manager cannot create RAR archives either.
- ArcSeven is **not affiliated with, endorsed by, or sponsored by** the 7-Zip project or Igor Pavlov.

[Unreleased]: https://github.com/havokentity/ArcSeven/commits/main
