<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# `vendor/` — the 7-Zip vendoring policy

Everything in this directory exists to answer one question with evidence rather
than assertion:

> **Is the `7zz` inside ArcSeven.app byte-for-byte a build of unmodified upstream
> 7-Zip, from a specific published commit?**

The answer has to be *yes*, provably, on every build, because ArcSeven's entire
licence posture rests on it. The scripts here are written to make "no" a build
failure rather than a discovery made later by someone else.

---

## Contents

| Path | What it is |
|---|---|
| `vendor/7zip/` | Git submodule → [`github.com/ip7z/7zip`](https://github.com/ip7z/7zip). **Unmodified**, pinned to a commit. Never edit anything in here. |
| `vendor/build-7zz.sh` | Builds the arm64 and x86\_64 slices, `lipo -create`s them, verifies, records SHA-256, stages the result. Refuses to run against a modified tree. |
| `vendor/bin/` | Build output: the staged universal `7zz`, its `7zz.sha256`, and `BUILD-INFO.txt`. Generated, self-ignoring, never committed. |
| `vendor/README.md` | This file. |

The submodule is *not* configured in a fresh clone until you run
`Scripts/bootstrap.sh`, which adds it, pins it, and builds it.

---

## The pin

| | |
|---|---|
| Upstream | `https://github.com/ip7z/7zip.git` |
| Tag | **`26.02`** (released 2026-06-25) |
| Commit | `f9d78aff31a5f2521ae7ddbdc97c4a8855808959` |
| Upstream licence | LGPL-2.1-or-later, **plus** the unRAR restriction on `CPP/7zip/Compress/Rar*` (see `DOC/License.txt` in the submodule) |
| Modifications | **NONE**, and this is enforced |

Upstream release assets encode version `NN.MM` as the four digits `NNMM`, so
tag `26.02` publishes `7z2602-mac.tar.xz`, `7z2602-src.tar.xz` and
`7z2602-src.7z` under
`https://github.com/ip7z/7zip/releases/download/26.02/`
(mirrored at `https://www.7-zip.org/a/`). Those names matter when you are
cross-checking a bump against the official downloads page; they are not what we
build from.

**The commit SHA is the authority, not the tag name.** Upstream's tags are
lightweight and can in principle be moved. Both scripts check the SHA first and
treat a tag that no longer resolves to it as a hard error, not a warning.

### Why we build instead of downloading `7z2602-mac.tar.xz`

The official macOS tarball is a perfectly good binary. We build anyway, for four
reasons that are all about what we can *prove* and *control*:

1. **Provenance.** A build from a pinned commit in our own tree is auditable by
   anyone with the repo. A downloaded binary is auditable only against a hash we
   would have to publish and defend ourselves.
2. **Signing.** ArcSeven ships Developer ID signed and notarized. A helper
   executable inside the bundle must carry our signature with the hardened
   runtime; re-signing someone else's binary is possible but building our own is
   cleaner and keeps the notarization story trivial.
3. **Deployment target.** `MACOSX_DEPLOYMENT_TARGET=14.0` is exported around the
   `make`, so the helper's `LC_BUILD_VERSION` matches the app's minimum. A
   downloaded binary's minimum is whatever upstream's builder happened to use.
4. **The RAR-free variant.** The future in-process engine (see below) needs a
   build from the same tree with `DISABLE_RAR=1`. Having the source vendored
   means that build is one flag away instead of a separate supply chain.

**Do not substitute Homebrew's `7zz`.** The `sevenzip` formula passes
`DISABLE_RAR_COMPRESS=1`, which silently reduces RAR support to "list entries
and extract stored files". Real-world RAR archives would appear to open and then
fail to extract. `build-7zz.sh --check` fails loudly if the `Rar5` handler is
missing, precisely to catch someone dropping a Homebrew binary into
`vendor/bin/`.

---

## The rule that makes this legal

ArcSeven is **GPL-3.0-or-later**. Upstream 7-Zip is **LGPL-2.1-or-later**, except
that the RAR decoder files carry an *additional* clause inherited from unRAR:
the code may not be used to re-create the RAR compression algorithm, and any
redistribution must state that it may not be used to build a RAR-compatible
archiver.

That extra clause is a **"further restriction"** in the sense of **GPLv3 §7**.
GPLv3 does not let a licensee impose one on downstream recipients. So a work
that *combines* GPL-3.0 code with the RAR-encumbered 7-Zip code into a single
program has a real, unresolved conflict. Debian and Fedora reach the same
conclusion from the other direction and strip the RAR decoder as non-free.

ArcSeven sidesteps this rather than arguing about it:

```
ArcSeven.app/
└── Contents/
    ├── MacOS/ArcSeven        GPL-3.0-or-later, first-party, our code
    └── Helpers/7zz            LGPL-2.1 + unRAR, upstream, UNMODIFIED
                               ── executed with Process(), talking over
                                  argv / stdout / stderr / exit codes
```

* `7zz` is a **separate executable**, spawned as a **subprocess**.
* It is **never linked** into the app — not statically, not dynamically, not via
  `dlopen`. There is no `7z.so`, no `7z.dylib`, no `libarchive` shim, nothing.
* The only interface is the process boundary: arguments in, bytes out, an exit
  code. That is arm's-length aggregation, not a combined work.
* Upstream's terms are satisfied by shipping the binary unmodified with its
  licence text (`THIRD_PARTY_LICENSES/7-Zip/`) and the unRAR paragraph
  reproduced verbatim in `NOTICE`.

**Three things must all stay true, or the argument collapses:**

1. `7zz` is unmodified. → enforced by `build-7zz.sh` (see below).
2. `7zz` runs as its own process. → `Sources/ArchiveCore/CLIEngine/` only ever
   uses `Process`; see `docs/ENGINE-PROTOCOL.md`.
3. The licence texts ship with the binary. → `project.yml` copies `LICENSE`,
   `NOTICE` and `THIRD_PARTY_LICENSES/` into `Contents/Resources/Legal/`.

This is also why ArcSeven is not on the Mac App Store: Apple's Licensed Application
End User Licence Agreement adds restrictions that GPLv3 §7 does not permit
either. Distribution is Developer ID + notarized DMG, plus a Homebrew Cask.

---

## How the "unmodified" guarantee is enforced

`vendor/build-7zz.sh` refuses to build unless *all* of these hold:

| Check | Failure mode |
|---|---|
| `vendor/7zip` is a real git work tree | A dropped-in tarball cannot be verified, so it is rejected outright |
| `HEAD` == the pinned commit SHA | Hard error, prints both SHAs and the fix |
| If `refs/tags/26.02` exists, it resolves to that same SHA | Hard error — catches a moved upstream tag |
| `git diff --quiet HEAD --` is clean | Hard error, lists every modified file and explains the licence consequence |
| No untracked files except build output under `CPP/7zip/Bundles/*/{b,_o}/` | Hard error — a stray `.cpp` is exactly what a smuggled patch looks like |

There is an `--allow-dirty` escape hatch for local experimentation. It prints a
warning, stamps `Modifications: YES — NOT DISTRIBUTABLE` into
`vendor/bin/BUILD-INFO.txt`, and `--check` then **refuses** that binary unless
`--allow-dirty` is passed there too. A dirty build cannot quietly become a
release build.

If you genuinely need to change upstream behaviour, the answer is not a patch
here. Send it to `ip7z/7zip`, or work around it in `ArchiveCore`.

---

## Building

```sh
./vendor/build-7zz.sh              # verify, build both slices, lipo, stage
./vendor/build-7zz.sh --clean      # discard object dirs first
./vendor/build-7zz.sh --check      # verify what is already staged; builds nothing
./vendor/build-7zz.sh --help
```

The recipe, which is upstream's own and needs no patches:

```sh
cd vendor/7zip/CPP/7zip/Bundles/Alone2
make -j -f ../../cmpl_mac_arm64.mak     # -> b/m_arm64/7zz
make -j -f ../../cmpl_mac_x64.mak       # -> b/m_x64/7zz
lipo -create b/m_arm64/7zz b/m_x64/7zz -output 7zz
```

`cmpl_mac_arm64.mak` is a three-line include of `var_mac_arm64.mak`
(`PLATFORM=arm64`, `O=b/m_$(PLATFORM)`, `MY_ARCH=-arch arm64`, `USE_ASM=1`),
`warn_clang_mac.mak`, and the bundle's `makefile.gcc`. The x64 variant is the
same with `MY_ARCH=-arch x86_64` and `USE_ASM=` empty, so the cross-build needs
no assembler beyond clang. `MACOSX_DEPLOYMENT_TARGET` is read by clang itself,
which is how the deployment target is pinned without editing a single upstream
file.

**No RAR-disabling flags are passed.** The shipped helper keeps full RAR
extraction, which is the whole point of running it out-of-process.

### What lands in `vendor/bin/`

| File | Purpose |
|---|---|
| `7zz` | Universal (`arm64` + `x86_64`), mode 755, ad-hoc signed. `project.yml` copies it to `Contents/Helpers/`. |
| `7zz.sha256` | `shasum -a 256 -c` compatible. Re-checked by `--check`. |
| `BUILD-INFO.txt` | Tag, commit, `Modifications:`, toolchain, per-slice and universal SHA-256, `lipo -info` output. |
| `.gitignore` | Written by the script, contains `*`. The directory ignores itself. |

`--check` verifies: the file exists and is executable; `lipo -archs` is exactly
`arm64 x86_64`; the recorded SHA-256 still matches; `BUILD-INFO.txt` records the
same pin the script holds and `Modifications: NONE`; the binary runs and its
banner says `7-Zip (z) 26.02`; the foreign slice runs too (best effort — the
x86\_64 slice needs Rosetta 2); the `Rar5` handler is present; the code
signature verifies.

---

## The future in-process engine must be built WITHOUT RAR

Milestone M5 replaces the read path with an in-process engine in an XPC service
(`Contents/XPCServices/ArchiveEngine.xpc`), driving `IInArchive`/`IOutArchive`
through the COM-style entry points that `CPP/7zip/Bundles/Format7zF` exports.
That engine **links** 7-Zip code. The moment linking enters the picture, the §7
argument above stops applying — so the RAR handlers must not be in that binary.

Upstream ships the switch for exactly this. From `DOC/readme.txt` (lines
184–196), `DISABLE_RAR=1` "removes whole RAR related code from compilation",
while `DISABLE_RAR_COMPRESS=1` removes only the "not fully free" RAR
decompression codecs. Mechanically, in
`CPP/7zip/Bundles/Format7zF/Arc_gcc.mak`:

* line 200 — `ifndef DISABLE_RAR` guards `RAR_OBJS` (`RarHandler.o`,
  `Rar5Handler.o`) — the *handlers* themselves
* line 283 — `ifdef DISABLE_RAR` implies `DISABLE_RAR_COMPRESS=1`
* line 287 — `ifndef DISABLE_RAR_COMPRESS` guards the decoders (`Rar1Decoder.o`
  … `Rar5Decoder.o`, `Rar3Vm.o`, `RarCodecsRegister.o`)
* line 311 — `ifndef DISABLE_RAR` guards the RAR crypto (`Rar20Crypto.o`,
  `Rar5Aes.o`, `RarAes.o`)

`DISABLE_RAR_COMPRESS=1` alone is **not sufficient**: it leaves the handlers
compiled in, so the RAR-derived code is still linked. The in-process build must
use the stronger flag:

```sh
cd vendor/7zip/CPP/7zip/Bundles/Format7zF
make -j -f ../../cmpl_mac_arm64.mak DISABLE_RAR=1
```

Consequences to design around, not discover late:

* The XPC engine will open **no** RAR archives at all.
* RAR therefore stays on the `7zz` subprocess path indefinitely. The engine
  selection in `ArchiveCore` must route by format, not by preference, and must
  keep working when the in-process engine reports "unsupported".
* Never expose a "create RAR" affordance anywhere in the UI, on any path. RAR
  compression is not implemented upstream and must not be.
* If RAR is ever split into a separately loadable `Codecs/Rar.so` plugin (the
  layout Keka uses), it is still a *separate* file loaded by a *separate*
  process, never linked into anything GPL-3.0.

---

## Bumping the pinned version

A bump is a supply-chain change to the component that parses hostile input on
the user's behalf. Treat it as one.

### 1. Read before you pin

* Upstream release notes for every version between the current pin and the new
  one. Security fixes are frequently described only as "some bugs and
  vulnerabilities were fixed" — assume every skipped release matters.
* `git -C vendor/7zip diff <old-tag>..<new-tag> -- DOC/License.txt` — if the
  licence text moved at all, stop and re-read it in full before continuing.
  `THIRD_PARTY_LICENSES/7-Zip/LICENSE.txt` and the unRAR paragraph in `NOTICE`
  must be reproduced verbatim, so a one-word change upstream is a change here.
* `git -C vendor/7zip diff <old-tag>..<new-tag> --stat -- CPP/7zip/UI/Console CPP/7zip/UI/Common`
  — this is the code whose *output text* `ArchiveCore` parses. Changes here are
  the ones most likely to break the CLI engine silently.

### 2. Move the pin

```sh
git -C vendor/7zip fetch --tags origin
git -C vendor/7zip rev-parse '<new-tag>^{commit}'      # copy this SHA
```

Edit **`vendor/build-7zz.sh`** — it is authoritative:

```sh
PINNED_TAG="<new-tag>"
PINNED_COMMIT="<the SHA you just printed>"
```

Then make **`Scripts/bootstrap.sh`** agree (it holds a copy so a fresh clone can
check out the right commit before `build-7zz.sh` ever runs; bootstrap compares
the two and refuses to continue if they diverge).

```sh
git -C vendor/7zip checkout --detach <the SHA>
git add vendor/7zip vendor/build-7zz.sh Scripts/bootstrap.sh
./vendor/build-7zz.sh --clean
```

### 3. Re-verify — none of this is optional

Per `docs/ENGINE-PROTOCOL.md`, the CLI engine parses a **human-facing UI, not a
contract**. Upstream owes us no stability there. The parser suite is the only
thing standing between a version bump and silent data-listing corruption.

- [ ] **Run the full parser test suite** (`Tests/ArchiveCoreTests`) against the
      newly built `7zz`, not against fixtures recorded from the old one.
- [ ] **`StreamTokenizer`** — confirm progress output still erases with
      backspace (`\b`) and has not switched to `\r`. This is the single
      highest-risk behaviour in the whole engine.
- [ ] **`SLTParser`** — the ten-hyphen separator and the `Key = Value` block
      shape for `l -slt`. The key *set* is format-dependent; re-record the
      per-format expectations. Cross-check the `-slt` item count against the
      `l` summary line, which is how a truncated parse is detected.
- [ ] **`ProgressParser`** — the transient `"%3d%% %d %c %s"` form and the
      permanent `- path` / `+ path` lines.
- [ ] **`ExitCodeMapper`** — 0, 1 (**success with warnings**, not failure), 2,
      7, 8, 255.
- [ ] **`FormatCatalog`** — re-run `7zz i` and diff the handler list. Confirm
      exactly seven creatable formats (7z, zip, gzip, bzip2, xz, tar, wim);
      confirm `Rar` and `Rar5` are still present; note any new handler.
- [ ] **Golden-file corpus** end to end: 7z solid and non-solid, zip, tar.gz
      (the two-layer case), rar, encrypted body, encrypted headers
      (`-mhe=on`), multi-volume, a 200k-entry archive, UTF-8 names
      (`café_日本.txt`), an NFD/NFC pair, a CP932 legacy zip, a deliberately
      corrupted archive, and a filename containing a newline.
- [ ] **`MemoryEstimator`** — dictionary/word/solid/thread enumerations and the
      memory-usage formula, if any level or method defaults moved.
- [ ] Round-trip smoke test: `a -p… -mhe=on` → `l -slt -p…` → `x -p…`,
      byte-compared.

### 4. Update the paperwork

- [ ] `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` — new version, new binary
      SHA-256 (take it from `vendor/bin/BUILD-INFO.txt`), source URL,
      `Modifications: NONE`.
- [ ] `THIRD_PARTY_LICENSES/7-Zip/LICENSE.txt` — refresh verbatim from the new
      `DOC/License.txt` if it changed.
- [ ] `NOTICE` — the unRAR paragraph must remain reproduced in full, starting
      from the words "UnRAR source code". Not a summary, not a link.
- [ ] `CHANGELOG.md` — record the bump and anything user-visible that came with
      it (new formats, changed defaults).
- [ ] Confirm `lipo -info vendor/bin/7zz` still reports both slices and that
      `otool -l` shows the expected minimum OS version.

### 5. Ship

- [ ] Sign and notarize a full DMG and verify the helper: `codesign --verify
      --deep --strict` on the app, and `spctl -a -vvv` on the stapled result.
- [ ] Only then tag a ArcSeven release.

If any box in step 3 is unchecked, the bump is not done. A `7zz` that extracts
correctly but is listed incorrectly is worse than one that fails outright,
because the user finds out later.

---

## Things that are never acceptable in this repository

* Editing anything under `vendor/7zip/`.
* Copying or pasting 7-Zip or unRAR **source code** into `Sources/`. Behaviour
  may be described and cited by file and line, then reimplemented clean-room.
  The code itself does not come across.
* Linking 7-Zip into the app process while the RAR handlers are present.
* Committing anything from `vendor/bin/`.
* Shipping a binary built with `--allow-dirty`.
* Substituting a `7zz` from Homebrew, a distro package, or a random release
  mirror for the one this script builds.
* Any user-facing string that implies affiliation with, or endorsement by,
  7-Zip or Igor Pavlov. References are nominative and descriptive only —
  "compatible with 7-Zip", "a reimplementation of the 7-Zip File Manager" —
  never possessive, never "official".

---

## See also

* `docs/ARCHITECTURE.md` — the module breakdown and the engine milestones
* `docs/ENGINE-PROTOCOL.md` — the `ArchiveEngine` contract and the CLI
  invocation/parsing spec the checklist above tests
* `THIRD_PARTY_LICENSES/7-Zip/` — upstream licence text, version and hashes
* `NOTICE` — attribution, the verbatim unRAR paragraph, trademark disclaimer
