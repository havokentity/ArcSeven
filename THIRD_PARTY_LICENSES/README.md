<!--
SPDX-License-Identifier: GPL-3.0-or-later
Copyright (C) 2026 Rajesh D'Monte
-->

# Third-Party Licenses

ArcSeven itself is **GPL-3.0-or-later** (see [`LICENSE`](../LICENSE) and
[`NOTICE`](../NOTICE)). The components listed below are *separate works* by
other authors, distributed alongside ArcSeven under their own licenses.

This file is the authoritative inventory. **If a component is not in this
table, it is not distributed with ArcSeven.**

## Index

| Component | Version | License (SPDX) | License text | Role in ArcSeven | Linkage |
|---|---|---|---|---|---|
| **7-Zip** (`7zz` console program)<br>Igor Pavlov | 26.02 (2026-06-25) | `LGPL-2.1-or-later AND BSD-3-Clause AND BSD-2-Clause AND LicenseRef-unRAR-restriction` | [`7-Zip/LICENSE.txt`](7-Zip/LICENSE.txt) — verbatim upstream `license.txt`<br>[`7-Zip/LGPL-2.1.txt`](7-Zip/LGPL-2.1.txt) — full LGPL-2.1<br>[`7-Zip/VERSION.txt`](7-Zip/VERSION.txt) — version, URLs, SHA-256 | The archive engine. Every list, extract, add, update, delete, test, hash and benchmark operation is performed by this binary. | **SEPARATE PROCESS — NOT LINKED.** Bundled unmodified at `ArcSeven.app/Contents/Helpers/7zz` and driven over argv / stdout / exit codes. No 7-Zip code is compiled into, statically linked to, or dynamically loaded by ArcSeven. |
| **Sparkle**<br>Sparkle Project | *not yet vendored* (planned: 2.x) | `MIT` | `Sparkle/LICENSE` — added in the same commit that vendors the framework | Automatic update checks against the signed appcast (planned for the release milestone). | **LINKED.** `Sparkle.framework`, embedded in `ArcSeven.app/Contents/Frameworks/` and linked into the app binary. MIT is GPL-compatible, so the combined work remains distributable under GPL-3.0-or-later. |

**No other third-party code is currently vendored.** ArcSeven has no Swift Package
Manager dependencies, no CocoaPods, no Carthage, and no vendored source from any
other project. Everything else in `Sources/` is first-party code under
GPL-3.0-or-later. The `vendor/` directory holds upstream 7-Zip *build inputs*
only — never code copied into ArcSeven's own modules.

## Why the linkage column is load-bearing

The distinction between *linked* and *bundled as a separate executable* is not
bookkeeping; it decides which license obligations attach to ArcSeven's own source:

- **7-Zip is deliberately never linked.** Its RAR decoder carries the "unRAR
  license restriction", a restriction on *use* — and GPL-3.0 §7/§10 forbid such
  "further restrictions" in a work conveyed under the GPL. Keeping 7zz in its
  own process makes the distribution an *aggregate* (GPL-3.0 §5, LGPL-2.1 §2)
  rather than a combined work, which is what keeps that restriction outside
  ArcSeven's copyleft boundary. See [`NOTICE`](../NOTICE) §2, and
  [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).
  - Practical rules that preserve separateness, all of them binding:
    ship `7zz` byte-identical to upstream; talk to it only over its documented
    command-line surface (never a private IPC or shared-memory channel); let the
    user point ArcSeven at their own `7zz` build; and fail with a clear error, not
    a crash, when the binary is missing.
  - The future in-process XPC engine must be built **without** RAR handlers, and
    `.rar` must continue to route to the CLI engine.
- **Sparkle may be linked** because MIT imposes only attribution, which
  GPL-3.0 §7(b) expressly permits as an additional term.

Any new dependency must be assessed against this rule *before* it is vendored,
and added to the table above in the same commit.

## What ships where

| Artifact | Contains |
|---|---|
| Git repository | This directory, in full. |
| `ArcSeven.app` | `Contents/Resources/Legal/` — a copy of every file in this directory, surfaced from **Help ▸ Acknowledgements** so a user who only has the app can read every notice without visiting GitHub. |
| Release `.dmg` | The `.app` (and therefore `Contents/Resources/Legal/`), plus a top-level copy of `NOTICE`. |
| GitHub Release page | The `.dmg`, plus the upstream 7-Zip **source** archive named in [`7-Zip/VERSION.txt`](7-Zip/VERSION.txt). That co-location is what discharges LGPL-2.1 §4 — see [`NOTICE`](../NOTICE) §1.2. |

## Maintaining this tree

Run [`Scripts/refresh-third-party-licenses.sh`](../Scripts/refresh-third-party-licenses.sh)
whenever the bundled `7zz` is rebuilt or bumped, and in CI before every release.
It re-fetches `https://www.7-zip.org/license.txt`, **fails loudly if the upstream
license text has changed** since it was last vendored, and rewrites the SHA-256
fields in `7-Zip/VERSION.txt` from the actual artifacts.

```sh
Scripts/refresh-third-party-licenses.sh --binary path/to/7zz    # re-vendor
Scripts/refresh-third-party-licenses.sh --check                 # CI: verify only
```

If the script reports that the upstream license text changed, treat it as a
release blocker: re-read the new `license.txt`, then update [`NOTICE`](../NOTICE)
§1.1 and §2, this table, and the in-app Acknowledgements before accepting it with
`--accept-license-change`.

## Verifying what you were shipped

```sh
shasum -a 256 /Applications/ArcSeven.app/Contents/Helpers/7zz   # == Binary SHA-256
shasum -a 256 7z2602-src.tar.xz                              # == Source SHA-256
curl -fsSL https://www.7-zip.org/license.txt | shasum -a 256  # == License SHA-256
```

All three expected values are in [`7-Zip/VERSION.txt`](7-Zip/VERSION.txt).
