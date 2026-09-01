<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# ArcSeven — Engine Protocol

**The contract between `ArcSeven` and the bundled upstream `7zz` binary.**

This document is normative for everything in `Sources/ArchiveCore/CLIEngine/`. It defines the exact
argv for every operation, the byte-level shape of every stream the child produces, the exit-code
model, the cancellation protocol, and the security properties (and one security *defect*) of the
subprocess design.

> **Provenance.** Every claim tagged **VERIFIED** was produced by actually running a real 7-Zip
> console binary against a purpose-built corpus (see `docs/_backend-rationale.md` and research
> artefact `res_3`). That binary was **7-Zip 18.05** (the universal Mach-O inside Parallels
> Desktop), *not* the 26.02 we ship. Claims tagged **(doc)** come from the 7-Zip manual and have
> not been executed. Claims tagged **(macOS-adapted)** are a reasoned mapping of Windows-specific
> behaviour onto macOS and must be confirmed.
>
> **§10 is not optional.** The parser suite must be re-run against the exact bundled `7zz` on every
> version bump. `-bb` verbosity shapes have changed historically; a silent change to the progress
> encoding would break the stream reader outright, and the failure mode is "the progress bar never
> moves", not a crash.

**Trademark:** ArcSeven is not affiliated with or endorsed by 7-Zip or Igor Pavlov. `7zz` is upstream
7-Zip, bundled unmodified, under LGPL-2.1-or-later; see `THIRD_PARTY_LICENSES/`.

---

## Table of contents

1. [The binary in the bundle](#1-the-binary-in-the-bundle)
2. [The standard switch block](#2-the-standard-switch-block)
3. [Canonical invocations](#3-canonical-invocations)
4. [Progress parsing — the highest-risk area](#4-progress-parsing--the-highest-risk-area)
5. [`-slt` listing parser](#5--slt-listing-parser)
6. [Passwords — the creation asymmetry](#6-passwords--the-creation-asymmetry)
7. [Exit codes and the app error model](#7-exit-codes-and-the-app-error-model)
8. [Cancellation](#8-cancellation)
9. [Format capability gating](#9-format-capability-gating)
10. [Versioning and compatibility](#10-versioning-and-compatibility)
- [Appendix A — argv quick reference](#appendix-a--argv-quick-reference)
- [Appendix B — the M0 verification matrix](#appendix-b--the-m0-verification-matrix)

---

## 1. The binary in the bundle

### 1.1 Location

```
ArcSeven.app/
└── Contents/
    ├── MacOS/ArcSeven ................ the AppKit host
    └── Helpers/
        └── 7zz ....................... upstream 7-Zip console binary, UNMODIFIED
```

Canonical path: **`Contents/Helpers/7zz`**. Nothing else in the bundle is executable except the
host, the app extensions, and Sparkle's own helpers.

In Xcode this is a **Copy Files** build phase with destination *Wrapper* and subpath
`Contents/Helpers` — **not** destination *Executables*, which would land it in `Contents/MacOS`.

### 1.2 Provenance and integrity

- The binary comes from the **official** release tarball `7z2602-mac.tar.xz`
  (`https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz`), byte-for-byte.
- **Do not vendor Homebrew's `sevenzip`.** Homebrew builds with `DISABLE_RAR_COMPRESS=1`, which
  removes the RAR decompression codecs. The result still *lists* RAR archives and extracts *stored*
  entries, so the breakage is invisible in a smoke test and total in the field.
- **Do not vendor p7zip or any fork.** Unmaintained since ~2016 / pinned at 22.00, with years of
  unpatched CVEs in code whose entire job is parsing hostile input.
- `vendor/` carries the fetch script; `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` records the upstream
  version, the tarball SHA-256, the SHA-256 of the extracted `7zz`, and the literal line
  `Modifications: NONE`. CI fails if the shipped binary's digest does not match that file.
- Confirm the binary is universal before it is ever committed:
  ```sh
  lipo -info 7zz          # expect: Architectures in the fat file: 7zz are: x86_64 arm64
  ```
  If it is thin, the build gains a `lipo -create` step over per-arch builds. (High confidence but
  **not** directly verified upstream: the macOS download is a single asset labelled
  "arm64 / x86-64" while Linux gets four per-arch assets.)

### 1.3 How it is signed

ArcSeven is **non-sandboxed**, Developer ID, hardened runtime, notarized, stapled. The helper is
signed **first**, inside-out, with the project identity:

```sh
TEAM="HAMH7N3PJR"
ID="Developer ID Application: Rajesh DMonte ($TEAM)"

# 1. Helper FIRST. No --entitlements argument at all.
codesign --force --options runtime --timestamp --sign "$ID" \
         "ArcSeven.app/Contents/Helpers/7zz"

# 2. Frameworks, 3. app extensions, 4. the app LAST (see docs/ARCHITECTURE.md)

# Verify the way Gatekeeper will
codesign --verify --deep --strict --verbose=4 "ArcSeven.app"
spctl -a -vvv -t exec "ArcSeven.app"
codesign -dv --entitlements :- "ArcSeven.app/Contents/Helpers/7zz"   # expect: no entitlements
```

Rules:

- **`--options runtime` on the helper is mandatory.** Notarization rejects any un-hardened Mach-O
  anywhere in the bundle.
- **`--timestamp` is mandatory.** Notarization rejects un-timestamped signatures.
- **Never `codesign --deep` to *sign*.** It applies the wrong entitlements to nested code. `--deep`
  is for *verification* only.
- **The helper carries no entitlements.** Keka's `keka7zz` carries exactly two —
  `com.apple.security.app-sandbox` and `com.apple.security.inherit` — *because Keka is sandboxed
  and the child must inherit the sandbox*. ArcSeven is not sandboxed, so the correct entitlement set
  for our helper is the empty set. Adding `com.apple.security.inherit` to a child of a
  non-sandboxed parent is meaningless at best.

### 1.4 Why no `com.apple.security.cs.*` entitlement is required

> **Executing a separate process was never gated by library validation.** `posix_spawn` on a
> signed, notarized child is plain-vanilla behaviour. No `com.apple.security.cs.*` key is involved.

Library validation requires that code *loaded into a process* be signed by the **same Team ID** as
the host, or by Apple. Two consequences:

1. For a **spawned executable** it does not apply at all — the child is its own process with its
   own code-signing context.
2. For anything we ever `dlopen` (the M5 in-process engine's `7z.dylib`), it applies — and it is
   satisfied automatically because we sign that dylib with **`HAMH7N3PJR`**, the same Team ID as
   the host. You would need `com.apple.security.cs.disable-library-validation` only to load code
   signed by a *different* team or unsigned, which we must never do (notarization would reject it
   anyway).

**Keka is the existence proof.** Shipping, hardened (`flags=0x10000(runtime)`), Developer ID,
notarized, stapled — and its entitlements contain **zero** `cs.*` keys, while it spawns
`Contents/MacOS/keka7zz` and `dlopen`s `7z.so` plus `Codecs/Rar.so`, all signed with its own team
`4FG648TM2A`.

The complete `com.apple.security.cs.*` set and our need for each:

| Entitlement | Purpose | Needed by ArcSeven |
|---|---|---|
| `com.apple.security.cs.allow-jit` | `MAP_JIT` executable memory | **No** (this is the Electron key) |
| `com.apple.security.cs.allow-unsigned-executable-memory` | unsigned exec pages | **No** |
| `com.apple.security.cs.allow-dyld-environment-variables` | honour `DYLD_*` | **No** |
| `com.apple.security.cs.disable-library-validation` | load code from another Team ID | **No** — we sign our own helpers |
| `com.apple.security.cs.disable-executable-page-protection` | disable W^X | **No** (very invasive) |
| `com.apple.security.cs.debugger` | attach as debugger | **No** |
| `com.apple.security.cs.jit-write-allowlist` / `…-freeze-late` | newer JIT hardening | **No** |

**An AppKit archive manager needs none of them.** If a `cs.*` key ever appears in
`ArcSeven.entitlements`, that is a defect: something is being loaded that should not be, or a
signing step was skipped. CI asserts the entitlement set is exactly the expected one.

Because the hardened runtime strips `DYLD_*` from the child's environment (we do **not** hold
`allow-dyld-environment-variables`), the helper cannot be hijacked by injected libraries. This is a
security property we get for free and must not give away.

### 1.5 Resolving and validating the helper at runtime

```swift
// Deterministic; no CFBundle auxiliary-executable search-path ambiguity.
let helper = Bundle.main.bundleURL
    .appendingPathComponent("Contents/Helpers/7zz", isDirectory: false)
```

Before the **first** spawn of a process lifetime, `SevenZipCLIEngine` must:

1. Resolve symlinks and assert the result is still inside `Bundle.main.bundleURL` (defeats a
   symlink-swap in a writable bundle copy).
2. Verify the code signature and pin the Team ID:
   ```
   anchor apple generic and certificate leaf[subject.OU] = "HAMH7N3PJR"
   ```
   via `SecStaticCodeCreateWithPath` + `SecRequirementCreateWithString` +
   `SecStaticCodeCheckValidity`. Cache the result for the process lifetime.
3. On failure, refuse to spawn and surface *Engine unavailable — the bundled 7-Zip binary failed
   signature validation.* Never fall back to a `7zz` found on `PATH`; an archiver silently driving
   an unknown binary is a supply-chain hole.

The Settings ▸ Advanced "engine binary path" override exists (a developer/power-user affordance).
For a user-supplied path the Team ID requirement is skipped, but the app must show a persistent,
non-dismissible warning banner in the operation UI and must never select such a binary
automatically.

### 1.6 Who may spawn the helper

| Component | May spawn `7zz` |
|---|---|
| Main app (`ArcSeven`, non-sandboxed) | **Yes** — the only spawner |
| `QuickLookPreview.appex` (sandboxed) | **No** — pure-Swift header parser, no spawn |
| `ArcSevenFinder.appex` (sandboxed) | **No** — hands URLs to the app via app group + `NSWorkspace.openApplication` |
| `QuickActions` App Intents appex | **Not built.** The target was removed; if it ever lands it routes to the app over the authenticated App-Group transport and spawns nothing |

App extensions are sandboxed by design; a child inherits only the parent's **static** entitlements,
never dynamically acquired PowerBox grants, so a spawn from an appex cannot reach a user-selected
path. Keep spawning in the app.

---

## 2. The standard switch block

### 2.1 The block

```
-bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8
```

In Swift:

```swift
enum SevenZip {
    /// Applies to every operation. Per-command deltas are documented in §3.
    static let standardSwitches = [
        "-bb3",        // per-file log lines
        "-bso1",       // normal output  -> stdout
        "-bsp2",       // progress       -> stderr
        "-bse2",       // errors         -> stderr
        "-ba",         // no banner / no list header+footer
        "-y",          // assume Yes to every query
        "-sccUTF-8",   // console charset
        "-scsUTF-8",   // list-file charset
    ]
}
```

Canonical argv order, fixed so that logs and golden-file tests are byte-reproducible:

```
7zz  <command>  <standard block>  <command-specific switches>  <archive>  [<args> | @listfile]
```

7-Zip accepts switches anywhere after the command; we always place them in this order anyway.

### 2.2 Why each switch is there

| Switch | Meaning | Why we pass it |
|---|---|---|
| `-bb3` | Output log level 3 (per-file lines) | Produces the permanent `- path` / `+ path` lines that are the **authoritative** per-file record and the extraction cleanup manifest (§8.4). `-bb0` suppresses them entirely. On 18.05, `-bb1`/`-bb2`/`-bb3` were identical for these cases (**VERIFIED**); 26.x is documented to add detail at higher levels. `-bb3` costs nothing. |
| `-bso1` | Normal (log) output → **stdout** | Gives a clean, newline-terminated, **backspace-free** stdout. This is the stream the line parser reads. |
| `-bsp2` | Progress → **stderr** | Confines all in-place backspace rewriting to one stream, so the two parsers never have to disentangle progress from log. |
| `-bse2` | Errors → **stderr** | Errors are newline-terminated even on stderr, so the tokenizer separates them from progress structurally: *a completed line on stderr is a message; the live, unterminated buffer is progress* (§4.2). |
| `-ba` | Suppress banner (and the `l` table header/footer) | Removes the version banner and "Scanning the drive for archives:" preamble so the first stdout line is meaningful. **`-ba` is undocumented** — it is not in the official switch list but is present and working in every version tested (**VERIFIED**). This is the single most likely switch to change behaviour on a version bump; §10 tests it explicitly. |
| `-y` | Assume **Yes** on all queries | **MANDATORY.** Any prompt reaching a closed stdin yields exit **255 / "Break signaled"** — indistinguishable from a user cancel. Without `-y`, a plain re-extract over existing files hits the overwrite prompt and dies 255 on *every* run (**VERIFIED**). With `-y` always present, a 255 that we did not signal is unambiguously a bug in our argv (§7.3). |
| `-sccUTF-8` | Console I/O charset | Belt-and-braces. UTF-8 filenames already round-trip as raw UTF-8 bytes on macOS with no switch (**VERIFIED**: `src/café_日本.txt` emerged as correct UTF-8 under `cat -v`). `-scc` exists for Windows code-page problems; passing it costs nothing and pins behaviour against a future default change. |
| `-scsUTF-8` | **List-file** charset | Load-bearing. We pass every file selection through a `@listfile` (§2.4) and the list file is UTF-8. Without this the interpretation is locale-dependent. |

### 2.3 `-spf`, `-spf2` and path modes

`-spf` stores **fully qualified** paths; `-spf2` stores them **without the leading separator**
(**VERIFIED**: `-spf` put `/private/tmp/.../src/small.txt` inside the archive; `-spf2` stripped the
leading `/`).

`-spf` is **not on by default**. It is the engine mapping for one specific value of the Add
dialog's *Path mode* combo, and the default (Relative pathnames) is achieved by setting the child's
working directory instead. Passing `-spf` unconditionally would embed the user's home directory
path in every archive they share.

Add dialog — *Path mode* (`IDC_COMPRESS_PATH_MODE`):

| Combo item | 7zFM `ECensorPathMode` | Engine mapping |
|---|---|---|
| `Relative pathnames` (default) | `k_RelatPath` | **no switch**; child `cwd` = the browsed-from directory, list file holds paths relative to it |
| `Full pathnames` | `k_FullPath` | `-spf2` — *(macOS-adapted: on Windows this strips the drive prefix; on macOS the analogue is the leading `/`)* |
| `Absolute pathnames` | `k_AbsPath` | `-spf` |

Extract dialog — *Path mode* (`IDC_EXTRACT_PATH_MODE`):

| Combo item | 7zFM `NPathMode` | Engine mapping |
|---|---|---|
| `Full pathnames` | `kFullPaths` | command **`x`** |
| `No pathnames` | `kNoPaths` | command **`e`** (see the collision warning in §3.5) |
| `Absolute pathnames` | `kAbsPaths` | `x -spf` **(doc — unverified on the extract side; Appendix B)** |

`kCurPaths` is not user-selectable; it is the mode used when extracting a selection from inside an
open archive, and 7zFM's sticky-preservation rule must be reproduced (see `res_8` §2.2).

Related: `-spe` (eliminate root-folder duplication) maps to the Extract dialog's *Eliminate
duplication of root folder* checkbox.

### 2.4 The `@listfile` contract

**Every file/entry selection goes through a list file. Never build a long argv.**

- `ARG_MAX` on macOS is ~1 MB. A user selecting a few thousand files with long paths blows it and
  the failure (`E2BIG`) surfaces as an opaque spawn error.
- Argv has no shell involved (we use `posix_spawn` with an argv array), so there is no *quoting*
  bug — but there is a **leading-hyphen** bug: a path or member name beginning with `-` is parsed
  as a switch. List-file contents are never switch-parsed, which removes the class entirely.

Rules for writing a list file:

1. UTF-8, **no BOM**, **LF** line endings, one path per line, final line LF-terminated.
2. Never emit an empty line (filter empties before writing); an empty name is at best ignored.
3. Paths are relative to the child's working directory in Relative path mode, absolute otherwise.
4. Write it into the operation's own scratch directory (`TMPDIR` of the operation, §8.5), mode
   `0600`, and delete it when the operation's process has been reaped — **not** before, since 7-Zip
   may re-read it.
5. Pass it as the last argv element, `@` + absolute path: `"@/private/var/folders/…/sel.txt"`.
6. `-scsUTF-8` must be in the argv (it is, via the standard block).

**The one case a list file cannot express:** an entry whose name contains a newline. The list-file
format is newline-delimited, so such an entry is unaddressable. It must be passed as a direct argv
argument, preceded by `--` to stop switch parsing:

```
7zz x <std block> -o/dest -- /abs/archive.7z "weird\nname.txt"
```

`--` is **(doc)** — verify at M0 (Appendix B). Until it is verified, entries whose names contain
control characters are surfaced read-only in the UI and cannot be individually extracted or
deleted; whole-archive extraction still works.

### 2.5 Process environment, working directory, file descriptors

- **Working directory** is set explicitly per operation (`posix_spawn` + `chdir` in the file
  actions, or `Process.currentDirectoryURL`). Relative path mode depends on it. Never inherit the
  app's cwd.
- **Environment** is constructed explicitly, not inherited wholesale: `PATH` (minimal), `HOME`,
  and `TMPDIR` pointed at the operation's own scratch directory so 7-Zip's update temp files land
  on a volume we control and are cleaned up with the operation. `DYLD_*` is stripped by the
  hardened runtime regardless.
  - `-w{dir}` is the documented switch for 7-Zip's own working directory **(doc)**; if M0 confirms
    it, prefer it to `TMPDIR` for `u` and `d` on large archives so the temp copy lands on the same
    volume as the archive.
- **File descriptors:** spawn with `POSIX_SPAWN_CLOEXEC_DEFAULT` so nothing but the three standard
  descriptors is inherited. stdin, stdout and stderr are each a fresh pipe. Never inherit the app's
  stdin.
- **stdin is always closed after we finish writing.** If a password is supplied, write it plus a
  newline, then close. If not, close immediately. This is deliberate: an unexpected prompt then
  fails fast with exit 255 instead of hanging the operation forever.
- **Drain stdout and stderr concurrently.** A full 64 KiB pipe buffer on stderr blocks the child
  while we sit blocked reading stdout. Use two independent readers (`DispatchIO` or a
  `readabilityHandler` per handle) feeding two independent tokenizer instances.
- Ignore `SIGPIPE` process-wide, and never close a read end while the child is alive — always drain
  to EOF (§8.3).

---

## 3. Canonical invocations

Notation: `STD` = the standard switch block from §2.1. `<archive>` is always an **absolute**
path (an absolute path begins with `/`, so it can never be mistaken for a switch).

### 3.1 `list` — plain listing (count cross-check only)

```
7zz l -bso1 -bse2 -bsp0 -y -sccUTF-8 -- <archive>
```

Deltas from `STD`: **no `-ba`** (the `N files, M folders` summary lives in the footer that `-ba`
strips), `-bsp0` (progress routing disabled — listing has none worth showing), no `-bb3`.

This is **not** the listing the app parses. Its only job is the trailing summary line used as a
cross-check against the `-slt` item count (§5.6):

```
2026-08-24 17:01:05            3000032         5471  4 files, 2 folders
```

**Never parse the plain `l` table.** The `Name` column is last and unquoted (a filename with a
leading/trailing space or a newline breaks it), the `Compressed` column is *blank* for solid-block
members, and the attribute column is positional. It is a human format.

### 3.2 `list-verbose` — `-slt`, the machine-readable listing

```
7zz l -slt -bso1 -bse2 -bsp0 -y -sccUTF-8 -- <archive>
```

Deltas from `STD`: **no `-ba`**, `-bsp0`, no `-bb3`.

`-ba` is deliberately omitted. Its effect on the `-slt` preamble (the `--` archive-property block
and the ten-hyphen separator) is **not** established, and those lines are the state machine's
anchors. The §5 parser is tolerant of their absence anyway, but we do not depend on that.

With a password (see §6.1 — supplied on **stdin**, not argv):

```
printf '%s\n' "$PW" | 7zz l -slt -bso1 -bse2 -bsp0 -y -sccUTF-8 -- <archive>
```

### 3.3 `extract-with-paths` — `x`

```
7zz x -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     -o<destDir> [-aoa|-aos|-aot|-aou] [-spe] [-mmt=<N>] \
     -- <archive> [@<listfile>]
```

- `-o<dir>` takes **no space** and no quoting (argv array): `"-o/Users/me/Downloads/out"`.
- Omitting the `@listfile` extracts everything.
- Overwrite switch: exactly one of `-aoa` (always), `-aos` (skip existing), `-aot` (auto-rename the
  **existing** file), `-aou` (auto-rename the **incoming** file). See §3.10 for the mapping and for
  how *Ask before overwrite* is implemented.
- Stdout carries permanent `- <path>` lines, one per extracted entry (`-bb3`). Stderr carries the
  transient progress token ` 34% 2`.

### 3.4 `extract-flat` — `e`

```
7zz e -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     -o<destDir> [-aoa|-aos|-aot|-aou] [-mmt=<N>] \
     -- <archive> [@<listfile>]
```

`e` flattens every entry into `<destDir>`. **This is lossy**: `a/readme.txt` and `b/readme.txt`
collapse onto one name, and with `-aoa` the later one silently wins.

**Contract:** before running `e`, the app computes basename collisions from the already-parsed
`-slt` listing and, if any exist, presents a warning naming the count and a sample. 7zFM prompts
per collision at run time; we cannot (we hold `-y`), and a pre-flight warning is strictly better
UX. Record it in `docs/DIVERGENCES.md`.

### 3.5 `test` — `t`

```
7zz t -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     [-mmt=<N>] -- <archive> [@<listfile>]
```

`t` is extraction to `/dev/null` with CRC verification and **works on any readable format**, not
only the seven creatable ones. Failures appear as per-entry lines and a count, with exit **2**
(**VERIFIED** against a deliberately corrupted `.7z`):

```
ERROR: Data Error : src/big.bin
ERROR: Data Error : src/café_日本.txt
Sub items Errors: 4
```

The per-entry operation character used by `t` in the `-bb3` log is **not** established — do not
assume `-`. The §4.5 permanent-line grammar captures the operation character rather than matching a
literal, so an unexpected character degrades to "unknown op, path recorded", never to a parse
failure. Pin the actual character at M0.

### 3.6 `add` — `a`

```
7zz a -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     -t<format> -mx=<0..9> [-m<prop>=<val> …] [-ms=on|off] [-mmt=<N>] \
     [-mhe=on] [-p<password>] [-spf|-spf2] [-v<size>] [-sdel] \
     -- <archive> @<listfile>
```

Working directory is set to the base directory; the list file holds paths relative to it (Relative
path mode). Method properties use the `-m<name>=<value>` form throughout: `-mx=9`, `-md=64m`,
`-mfb=64`, `-ms=on`, `-mmt=8`, `-mhe=on`. (7-Zip accepts both `-mx9` and `-mx=9`; we always use the
`=` form so the argv is uniform and greppable.)

Verified end to end (**VERIFIED**, 18.05):

```
7zz a -bb3 -bso1 -bsp2 -bse2 -ba -y -mx=9 -md=64m rec.7z big/src
```

- stdout: `Scanning the drive:` … `Creating archive: rec.7z` … `+ <path>` lines …
  `Files read from disk: 60`, `Archive size: 93685 bytes (92 KiB)`, `Everything is Ok`.
- stderr: `  0%`, `  8% 4 + big/src/file04.dat`, … (backspace-erased, §4).

The Add dialog's free-form **Parameters** field is tokenised on whitespace, `-m`/`-M` prefixes are
stripped, and each token is split at the **first** `=`; the resulting properties are appended
*after* the dialog-derived ones so they override (see `res_8` §1.18). They are appended to argv in
the same position, immediately before the archive path.

`-sdel` (delete source files after successful compression) really does delete (**VERIFIED**). It is
gated behind an explicit, separately-confirmed user action and is never a remembered default.

### 3.7 `update` — `u`

```
7zz u -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     [-u<actionset>] [-m<prop>=<val> …] [-p<password>] \
     -- <archive> @<listfile>
```

Add-dialog *Update mode* (`IDC_COMPRESS_UPDATE_MODE`) mapping:

| Combo item | 7zFM `NUpdateMode` | Engine mapping | Status |
|---|---|---|---|
| `Add and replace files` | `kAdd` | command **`a`** (§3.6) | **VERIFIED** |
| `Update and add files` | `kUpdate` | command **`u`**, default action set | (doc) |
| `Freshen existing files` | `kFresh` | `u -uq0` | **transcribed, unverified** |
| `Synchronize files` | `kSync` | `u -up0q3r2x2y2z0w2` | **transcribed, unverified** |

The `-u` grammar is `-u[-][p#][q#][r#][x#][y#][z#][w#]`, where the letter selects a file *state*
and the digit selects the *action* **(doc)**:

| Letter | State |
|---|---|
| `p` | in archive, not matched by the selection |
| `q` | in archive, absent from disk |
| `r` | not in archive, present on disk |
| `x` | archive copy newer than disk copy |
| `y` | archive copy older than disk copy |
| `z` | archive copy same as disk copy |
| `w` | cannot determine which is newer |

| Digit | Action |
|---|---|
| `0` | ignore |
| `1` | copy (from the old archive) |
| `2` | compress (from disk) |
| `3` | create anti-item (7z only) |

**Getting an action set wrong silently mangles an archive.** *Freshen* and *Synchronize* stay
disabled in the UI until a golden-file test proves the exact resulting entry set for each: build a
fixture archive, mutate the tree (add / remove / touch newer / touch older / leave identical), run
the mode, assert the exact `l -slt` output. Until then, `Add and replace` and `Update and add` are
the only two offered. If the transcribed strings fail verification, implement *Synchronize* in the
app instead — compute the difference set from the `-slt` listing and issue explicit `d` then `a`
passes — rather than guessing at digits.

### 3.8 `delete` — `d`

```
7zz d -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
     [-p<password>] -- <archive> @<listfile>
```

`d` rewrites the archive through a temp file and renames, so the original survives a cancel intact
(**VERIFIED** for the update path generally). The list file holds **archive-internal** paths, taken
verbatim from `-slt`'s `Path` values — not filesystem paths.

### 3.9 `rename` — `rn`

```
7zz rn -bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8 \
      [-p<password>] -- <archive> <oldPath> <newPath> [<oldPath> <newPath> …]
```

Arguments are **pairs on argv**, in order. This is the one operation that does not use a list file,
because the pairing is positional and a newline-delimited list file cannot express it
unambiguously. Consequences:

- `--` is required before the first path, since an entry name may begin with `-`.
- Batches are chunked to stay well under `ARG_MAX` (cap at 1024 pairs or 256 KiB of argv,
  whichever comes first) and issued as successive `rn` invocations.
- The 7zFM file pane renames one entry at a time (`F2`), so the single-pair form is the hot path.
- `rn` with a list file of alternating lines is **unverified**; do not rely on it.

### 3.10 Overwrite modes, and why *Ask* cannot be delegated

| Extract dialog item | 7zFM `NOverwriteMode` | Engine mapping |
|---|---|---|
| `Ask before overwrite` | `kAsk` | **no switch** — implemented by the app, see below |
| `Overwrite without prompt` | `kOverwrite` | `-aoa` |
| `Skip existing files` | `kSkip` | `-aos` |
| `Auto rename` (renames the *incoming* file) | `kRename` | `-aou` |
| `Auto rename existing files` | `kRenameExisting` | `-aot` |

Because `-y` is mandatory, `7zz` can never prompt us, so *Ask* is implemented **ahead of the run**:

1. From the parsed `-slt` listing, compute the destination path for every selected entry.
2. `stat()` each; collect collisions.
3. Present the 7zFM overwrite dialog (Yes / No / Yes to All / No to All / Auto rename / Auto rename
   existing / Cancel) with the two file summaries, 1:1.
4. Partition the entry set by decision and run **one pass per decision class**, each with its own
   list file and its own explicit `-ao*` switch.
5. If more than two classes result — or the archive is **solid `.7z`**, where each pass re-decodes
   the whole block — extract once into the operation's staging directory with `-aoa` and apply the
   per-entry decisions as `rename(2)` moves (§8.5).

A collision that appears *after* step 2 (something else wrote the file meanwhile) is resolved by
the explicit `-ao*` switch with no prompt, so it can never hang the operation.

### 3.11 `benchmark` — `b`

```
7zz b <passes> -bso1 -bse2 -bsp0 -y [-mmt=<threads>] [-md=<dictSize>] [-mm=<method>]
```

Deltas from `STD`: no `-ba` (the benchmark report is the whole point of stdout), no `-bb3`,
`-bsp0`.

The three Benchmark-dialog inputs (`res_7` §9.1) map as: *Passes* → the positional iteration count,
*Number of CPU threads* → `-mmt=`, *Dictionary size* → `-md=`.

**Unverified, and the dictionary spelling is the risk.** The `b` command historically accepts a
log-2 form (`-md26`) as well as the byte-suffix form (`-md=64m`) used by `a`. Resolve this at M0 by
running both against the bundled binary and comparing the reported dictionary column; record the
answer in Appendix B before wiring the dialog.

Result parsing is deliberately tolerant. The Benchmark window has a **raw log column**
(`IDT_BENCH_LOG`), so every line is displayed verbatim regardless; the structured fields (Size,
Speed, CPU Usage, Rating/Usage, Rating, per compress/decompress, plus the total row) are filled
from a numeric-column regex and left blank when a line does not match. A shape change in a future
version therefore degrades to "the log still works", never to a crash or a wrong number.

Additionally, the dialog reports the **P-core / E-core split** (`hw.perflevel0/1.logicalcpu`) —
a Mac-native improvement over the Windows original, and the reason the default thread count is the
P-core count rather than `activeProcessorCount`.

### 3.12 `hash` — `h`

```
7zz h -scrc<Method> -bso1 -bse2 -bsp2 -y -sccUTF-8 -scsUTF-8 -- @<listfile>
```

`-scrc<Method>` selects the hash function; `-scrc*` computes every registered hasher **(doc)**.
Method names, in the exact 7zFM `File ▸ CRC` submenu order (`res_8` §8.1):

`CRC32`, `CRC64`, `XXH64`, `MD5`, `SHA1`, `SHA256`, `SHA384`, `SHA512`, `SHA3-256`, `BLAKE2sp`,
and `*` for all (which iterates registered hashers ascending by codec ID).

**Capability gating.** The registered hasher set differs across 7-Zip versions. At first run (and
whenever the engine's version string changes) the app enumerates what the bundled binary actually
supports and hides the submenu items it does not. Preferred source is the `Hashers:` section of
`7zz i` (§9.3); fall back to probing `h -scrc<Method>` against a one-byte temp file. Both are
**unverified** — Appendix B.

Digest formatting is 7zFM's, not ours (`res_8` §8.2): digests **> 8 bytes** render **lowercase**
hex, digests **≤ 8 bytes** render **UPPERCASE** hex, and the aggregate "…for data" / "…for data and
names" rows carry a `-` plus 8 or 16 uppercase hex characters of extra bytes.

For archive **members**, `l -slt` already yields `CRC = 8E29F6F7` per entry with zero extraction —
use it, and never spawn `h` for a CRC32 the listing already gave you. A member checksum for any
other algorithm requires `x -so` piped into a native hasher (§3.13).

### 3.13 Streaming a single member to stdout (`-so`)

```
7zz x -so -bso0 -bse2 -bsp0 -y -sccUTF-8 -- <archive> <memberPath>
```

`-so` writes the member's **data** to stdout; `-bso0` disables the **log** stream (**VERIFIED**:
`-bso0` yields exactly 0 bytes of log on stdout). This is the Quick Look / preview path — no temp
file, no disk write.

The interaction of `-so` (data) with `-bso0` (log) is asserted at M0 by round-tripping a known
member and comparing bytes (Appendix B).

### 3.14 The `.tar.gz` double layer

`.tar.gz`, `.tar.xz`, `.tar.bz2` are **two containers**. `l` on `n.tar.gz` shows a single entry
`n.tar`. Peeking inside without a temp file (**VERIFIED**):

```
7zz x -so -bso0 -bse2 -bsp0 -y -- n.tar.gz  |  7zz l -ba -si -ttar -bso1 -bse2 -bsp0 -y
```

`-si` reads the archive from stdin; `-ttar` names the inner type explicitly (type sniffing on a
non-seekable stream is unreliable). The `ArchiveFolder` provider handles this as a nested-archive
chain, exactly as 7zFM does; a user must never see "this archive contains one file".

Creating a `.tar.gz` is symmetrically two passes: `a -ttar` then `a -tgzip` over the resulting
`.tar` (§9.2).

---

## 4. Progress parsing — the highest-risk area

> **This is the single most important parsing fact in the project, and the one that is usually
> gotten wrong: 7-Zip erases the progress indicator with BACKSPACE (`0x08`), not carriage return.**

Write the tokenizer once, test it hard, and never touch it again.

### 4.1 The encoding

Raw `x -bsp1 -bb3` output through `cat -v` (**VERIFIED**, 18.05):

```
  0%^H^H^H^H    ^H^H^H^H- src
  0%^H^H^H^H    ^H^H^H^H- src/sub
  0% 1^H^H^H^H^H^H      ^H^H^H^H^H^H- src/big.bin
 34% 2^H^H^H^H^H^H      ^H^H^H^H^H^H- src/café_日本.txt
100% 3^H^H^H^H^H^H      ^H^H^H^H^H^H- src/small.txt
100% 4^H^H^H^H^H^H      ^H^H^H^H^H^H- src/sub/nested.txt
100% 5^H^H^H^H^H^H      ^H^H^H^H^HEverything is Ok
```

The cycle is: **emit token → *N* backspaces → *N* spaces → *N* backspaces**. There is no `\r`
anywhere. A `\r`-based or `readLine()`-based reader sees one gigantic line and reports nothing at
all until the process exits.

Note the last line: 6 spaces followed by only **5** backspaces, so `Everything is Ok` is written at
column 1 and the emitted line carries a leading space. That artefact exists only when log and
progress share a stream. Under our standard block (`-bso1 -bsp2`) they never do, and stdout is
backspace-free — but the tokenizer is backspace-aware on **both** streams anyway, because assuming
otherwise is how this breaks silently on a version bump.

### 4.2 The tokenizer contract

`StreamTokenizer` is a **byte-level line emulator**, not a line reader. One instance per stream.

State:

```swift
final class StreamTokenizer {
    private var buffer: [UInt8] = []   // the current logical line
    private var cursor: Int = 0        // write position within buffer
    private var dirty: Bool = false    // bytes arrived since the last transient emit

    enum Event {
        case line(String)        // PERMANENT: a \n-terminated logical line
        case transient(String)   // LIVE: the current, unterminated buffer
        case overflow            // buffer cap exceeded; buffer was flushed and reset
    }

    func consume(_ bytes: UnsafeRawBufferPointer) -> [Event]
    func finish() -> [Event]     // called once at EOF
}
```

Per-byte rules:

| Byte | Action |
|---|---|
| `\n` (0x0A) | Emit `.line(decode(buffer))`. Clear `buffer`, `cursor = 0`, `dirty = false`. |
| `\b` (0x08) | `cursor = max(0, cursor - 1)`. **Do not truncate `buffer`.** |
| `\r` (0x0D) | `cursor = 0`. Not emitted by any verified build; handled defensively. **Raise a diagnostic the first time one is seen** — if 26.02 switched to CR-based erasure the whole model changed and §10 must run. |
| `ESC` (0x1B) followed by `[` | Consume a CSI sequence (parameter bytes `0x30–0x3F`, intermediates `0x20–0x2F`, one final byte `0x40–0x7E`) and discard it. No verified build emits ANSI, but a future colourised build must not corrupt the buffer. |
| anything else | Write at `cursor`; append if `cursor == buffer.count`; `cursor += 1`; `dirty = true`. |

Bytes `0x00–0x07`, `0x0B`, `0x0C`, `0x0E–0x1F` are not expected. They are written through as
ordinary bytes and handled at decode time; they must never throw or truncate.

**Transient emission timing — the critical rule:** emit at most **one** `.transient` per
`consume()` call, *after* the whole chunk has been processed, and only if `dirty`. Never emit
mid-chunk. A chunk normally contains a complete erase-write cycle, and mid-chunk snapshots would
surface the all-spaces erase frame as a progress value.

**Decoding.** The buffer is decoded to `String` only at emit time. A chunk boundary can split a
multi-byte UTF-8 sequence, so before decoding a **transient** snapshot, trailing bytes forming an
incomplete UTF-8 sequence are dropped (never replaced with U+FFFD — a flickering replacement
character in a progress label is worse than a one-frame-shorter path). Permanent lines are
`\n`-terminated and therefore always complete; decode them strictly and flag any invalid sequence
as a `suspiciousEntry`.

**Buffer cap.** A hostile or broken stream with no newline could grow the buffer without bound.
Cap it at **64 KiB**; on overflow emit `.overflow` plus `.line(decode(buffer))` marked truncated,
then reset. This bounds memory for an archive crafted to have an enormous entry name.

**Trailing-space trim.** Before matching a `.transient` against the grammars in §4.5, trim
**trailing** spaces only (never leading, never on permanent lines). This makes half-erased frames
such as `" 34% 2"` → `" 34%  "` → `" 34%"` degrade to a stale-but-correct percent instead of a
parse failure.

### 4.3 Tokens split across read boundaries

The tokenizer is a pure state machine over bytes and holds no assumption about chunk size, so a
split is not an error state. The behaviour, exactly:

| Split point | Result |
|---|---|
| mid-token, after a complete `NN%` (` 34% 2 + big/sr`) | Matches the creation grammar. Percent and counter are **correct**; the path label is **truncated** and is corrected on the next chunk. |
| mid-percent (`" 3"`) | Fails the anchored grammar → **discard**, keep the last good value. |
| inside the backspace run | Buffer holds the un-erased token → the last good value repeats. Harmless. |
| inside the space run | Buffer trims to empty → **discard**. |
| mid-UTF-8 sequence | Trailing incomplete sequence dropped before decoding (§4.2). |
| mid permanent line | No `.line` until the `\n` arrives. Permanent lines are never partial. |

**Contract:** a `.transient` path label is a **label only**. It must never be used as an identity,
a cleanup manifest entry, or a key. The authoritative per-file record is the permanent
`- path` / `+ path` line on **stdout** (§4.5).

### 4.4 No TTY required

**Progress fires regardless of TTY** (**VERIFIED**: every capture above was redirected to a file).
There is no `isatty()` gate, no terminal-width dependence, and **no pty is needed**. This is the
crucial difference from tools like `rsync` or `git`, and it is the reason the subprocess
architecture is viable at all.

Two consequences:

- The tokenizer needs no ANSI parser in practice (the defensive CSI rule in §4.2 is insurance).
- **Latency contingency.** 7-Zip must call `fflush` explicitly after each tick, because progress
  carries no newline and would otherwise be invisible even on a TTY — so ticks should arrive
  promptly through a pipe. This is *inference*, not measurement. M0 measures tick arrival latency
  through a pipe on a long job (Appendix B). If ticks turn out to be block-buffered, the fallback
  is a pty on **fd 2 only** (`openpty`, dup the slave to stderr, keep stdout a pipe), which
  preserves the `-bso1 -bsp2` stream separation. Do not reach for a pty on both descriptors: that
  merges the two streams and destroys the entire routing design.

### 4.5 The grammars

Three transient shapes and one permanent shape are established.

**T1 — scan phase** (during `a`, while 7-Zip walks the input tree). Observed as `  0M Scan `
(**VERIFIED**, on stderr, backspace-erased):

```
^ *(?<mib>\d+)M Scan ?(?<location>.*)$
```

Only the empty-`location` form was captured. Treat `location` as an opaque hint, display it
verbatim, never parse it. During T1 there is no percentage — the UI shows an indeterminate bar with
"Scanning… *N* MiB".

**T2 — extraction / test transient.** Observed `  0%`, ` 34% 2`, `100% 5`:

```
^ *(?<pct>\d{1,3})%(?: +(?<count>\d+))?$
```

**T3 — creation transient** (the filename is *in* the transient token, not only in the log).
Observed ` 16% 9 + big/src/file09.dat`. Format is `%3d%% %d %c %s`:

```
^ *(?<pct>\d{1,3})%(?: +(?<count>\d+))?(?: (?<op>\S) (?<path>.*))?$
```

T3 subsumes T2, so a single anchored regex covers both:

```
^[ ]*([0-9]{1,3})%(?:[ ]+([0-9]+))?(?:[ ](\S)[ ](.*))?$
```

Capture groups: `1` = percent, `2` = file counter (optional), `3` = operation character (optional),
`4` = path (optional). **Only `+` (add) and `-` (extract) are verified** operation characters. Any
other single character is carried through as `unknownOp` — the path is still displayed, but no
semantic is attached. Never match a literal `[+-]`; that turns an unrecognised character into a
parse failure.

**P1 — the permanent per-file line**, on **stdout**, produced by `-bb3`:

```
^(?<op>\S) (?<path>.*)$
```

- `- <path>` — an entry was **extracted** (`x`, `e`). **VERIFIED.**
- `+ <path>` — an entry was **added** (`a`, `u`). **VERIFIED.**
- Anything else — `unknownOp`, path recorded, no semantic.

Everything else on stdout is a status line and is matched against a small set of known prefixes
(`Scanning the drive`, `Creating archive:`, `Updating archive:`, `Add new data to archive:`,
`Files read from disk:`, `Archive size:`, `Everything is Ok`, `Scan WARNINGS`, `ERROR`,
`WARNING`, `Sub items Errors:`), with unmatched lines kept verbatim in the operation log. Status
text is **English-only and unlocalised**, and may be reworded between versions — it is diagnostic,
never a control-flow input. The exit code is the authority (§7).

**Assertion:** under the standard block, stdout must contain **no** `0x08`. If the tokenizer ever
sees a backspace on stdout, log a loud diagnostic — the meaning of `-bso`/`-bsp` changed and §10
must run before shipping.

### 4.6 What progress actually gives you, and what it does not

- **Integer percent only.** There is no byte-level progress and no ETA (**VERIFIED**). To draw a
  byte-accurate bar, take the total from `l -slt` (sum of `Size`, or `Packed Size` for the read
  side) and interpolate against the percent ticks.
- **Tick density is throughput-based, not fixed.** A 124 MB / 60-file `-mx=9 -md=64m` job produced
  **13** ticks in ~2.7 s. Small jobs produce exactly one (`  0%`). **Never derive "done" from
  seeing `100%`** — completion is the process exiting and being reaped, nothing else.
- The percent is monotonic in practice but must be clamped anyway: `pct = min(100, max(lastPct,
  parsed))`, so a stale half-erased frame can never make the bar jump backwards.

---

## 5. `-slt` listing parser

### 5.1 The document shape

`l -slt` output (**VERIFIED**, 18.05, `.7z`):

```
7-Zip 18.05 : Copyright (c) 1999-2018 Igor Pavlov : 2018-04-30

Scanning the drive for archives:
1 file, 5713 bytes (6 KiB)

Listing archive: out.7z

--
Path = out.7z
Type = 7z
Physical Size = 5713
Headers Size = 242
Method = LZMA2:16
Solid = +
Blocks = 1

----------
Path = src
Size = 0
Packed Size = 0
Modified = 2026-08-24 17:01:05
Attributes = D drwxr-xr-x
CRC = 
Encrypted = -
Method = 
Block = 

Path = src/big.bin
Size = 3000000
Packed Size = 5471
Modified = 2026-08-24 17:01:05
Attributes = A -rw-r--r--
CRC = 8E29F6F7
Encrypted = -
Method = LZMA2:16
Block = 0
```

1. Banner and preamble.
2. A line of exactly `--` introducing the **archive-level** property block.
3. A line of exactly **ten hyphens** `----------` separating archive properties from the item list.
4. Items: runs of `Key = Value` lines, **separated by a blank line**.
5. Trailing blank line at EOF.

### 5.2 The state machine

Implemented as a **paragraph** machine rather than a line-position machine, which makes it immune
to preamble variation (banner present or not, `-ba` or not) and therefore to the one behaviour of
`-ba` we could not establish:

```
1. Split the stream into paragraphs: runs of non-blank lines separated by one or more blank lines.
2. Strip a leading "----------" line from any paragraph that starts with one.
3. Discard every paragraph that contains no " = " and no " =" line
   (banner, "Scanning the drive for archives:", "1 file, 5713 bytes (6 KiB)",
    "Listing archive: out.7z").
4. The paragraph whose FIRST line is exactly "--"  ->  the archive-level dictionary.
5. Every remaining paragraph -> ONE item dictionary, in order.
```

Post-conditions asserted by the parser:

- The archive dictionary, when present, contains `Type`.
- Every item dictionary contains `Path`.
- Item order is preserved and is the archive's internal index order — it is the index space used by
  every later operation, so it must never be sorted in place.

### 5.3 The `Name = Value` grammar

```
1. Find the FIRST occurrence of " = " (space, equals, space).
      key   = everything before it
      value = everything after it, VERBATIM  (no trimming)
2. If there is no " = " but the line ends with " =" or "=", then
      key = the prefix, value = ""      (empty value, see §5.4)
3. Otherwise the line is a CONTINUATION of the previous value:
      append "\n" + line to the previous key's value
      AND set the item's `suspicious` flag   (see §5.6)
```

- **Split on the first ` = ` only.** Values legitimately contain `=`: `Method = LZMA2:16`,
  `Method = LZMA2:12 7zAES:19`.
- **Values legitimately contain ` = ` too** — a `Comment` value may be `a = b`. First-match split
  handles it; a *key* never contains ` = `.
- Keys contain spaces: `Packed Size`, `Physical Size`, `Headers Size`, `Volume Index`.
- **Do not trim the value.** `Attributes = ` + `" -rw-r--r--"` for a ZIP entry has a *leading
  space* where the Windows attribute letters would be, and that space is meaningful (§5.5).

### 5.4 Empty values are present, not absent

`CRC = `, `Method = `, `Block = `, `Comment = ` all occur (**VERIFIED** — a `.7z` directory entry
emits an empty `CRC`, `Method` and `Block`). **Empty ≠ absent**, and the distinction matters: an
empty `CRC` means "this format/entry has no CRC", while an absent `CRC` key means "this format does
not report CRCs at all".

Model as `[String: String]`:

```swift
dict["CRC"] == nil        // key absent  -> format does not report it
dict["CRC"] == ""         // key present, no value -> entry has none
dict["CRC"] == "8E29F6F7" // value
```

Never collapse `""` to `nil`. Never use a positional struct — see §5.5.

### 5.5 Which keys appear per format

**Key sets are format-dependent.** This is not a corner case; it differs between the two most
common formats. **Build a dictionary keyed by field name, never a positional struct.**

Archive-level keys, `.7z` (**VERIFIED**): `Path`, `Type`, `Physical Size`, `Headers Size`,
`Method`, `Solid`, `Blocks`. Other formats add or omit keys (`Comment`, `Volumes`, `Total Physical
Size`, `Offset`, `Warning`, `Code Page`, `Characteristics` are all seen in the wild) — the archive
block is a dictionary too, and unknown keys are retained for the Properties dialog rather than
discarded.

Item keys, **`.7z`** (**VERIFIED**): `Path`, `Size`, `Packed Size`, `Modified`, `Attributes`,
`CRC`, `Encrypted`, `Method`, `Block`.

Item keys, **`.zip`** (**VERIFIED**): `Path`, `Folder`, `Size`, `Packed Size`, `Modified`,
`Created`, `Accessed`, `Attributes`, `Encrypted`, `Comment`, `CRC`, `Method`. Verified subset, not
exhaustive.

So `.zip` emits `Folder`, `Created`, `Accessed` and `Comment` that `.7z` does not. `.7z` emits
`Block` that `.zip` does not. **No other format's key set has been captured**; the parser must be
key-driven so an unseen set is harmless, and every key it does not model is preserved verbatim for
the Properties dialog and the column model.

Derived fields — the rules, in order:

| Field | Rule |
|---|---|
| **isDirectory** | `Folder == "+"` if the key is present; **otherwise** the `Attributes` value's Windows-attribute part contains `D`, or its POSIX part begins with `d`. Never assume `Folder` exists. |
| **Attributes** | Value is `<winAttrLetters><space><posixMode>`; either part may be empty. `"D drwxr-xr-x"`, `"A -rw-r--r--"`, `" -rw-r--r--"` (empty win part, note the leading space) are all valid. Split at the **first** space; the left part is a letter set (`D R H S A …`), the right part is a 10-character mode string when present. A Windows-authored ZIP may have no POSIX part at all. |
| **Encrypted** | `"+"` = encrypted, `"-"` = not. See §6.4. |
| **CRC** | Uppercase hex CRC32 when non-empty. Free — no extraction. Feeds the archive-diff feature. |
| **Modified / Created / Accessed** | `YYYY-MM-DD HH:MM:SS`, **local time, no timezone, one-second granularity**. Parse with the local calendar and tag the result `zone: .localUnspecified`. Never compare across a DST boundary without accounting for it. 26.x is documented to add UTC timestamp output; identify the exact switch from `7zz` help at M0 and prefer it (Appendix B). |
| **Method** | Space-separated codec chain, e.g. `LZMA2:16`, `LZMA2:12 7zAES:19`. The presence of `7zAES` corroborates `Encrypted = +`. |

### 5.6 Filenames containing newlines

**A filename containing a newline corrupts this format.** It is rare but constructible, and it is a
genuine attack surface for a GUI that then acts on parsed paths. Three layered defences:

1. **Structural detection, zero cost.** Rule 3 of §5.3: any non-blank line inside an item paragraph
   that is not a `Key = Value` line is a continuation, i.e. an embedded newline. Append it to the
   previous value and set `item.suspicious = true`. This catches the common case immediately.
2. **Count cross-check.** Compare the `-slt` item count against the `N files, M folders` summary
   from plain `l` (§3.1). A name containing a *blank line* splits one item into two paragraphs and
   evades defence 1; the count catches it. Run the cross-check on archive open by default; it may
   be deferred to an explicit *Verify listing* action for archives above a configurable entry
   count, because it costs a second header scan.
3. **Refuse to round-trip.** A path with a control character is displayed escaped in the UI, is
   never written into a list file (§2.4), and is passed on argv after `--` only for single-entry
   operations. Any operation over a `suspicious` item requires explicit confirmation.

**Residual risk, documented deliberately:** a name of the form `a\nb = c` produces a syntactically
valid bogus key inside the item and evades defence 1. Defence 2 catches it. This is inherent to a
line-oriented text protocol and is one of the reasons the M5 in-process engine exists — `IInArchive
::GetProperty` returns a `BSTR`, not a line of text.

### 5.7 Cost

`l -slt` re-opens and re-scans the archive on **every** call. Cache the parsed listing per
(archive path, size, mtime, inode) and invalidate on any write we perform. This matters most for
solid `.7z` and for the browsing UI; it is the specific pain that the M5 random-access engine
removes.

---

## 6. Passwords — the creation asymmetry

> **SECURITY FINDING.** A password **can** be piped on stdin for `x`, `e`, `l`, `t`. It **cannot**
> for `a` / `u`. Piping a password to `a` produces an **UNENCRYPTED archive, exit 0, no warning**.
> Encryption on creation requires `-p<password>` on the command line, where it is visible in
> `ps(1)` to any process running as the same user.

### 6.1 Extract / list / test — stdin, and nothing on argv

**VERIFIED:**

```sh
printf '%s\n' 'S3cret!' | 7zz x -o/dest -bso1 -bsp2 -y archive.7z
Enter password:
Everything is Ok
0
```

Omit `-p` entirely. 7-Zip prints `Enter password:` on stdout and reads **one line** from stdin.
The secret never reaches the process table. `-y` and a piped password coexist — `-y` answers
yes/no *queries*, and a password prompt is not one (**VERIFIED** in the reference command set;
re-confirm at M0).

Engine rules:

- Write `password + "\n"` to the child's stdin, then **close** stdin immediately (§2.5).
- Hold the password in a `SecureBytes` buffer that is `memset_s`-zeroed on release; never in a
  `String` (Swift strings are immutable, copy freely, and cannot be reliably zeroed).
- Never log it, never include it in the argv echoed into the operation log, never let it reach a
  crash report.

### 6.2 Creation — the silent trap

**VERIFIED, and this is the trap:**

```sh
# WRONG — produces an UNENCRYPTED archive, exit 0, no warning whatsoever
printf 'MyPass123\n' | 7zz a -mhe=on out.7z src/small.txt
Everything is Ok
0

7zz l -slt -ba out.7z
Path = src/small.txt
Encrypted = -                 # <-- NOT ENCRYPTED
Method = LZMA2:12
```

7-Zip only encrypts when `-p` is present on the command line. Without it there is no prompt, the
piped stdin bytes are discarded, and the user receives a plaintext archive they believe is
protected. A GUI that does this ships a data breach.

### 6.3 The exposure, and the mitigation

**VERIFIED:**

```
$ ps -o args= -p <pid>
… 7zz a -pVISIBLE_SECRET -mx=9 -md=64m psprobe.7z big/src
```

There is no `--password-file`, and `-p` has no `@file` form. On macOS, argv is readable via `ps` by
the **same UID** (and root). The exposure is to other processes running as the user — moderate, not
catastrophic, but real and **unfixable within the subprocess architecture**.

Mitigations that are required now:

1. **A code comment at the call site**, verbatim in `SevenZipCLIEngine`, recording that `-p` on
   argv is deliberate and that "fixing" it to stdin silently disables encryption for every user.
   This is the single highest-value comment in the codebase.
2. **Minimise the window.** The encrypting `a`/`u` process is spawned with the password already
   assembled; nothing else runs between spawn and the operation. We cannot shorten the lifetime
   below the process lifetime — that is the point of the finding.
3. **Tell the truth in the UI.** The Add dialog's encryption group shows a short, non-alarmist note
   for encrypted creation: that the password is passed to the bundled 7-Zip command-line tool and
   is briefly visible to other programs running under your account while the archive is being
   created. Users on shared or managed machines deserve to know.
4. **Never reuse a login-keychain password directly.** Keychain/Touch ID storage (an M-later
   feature) is keyed on an archive content fingerprint and yields a one-shot value.
5. **This is the strongest single argument for the M5 in-process engine.** `ICryptoGetTextPassword`
   passes the password in memory and closes the leak. When M5 lands, the **creation** path moves
   in-process *first*, even if browsing does not.

### 6.4 Detecting encryption before prompting

Never discover an encryption requirement mid-run. Pre-flight with `l -slt` (**VERIFIED**):

| Case | Symptom | Handling |
|---|---|---|
| **Body-encrypted** (`-p` without `-mhe=on`) | `l -slt` succeeds **without** a password; items show `Encrypted = +` and `Method = LZMA2:12 7zAES:19` | Prompt before starting the extract/test. |
| **Header-encrypted** (`-p` with `-mhe=on`) | `l` cannot read the listing at all; prompts, and with closed stdin exits **255** with `Break signaled` | 255-with-no-signal on a bare `l` ⇒ header-encrypted. Prompt, then re-run `l -slt` with the password on stdin. |
| **Wrong password** | exit **2**, `ERROR: Can not open encrypted archive. Wrong password?`, `ERRORS: Headers Error` | Re-prompt (bounded retries), do not report a generic failure. |
| **Empty password** (`-p` with no value) | harmless on non-encrypted archives, exit **0** | Never send an empty `-p` on creation; treat an empty password field as "no encryption". |

Because encryption state is known from the *listing*, wrong-password classification never depends
on matching English error text: any exit 2 on an archive we know is encrypted offers a re-prompt.
The message match is a refinement, not the mechanism (§7.4).

### 6.5 Mandatory post-creation verification

**Every encrypted-creation operation is followed by a verification step, and it is not optional.**

After a successful `a`/`u` with `-p`, before reporting success to the user:

1. Run `7zz l -slt` on the new archive.
   - If headers are encrypted (`-mhe=on`), the listing must **require** a password — the
     no-password `l` must fail (exit 255 with `Break signaled`, or exit 2). If it succeeds and
     reveals entry names, header encryption did **not** apply.
   - If headers are not encrypted, the listing succeeds and **every non-directory item must have
     `Encrypted = +`**, with `7zAES` present in its `Method` chain.
2. Any item with `Encrypted = -` when encryption was requested ⇒ treat the operation as
   **failed**: surface *The archive was created but is NOT encrypted*, offer to delete it, and file
   an internal diagnostic with the exact argv (password redacted). Never leave a
   believed-encrypted, actually-plaintext archive on the user's disk without saying so.
3. The verification is a golden-path test in `Tests/ArchiveCoreTests`, run for both `-mhe=on` and
   `-mhe=off`, for `.7z` and `.zip` — the only two creatable formats with `kFF_Encrypt`.

This check costs one header scan and is the only thing standing between a future refactor and a
silent breach.

---

## 7. Exit codes and the app error model

### 7.1 The codes

| Code | 7-Zip meaning | Evidence | App outcome |
|---|---|---|---|
| **0** | No error | **VERIFIED** | `.success` |
| **1** | **Warning — non-fatal. The operation SUCCEEDED.** | **VERIFIED**: `a w.7z does_not_exist.txt` → `Scan WARNINGS: 1`, **and the archive was still created** | `.successWithWarnings([Warning])` |
| **2** | Fatal error | **VERIFIED**: wrong password; missing archive; `t` on a corrupted archive | `.failure(.fatal(...))` |
| **7** | Command-line error | **VERIFIED**: `7zz a -zzz bad.7z f` → `Command Line Error: Unknown switch: -zzz` | `.failure(.internalDefect(...))` — **our bug**, never the user's |
| **8** | Not enough memory | **(doc)** — not reproduced; reachable with a large `-md` on a constrained machine | `.failure(.outOfMemory(requested:))` |
| **255** | User break — **or** a prompt that hit closed stdin | **VERIFIED** both ways | `.cancelled` **or** `.protocolViolation` — see §7.3 |

### 7.2 Exit 1 is success

> **A GUI that reports failure on exit 1 will annoy users constantly.** A single unreadable file in
> a large selection produces exit 1 while still creating a perfectly good archive.

`.successWithWarnings` renders as a completed operation with a warnings disclosure. The warning
detail comes from the `Scan WARNINGS` block on stdout (**VERIFIED**):

```
Scan WARNINGS for files and folders:

no_such_file.txt : No such file or directory
----------------
Scan WARNINGS: 1
```

Parse it as: header line, blank, then `path : reason` lines until a run of hyphens, then
`Scan WARNINGS: N`. Assert the parsed count equals `N`; on mismatch keep the raw block and show it
verbatim. The `----------------` terminator here is **sixteen** hyphens and is *not* the `-slt`
ten-hyphen separator — do not share a constant between the two parsers.

### 7.3 Exit 255 is overloaded, and this will bite you

255 means both "the user cancelled" **and** "7-Zip needed input and stdin was closed"
(**VERIFIED** both ways):

```sh
7zz l enc.7z < /dev/null ; echo $?          # header-encrypted, no -p
Enter password:
Break signaled
255

7zz x -oexo out.7z < /dev/null ; echo $?    # files exist, no -y
? (Y)es / (N)o / (A)lways / (S)kip all / A(u)to rename all / (Q)uit?
Break signaled
255
```

**Disambiguation is structural, not textual.** The engine records `didSignal: Bool`, set when *we*
send the cancel signal (§8):

```swift
switch (status, didSignal) {
case (255, true):  return .cancelled
case (255, false): return .protocolViolation(lastPrompt: tail(stderrLog, stdoutLog))
default: ...
}
```

`.protocolViolation` is **an internal defect, not a user-facing failure**: it means our argv was
missing `-y`, or we failed to resolve a password before spawning. It logs the full argv (password
redacted), the last 4 KiB of both streams, and the detected prompt text, and it is a hard failure
in CI. Passing `-y` on every operation and pre-flighting the password question (§6.4) is what makes
255 unambiguous.

### 7.4 Death by signal is not an exit code

`Process.terminationReason == .uncaughtSignal` (or `WIFSIGNALED`) must be handled **before** the
exit-code switch. A malformed archive that segfaults the decoder produces a signal death, not exit
2, and must never be confused with a normal failure:

```swift
if reason == .uncaughtSignal {
    return .failure(.engineCrashed(signal: Int32(status)))
}
```

- `SIGSEGV` / `SIGBUS` / `SIGABRT` ⇒ a decoder crash on hostile input. This is precisely the case
  the subprocess architecture exists to contain: the child dies, the app shows an error, no user
  work is lost. Report it with the archive's format and size (never its contents).
- **`SIGTRAP` (shell exit 133) is the code-signing canary.** A hardened binary that fails library
  validation or is run outside the bundle it was pinned to dies exactly this way — it is what
  Keka's `keka7zz` does when run standalone. A `SIGTRAP` from our helper means the signing step
  broke, the bundle was tampered with, or the Team ID does not match. Surface it as *Engine
  unavailable* and point at §1.3, never as an archive error.

### 7.5 Message patterns → typed errors

The exit code is authoritative. Message text is **diagnostic**, English-only, unlocalised, and may
be reworded between versions — it refines an error, it never decides one.

| Pattern (case-insensitive substring) | Stream | Typed error | Evidence |
|---|---|---|---|
| `Can not open encrypted archive. Wrong password?` | stdout/stderr | `.wrongPassword` | **VERIFIED** |
| `ERRORS: Headers Error` | stdout | corroborates `.wrongPassword` / `.headerError` | **VERIFIED** |
| `ERROR: Data Error : <path>` + `Sub items Errors: N` | stdout | `.dataError(entries:)` | **VERIFIED** |
| `Command Line Error: Unknown switch: <sw>` | stdout | `.internalDefect(.badSwitch)` | **VERIFIED** |
| `System ERROR: Unknown error: -2147024894` | stdout | `.archiveNotFound` | **VERIFIED** |
| `WARNING: <reason>` + `Scan WARNINGS: N` | both | `.scanWarnings([...])` | **VERIFIED** |
| `Break signaled` | stdout | corroborates 255 | **VERIFIED** |
| `Enter password:` | stdout | password required | **VERIFIED** |
| `? (Y)es / (N)o / (A)lways / …` | stdout | **must never appear** — `-y` is missing ⇒ `.protocolViolation` | **VERIFIED** |
| `Everything is Ok` | stdout | success sentinel, **corroborating only** | **VERIFIED** |

**HRESULTs leak into messages.** `-2147024894` is `0x80070002` — a Windows `HRESULT` wrapping
Win32 `ERROR_FILE_NOT_FOUND` (2). For diagnostics, any `System ERROR: Unknown error: -<n>` is
converted to `0x` hex; if the top bits are `0x8007`, the low 16 bits are a Win32 error code. Show
the decoded form in the log, never in the user-facing message.

### 7.6 The outcome type

```swift
enum EngineOutcome: Sendable {
    case success
    case successWithWarnings([EngineWarning])       // exit 1 — SUCCEEDED
    case failure(EngineError)                       // exit 2, 8, signal death
    case cancelled                                  // exit 255, we signalled
    case protocolViolation(ProtocolViolation)       // exit 255, we did NOT signal — our bug
}

enum EngineError: Sendable {
    case wrongPassword
    case headerError
    case dataError(entries: [String])
    case archiveNotFound
    case unsupportedFormat
    case outOfMemory(requestedBytes: UInt64?)
    case engineCrashed(signal: Int32)
    case engineUnavailable(reason: String)          // signature / SIGTRAP / missing helper
    case internalDefect(InternalDefect)             // exit 7, bad argv
    case fatal(code: Int32, detail: String)
}
```

Every case maps to a distinct, actionable presentation. `.internalDefect` and
`.protocolViolation` are never phrased as the user's fault, and both carry a "copy diagnostics"
affordance.

Exit **8** deserves a real response rather than a generic error: recompute the memory requirement
from the chosen dictionary size, thread count and `physicalMemory`, and offer the reduced settings
directly in the alert. 7zFM's memory-usage-request dialog exists for exactly this; the
`-mmemuse=` property **(doc)** is the lever if M0 confirms it.

---

## 8. Cancellation

Cancellation is the subprocess architecture's best feature, and it is better than expected.

### 8.1 What a signal does

**VERIFIED:**

```sh
7zz a -bsp1 -mx=9 -md=256m -mmt=1 cancel.7z big/src &  ;  kill -INT $!
# EXIT=255, output ends "Break signaled"
ls cancel*            # -> no matches: the partial archive was REMOVED
```

- **SIGINT → exit 255, partial output deleted.** **VERIFIED.**
- **SIGTERM → exit 255, partial output deleted.** **VERIFIED.**
- Mid-run the target file exists (68,478 bytes at t≈0.5 s) and is gone after the signal. 7-Zip
  installs a handler that unwinds and cleans up; it does not die mid-write leaving a corrupt
  archive.

### 8.2 Signal the process group, and put the child in its own group at spawn

**The child must be the leader of its own process group.** Two reasons, both load-bearing:

1. **Correctness of the target.** `kill(-pgid, …)` reaches the child *and any process it spawned*.
   Today `7zz` uses threads (`-mmt`), not helper processes, so the practical difference is small —
   but "small today" is not a contract, and a helper that outlives its parent holds the output file
   open and defeats the cleanup.
2. **Safety of the signal.** If the child stayed in **our** process group, a group signal would hit
   the app itself — `kill(0, SIGINT)` would kill ArcSeven. Isolating the child makes the group form
   safe to use, and the group form is the only form that is complete.

Spawn with `posix_spawn(3)` directly (Foundation's `Process` exposes no way to set the process
group):

```c
posix_spawnattr_t attr;
posix_spawnattr_init(&attr);
posix_spawnattr_setflags(&attr,
        POSIX_SPAWN_SETPGROUP |          // put the child in a new process group
        POSIX_SPAWN_CLOEXEC_DEFAULT);    // inherit nothing but fds 0,1,2
posix_spawnattr_setpgroup(&attr, 0);     // 0 => new group, pgid == child pid
```

`pgid == childPid`. Cancel is then:

```
kill(-pgid, SIGINT)
  wait up to 5 s for exit
kill(-pgid, SIGTERM)
  wait up to 5 s for exit
kill(-pgid, SIGKILL)          // last resort
```

**SIGKILL forfeits 7-Zip's cleanup.** After a SIGKILL the app must delete the partial output file
itself (for `a`) or the staging directory (for `x`/`e`) — it can, because it knows the exact
output path. Reaching SIGKILL is logged as an anomaly.

### 8.3 Drain, then reap — never kill and walk away

After signalling:

1. Keep reading **both** pipes until EOF. Do not close the read ends early.
2. `waitpid(childPid, &status, 0)` and record `didSignal = true` (§7.3).
3. Only then tear down the tokenizers, delete the list file and the scratch directory, and report.

Skipping the drain leaks file descriptors and fires readability handlers against a dead process. On
app termination (`applicationWillTerminate`, and on `NSApplication` sudden-termination paths) every
live pgid is signalled and reaped; macOS has no `PDEATHSIG`, so orphan prevention is entirely our
responsibility.

### 8.4 What survives a cancel, per command

| Command | On cancel |
|---|---|
| `a` (create) | **7-Zip deletes the partial archive itself.** **VERIFIED.** Nothing to clean up. |
| `u`, `d` (update/delete) | 7-Zip writes a temp file and renames, so **the original archive survives intact**. **VERIFIED** as the documented update path. Delete any leftover temp in our scratch dir. |
| `x`, `e` (extract) | **Already-extracted files REMAIN on disk.** 7-Zip does not roll them back. **We must.** |
| `t` (test) | Nothing written. |
| `b`, `h` | Nothing written. |

### 8.5 Extraction cleanup — staging, with the log as manifest

Default policy: extract into a per-operation **staging directory on the destination's volume**
(`<destDir>/.ArcSeven-staging-<uuid>`, or the operation's `TMPDIR` when it is on the same volume), then
`rename(2)` entries into place on success. Same-volume rename is cheap and atomic per entry.
Benefits:

- Cancel is `rm -rf <staging>`; the user's destination is never left half-populated.
- The *Ask before overwrite* partitioning (§3.10) becomes a set of moves rather than extra
  extraction passes — which matters enormously for solid `.7z`, where every pass re-decodes the
  whole block.

Direct-to-destination extraction remains available (a setting, and the automatic choice when the
destination volume lacks room for staging). In that mode the cleanup manifest is the permanent
`- <path>` lines already captured from stdout (§4.5): the app knows exactly which paths it created
and removes precisely those, newly-created directories included, and nothing else. **Never `rm -rf`
a user-chosen destination directory.**

### 8.6 Cancellation is not the same as failure

`.cancelled` is a terminal, non-error outcome: no alert, no red badge, the queue item shows
"Cancelled" and stays in history. The operation queue may reissue it later — which is why the
staging directory and the list file are named per-operation and never reused.

---

## 9. Format capability gating

### 9.1 Exactly seven formats can be created

Empirically determined by running `a -t<fmt>` across 32 candidate types and round-tripping each
success through `t` and `x -so` (**VERIFIED**, 18.05):

| Format | Create | Extract | Test |
|---|---|---|---|
| `7z` | ✅ | ✅ | ✅ |
| `zip` | ✅ | ✅ | ✅ |
| `gzip` | ✅ | ✅ | ✅ |
| `bzip2` | ✅ | ✅ | ✅ |
| `xz` | ✅ | ✅ | ✅ |
| `tar` | ✅ | ✅ | ✅ |
| `wim` | ✅ | ✅ | ✅ |

Everything else **rejected creation**: `lzma`, `lzma86`, `swfc`, `rar`, `rar5`, `iso`, `cab`,
`dmg`, `hfs`, `squashfs`, `udf`, `arj`, `lzh`, `cpio`, `rpm`, `deb`, `ar`, `z`, `chm`, `nsis`,
`vhd`, `vmdk`, `xar`, `apm`, `ext`, `fat`, `ntfs`.

### 9.2 How the Add dialog must be gated

The *Archive format* dropdown is populated from a static `FormatCatalog` of those seven, sorted by
handler name (7zFM's combo has `CBS_SORT`), **filtered** by the same rules 7zFM applies
(`res_8` §1.3):

| Gate | Rule | Affects |
|---|---|---|
| **`UpdateEnabled`** | The handler must have an out-handler. | The seven above; nothing else is ever listed. |
| **`kKeepName` / single-stream** | Offered **only when the selection is exactly one existing file** (not a directory). | `gzip`, `bzip2`, `xz` |
| **`kFF_Encrypt`** | The whole encryption group (both password fields, Show Password, encryption-method combo, *Encrypt file names*) is **enabled only for `7z` and `zip`**; greyed for `gzip`, `bzip2`, `xz`, `tar`, `wim`. | password UI |
| **`kFF_MultiThread`** | The *Number of CPU threads* combo is populated only for `7z`, `zip`, `bzip2`, `xz`; empty/disabled for `gzip`, `tar`, `wim`. | threads UI |
| **NTFS/metadata group** | Each checkbox is hidden when the handler does not advertise the flag: `7z` = symlinks + hard links + security; `wim` = alt streams + security + symlinks + hard links; `tar` = symlinks + hard links; `zip`/`gzip`/`bzip2`/`xz` = none. | metadata UI |
| **Level 0 (Store)** | For any handler except `tar` and the hash handler, `Store` clears and disables the Method, Dictionary and Word-size combos. | method UI |

**Compound `.tar.*` targets** (`.tar.gz`, `.tar.xz`, `.tar.bz2`) are offered as first-class entries
and implemented as two passes — `a -ttar` into the operation's scratch directory, then
`a -tgzip|-txz|-tbzip2` over the result — with a single merged progress model (pass 1 and pass 2
weighted by expected bytes) and one cancel that covers both. Only pass 2's output is moved into
place; a cancel in either pass leaves nothing behind.

**Two 7zFM entries are deliberately out of scope for v1**, both flagged in Appendix B: `swfc`
(offered only for a single `*.swf`; `a -tswfc` was **rejected** with generic input on 18.05, so its
creatability is input-conditional and unestablished) and the `Hash` handler (offered only when
pre-selected via the shell "CRC SHA" verb; it writes `.sha256`-style checksum files). Neither may
appear in the format list until a golden-file test proves the CLI can create it.

**Never expose a "create RAR" affordance anywhere.** RAR is extract/test only — 7zFM cannot create
RAR either, and the unRAR restriction forbids building a RAR-compatible archiver.

### 9.3 The extract/test set is much larger

`t` works on **any readable format** — it is extraction to `/dev/null` with CRC verification. The
registered handlers on the verified build were:

`APM, Ar/a/deb/lib, Arj, Cab, Chm/chi/chq/chw, Compound (msi/msp/doc/xls/ppt), Cpio, CramFS, Dmg,
ELF, Ext/ext2/ext3/ext4, FAT, FLV, GPT/mbr, HFS/hfsx, Hxs/lit, IHex, Iso, Lzh/lha, lzma, lzma86,
MachO, MBR, MsLZ, Mub, Nsis, NTFS, PE/exe/dll/sys, COFF/obj, Ppmd, QCOW/qcow2, Rar, Rar5, Rpm,
Split (.001), SquashFS, SWF, SWFc, TE, Udf, UEFIc/scap, UEFIf, VDI, VHD, VMDK, Xar/pkg/xip, Z`
— plus the seven creatable ones. 26.02 adds further handlers **(doc)**.

Codecs on the verified build: `BZip2, BCJ2, BCJ, PPC, IA64, ARM, ARMT, SPARC, Swap2, Swap4, Copy,
Deflate64, Deflate, Delta, LZMA2, LZMA`; 26.02 adds Zstd decode and ARM64/RISC-V filters **(doc)**.
**Zstd is decode-only** in 24.x–26.x — its handler registers with a null out-creator — so it is
never in the create list.

The full handler/codec/hasher inventory is read from `7zz i` at first run and cached against the
engine version. It drives:

- **Open**: which extensions the app claims it can open (cross-checked against the UTI declarations
  in `Info.plist` — a format we declare but cannot open is a bug, and vice versa).
- **The CRC submenu**: hidden entries for hashers this build does not register (§3.12).
- **A CI assertion**: the bundled binary's handler set must be a superset of the set the UI
  advertises.

### 9.4 The creatable-set self-test

`FormatCatalog`'s seven entries are hardcoded (they are stable, and probing at launch would be
absurd), but CI probes them for real: for each of the 32 candidate `-t` values, attempt a
one-file `a` into a temp path and record success/failure. **CI fails if the resulting set differs
from the seven.** This is the mechanism that turns "we believe seven" into "we know seven for the
binary we are actually shipping".

---

## 10. Versioning and compatibility

> **The parser test suite MUST be re-run against the exact bundled `7zz` on every version bump.**

The subprocess contract is a **human-facing UI** that nobody promised us: backspace erasure, an
undocumented `-ba`, format-dependent `-slt` key sets, message text that is not localised and not
stable. It works, and it can shift between releases. `-bb` verbosity shapes in particular **have
changed historically** — on 18.05, `-bb1`/`-bb2`/`-bb3` produced identical per-file output, while
26.x is documented to add detail at higher levels.

**Everything marked VERIFIED in this document was verified against 7-Zip 18.05** (the universal
binary inside Parallels Desktop) and **MUST be re-verified against the bundled 26.02** before the
first release, and again on every bump thereafter.

### 10.1 The gate

Version bumps go through `Scripts/verify-engine.sh`, which is a **release blocker**, not a
courtesy. It must:

1. Record the new binary's `7zz` version banner, `lipo -info`, and SHA-256 into
   `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt`.
2. Rebuild the golden corpus from `Tests/Fixtures` (a compressible file, a 60-file multi-megabyte
   set, UTF-8 names including `café_日本.txt` and a non-BMP emoji name, nested directories, a
   symlink, a hard link, a zero-byte file, a name with a leading `-`, a name with a trailing space,
   a body-encrypted archive, a header-encrypted archive, a deliberately corrupted archive, a
   two-volume set, and a `.tar.gz`).
3. Re-run every row of Appendix B and diff against the recorded expectations.
4. Re-run the `-slt` golden-file parser tests for `.7z`, `.zip`, `.tar`, `.gz`, `.xz`, `.wim`,
   `.rar`, `.iso`, `.dmg`.
5. Re-run the tokenizer tests against **captured raw byte streams**, not re-generated ones — the
   fixtures include the exact backspace-laden bytes from a real run, replayed through the tokenizer
   at every chunk size from 1 to 8192 bytes (§10.2).
6. Re-run the creatable-format probe (§9.4) and the hasher enumeration (§3.12).
7. Re-run the encrypted-creation verification (§6.5).

### 10.2 Tokenizer fuzzing is part of the suite

The stream reader is the highest-risk code in the project, so its tests are adversarial by
construction:

- Replay each captured stream at **every chunk size from 1 to 8192**, asserting the emitted
  `.line` sequence is byte-identical across all of them and that the final `.transient` is the
  expected token. A tokenizer that is correct at 4096 and wrong at 1 is a tokenizer that will fail
  on a slow network volume.
- Randomised chunking (property test, fixed seed) over the same streams.
- Adversarial inputs: a lone `\b` at offset 0; more backspaces than the line is long; a 1 MiB line
  with no newline (must hit the cap and emit `.overflow`); a UTF-8 sequence split across every
  possible boundary; an ANSI CSI sequence; a lone `\r`.

### 10.3 Canaries — the four things that mean "stop and re-read §4"

Ship these as runtime diagnostics, not just tests. Any of them firing in the field means the
contract moved:

1. A `0x08` byte appears on **stdout** under the standard block.
2. A `0x0D` byte appears on **either** stream.
3. `l -slt` yields an item paragraph with **no `Path` key**.
4. Exit **255** with `didSignal == false` (`.protocolViolation`).

Each is counted and surfaced in the diagnostics pane; none of them is ever silently swallowed.

### 10.4 What is allowed to change without a code change

The parser is deliberately tolerant in exactly the places that historically move, so that a version
bump degrades rather than breaks:

- **New `-slt` keys** — retained verbatim and shown in Properties; never a parse error.
- **New operation characters** in the progress/log grammars — captured as `unknownOp`, path still
  recorded.
- **Reworded messages** — the exit code decides; text only refines (§7.5).
- **New handlers, codecs, hashers** — discovered from `7zz i`, not hardcoded.
- **New creatable formats** — CI's probe (§9.4) reports the delta; adding one is a deliberate,
  reviewed change to `FormatCatalog`, never automatic.

What is **not** allowed to change silently: the backspace encoding, the ten-hyphen separator, the
` = ` grammar, the exit-code meanings, and the `-y` requirement. Those are the load-bearing
assumptions, and §10.3 watches all five.

---

## Appendix A — argv quick reference

`STD` = `-bb3 -bso1 -bsp2 -bse2 -ba -y -sccUTF-8 -scsUTF-8`
`LIST` = `-bso1 -bse2 -bsp0 -y -sccUTF-8` (no `-ba`, no `-bb3`, progress off)

```sh
# List, machine-readable (the one the app parses)
7zz l -slt LIST -- /abs/archive.7z

# List, plain — count cross-check only
7zz l LIST -- /abs/archive.7z

# Extract with paths
7zz x STD -o/abs/dest -aoa -- /abs/archive.7z @/abs/sel.txt

# Extract flat (LOSSY — pre-flight basename collisions)
7zz e STD -o/abs/dest -aoa -- /abs/archive.7z @/abs/sel.txt

# Extract with the password on STDIN (keeps it out of `ps`)
printf '%s\n' "$PW" | 7zz x STD -o/abs/dest -- /abs/archive.7z

# Test integrity
7zz t STD -- /abs/archive.7z

# Create (cwd = base dir; list file holds relative paths)
7zz a STD -t7z -mx=9 -md=64m -ms=on -mmt=8 -- /abs/out.7z @/abs/sel.txt

# Create encrypted, encrypted headers — -p MUST be on argv (visible in ps; see §6)
7zz a STD -t7z -mx=9 -mhe=on -p"$PW" -- /abs/out.7z @/abs/sel.txt
#   ... then ALWAYS run the §6.5 verification before reporting success

# Update
7zz u STD -- /abs/archive.7z @/abs/sel.txt

# Delete entries (list file holds ARCHIVE-INTERNAL paths)
7zz d STD -- /abs/archive.7z @/abs/entries.txt

# Rename (pairs on argv, never a list file)
7zz rn STD -- /abs/archive.7z "old/path.txt" "new/path.txt"

# Benchmark (dictionary spelling unverified — see Appendix B)
7zz b 10 -bso1 -bse2 -bsp0 -y -mmt=8 -md=64m

# Hash
7zz h -scrcSHA256 -bso1 -bse2 -bsp2 -y -sccUTF-8 -scsUTF-8 -- @/abs/sel.txt

# Stream one member to stdout (Quick Look / preview)
7zz x -so -bso0 -bse2 -bsp0 -y -- /abs/archive.7z "path/inside/archive.txt"

# Peek inside a .tar.gz without a temp file
7zz x -so -bso0 -bse2 -bsp0 -y -- /abs/bundle.tar.gz | 7zz l -ba -si -ttar LIST

# Capability inventory (handlers, codecs, hashers)
7zz i
```

**Cancel:** `SIGINT` (then `SIGTERM`, then `SIGKILL`) to the child's **process group** → exit 255,
partial archive auto-removed for `a`.

**Exit codes:** `0` ok · `1` warning (**still succeeded**) · `2` fatal · `7` bad command line ·
`8` out of memory · `255` cancelled *or* a prompt hit closed stdin.

---

## Appendix B — the M0 verification matrix

Every row must be executed against the **bundled 26.02 `7zz`** and its result recorded in
`THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` alongside the binary's digest, before Phase 1 begins.
Rows marked ⛔ block the feature named in the last column until they pass.

| # | Claim | Status from res_3 | How to verify | Blocks |
|---|---|---|---|---|
| 1 | `7zz` is a universal Mach-O | inferred | `lipo -info 7zz` → `x86_64 arm64` | ⛔ build |
| 2 | Progress is backspace-erased, not `\r` | VERIFIED 18.05 | `7zz x -bsp1 -bb3 … > f 2>&1; cat -v f` → `^H` runs, no `^M` | ⛔ all progress |
| 3 | Progress fires with no TTY | VERIFIED 18.05 | same capture, redirected to a file | ⛔ all progress |
| 4 | Progress ticks arrive promptly through a **pipe** | inferred (fflush) | long `a`, read stderr via pipe, log arrival timestamps | ⛔ progress UX (pty fallback, §4.4) |
| 5 | Creation transient shape `%3d%% %d %c %s` | VERIFIED 18.05 | capture `a -bsp1` on a 60-file set | ⛔ progress |
| 6 | Extraction transient `<pct>% <n>` + permanent `- path` | VERIFIED 18.05 | capture `x -bsp1 -bb3` | ⛔ progress |
| 7 | Scan-phase transient `  0M Scan ` | VERIFIED 18.05 | capture `a` on a large tree | — |
| 8 | `t` per-entry log operation character | **unknown** | `t -bb3` on a multi-entry archive, inspect stdout | — (grammar degrades) |
| 9 | `-bb1`/`-bb2`/`-bb3` differences on 26.02 | changed historically | run all three on the same job, diff stdout | — |
| 10 | `-ba` suppresses the banner for `x`/`a`/`t` | VERIFIED 18.05 | run with and without, diff | ⛔ line parser |
| 11 | `-ba` effect on `l -slt` preamble | **unknown** | `l -slt` with and without `-ba`, diff | — (parser is tolerant) |
| 12 | Ten-hyphen separator + `--` archive block | VERIFIED 18.05 | `l -slt` on a `.7z` | ⛔ listing |
| 13 | `-slt` key sets for `.tar`, `.gz`, `.xz`, `.wim`, `.rar`, `.iso`, `.dmg` | **uncaptured** | `l -slt` on each fixture, record golden files | ⛔ Properties dialog |
| 14 | Empty values render as `Key = ` (trailing space) | VERIFIED 18.05 | `l -slt` on a directory entry, `cat -A` | ⛔ listing |
| 15 | 26.x UTC-timestamp output switch | (doc) | `7zz --help`; find the exact switch name | ⛔ DST-correct timestamps |
| 16 | Password on **stdin** works for `x`/`l`/`t` **with `-y` present** | VERIFIED (reference set) | `printf '%s\n' pw \| 7zz x STD -o… enc.7z` | ⛔ all encrypted reads |
| 17 | Piping a password to `a` yields an **unencrypted** archive | VERIFIED 18.05 | reproduce §6.2 verbatim, then `l -slt` | ⛔ §6.5 verification |
| 18 | `-p` on argv is visible in `ps` | VERIFIED 18.05 | `ps -o args= -p <pid>` mid-run | ⛔ security note in UI |
| 19 | Header-encrypted `l` with closed stdin → 255 `Break signaled` | VERIFIED 18.05 | `7zz l enc.7z < /dev/null; echo $?` | ⛔ encryption detection |
| 20 | Exit 1 = warning, **archive still created** | VERIFIED 18.05 | `a w.7z missing.txt; echo $?`, then `l` the archive | ⛔ error model |
| 21 | Exit 2 / 7 / 255 reproductions | VERIFIED 18.05 | §7.1 recipes | ⛔ error model |
| 22 | Exit 8 (out of memory) | (doc) | `a -md=<absurd>` on a constrained machine | — |
| 23 | SIGINT/SIGTERM → 255 **and partial archive removed** | VERIFIED 18.05 | §8.1 recipe, then `ls` | ⛔ cancel |
| 24 | Cancel during `u`/`d` leaves the original intact | VERIFIED (documented path) | cancel mid-`u`, verify with `t` | ⛔ cancel |
| 25 | Exactly 7 creatable formats | VERIFIED 18.05 | probe all 32 `-t` values (§9.4) | ⛔ Add dialog |
| 26 | `swfc` creatability with a real `.swf` input | **rejected on 18.05, generic input** | `a -tswfc out.swf in.swf` | ⛔ swfc entry (out of scope v1) |
| 27 | `Hash` handler creatability from the CLI | **untested** | `a -thash -scrcSHA256 out.sha256 file` | ⛔ Hash entry (out of scope v1) |
| 28 | `--` stops switch parsing | (doc) | `7zz l -- ./-weird.7z` | ⛔ leading-hyphen names on argv |
| 29 | `-so` data is unaffected by `-bso0` | inferred | `x -so -bso0` a known member, compare bytes | ⛔ Quick Look |
| 30 | `-si -ttar` reads a tar from stdin | VERIFIED 18.05 | the `.tar.gz` pipeline (§3.14) | ⛔ `.tar.*` browsing |
| 31 | `b` dictionary switch spelling (`-md=64m` vs `-md26`) | **unknown** | run both, compare the reported dictionary | ⛔ Benchmark dialog |
| 32 | `b` output table shape | **unknown** | `7zz b 1`, record a golden file | — (raw log column absorbs it) |
| 33 | `h -scrc<Method>` names + output shape | (doc) | `7zz h -scrc*` on a 1-byte file | ⛔ CRC submenu |
| 34 | `7zz i` lists a `Hashers:` section | **unknown** | `7zz i` | — (probe fallback) |
| 35 | `-w{dir}` sets 7-Zip's working directory | (doc) | `u -w/tmp/x` on a large archive; watch where temp lands | — (`TMPDIR` fallback) |
| 36 | `-mmemuse=` accepted | (doc) | `a -mmemuse=2g …` | — (exit-8 UX) |
| 37 | `u -uq0` = Freshen; `u -up0q3r2x2y2z0w2` = Synchronize | **transcribed, unverified** | golden-file entry-set assertion (§3.7) | ⛔ Freshen / Synchronize modes |
| 38 | `-spf` / `-spf2` path-mode mapping on extract | VERIFIED for `a`; **unverified for `x`** | `x -spf` on an archive with absolute paths | ⛔ Extract "Absolute pathnames" |
| 39 | Helper spawns cleanly from a signed, hardened, **notarized** bundle | not attempted | Phase 0 spike: extract from an external volume to a user-chosen destination | ⛔ everything |
| 40 | Helper does **not** die with SIGTRAP (exit 133) | — | run the bundled helper from inside the signed bundle | ⛔ everything |

---

## Appendix A — Corrections from live verification (7-Zip 26.02)

The body of this document was written from research against 7-Zip **18.05**, with an
explicit instruction to re-verify against the bundled build. That verification has now
been done against the vendored **26.02** universal binary. Where the two disagree,
**this appendix wins**, and the code follows this appendix.

### A.1 Passwords are not delivered the way §6 describes

| Invocation | Result on 26.02 |
| --- | --- |
| `-p` (bare) + passphrase on stdin | **Fails.** Bare `-p` means an *empty* password and suppresses the prompt. Exit 2, "Cannot open encrypted archive. Wrong password?" |
| `-p<pw>` on argv | Works. Visible in `ps`. |
| **No `-y`, no `-p`**, passphrase on stdin | **Works.** `7zz` prints `Enter password:` and reads stdin. No TTY needed — verified with the child in its own session via `setsid`. |
| `a` (create), no `-p`, passphrase on stdin | **Silently produces an UNENCRYPTED archive, exit 0.** There is no prompt on the creation path. |

**Consequences, implemented in `SevenZipCLIEngine.PasswordDelivery`:**

1. Read operations (`l`, `t`, `x`, `e`, `d`, `rn`, `h`) carrying a password omit both
   `-y` and `-p`, and write `<passphrase>\n` to stdin. The passphrase never reaches argv.
2. Because `-y` is absent on that path, every such invocation must pass an explicit
   `-ao*` overwrite mode so no other prompt can block the child.
3. Creation must use `-p<pw>` on argv, and the result **must** be verified with
   `verifyEncryption(of:password:)`.

### A.2 `-mem=` is ZIP-only

`-mem=` sets the ZIP cipher. The `.7z` handler rejects it outright:

```
$ 7zz a -t7z -pX -mem=aes256 out.7z in.txt
System ERROR: E_INVALIDARG : One or more arguments are invalid
```

`.7z` supports AES-256 and nothing else, so the cipher is implicit. Emit `-mem=` only
for `.zip`. Header encryption (`-mhe=on`) remains `.7z`-only.

### A.3 The version banner is preceded by a blank line

`7zz i` and `7zz` with no arguments both emit an empty first line before
`7-Zip (z) 26.02 (arm64) : ...`. Any check using `head -n 1` gets `""`. Match on the
first line containing `7-Zip` instead. (`vendor/build-7zz.sh` had this bug.)

### A.4 Host-side concurrency hazards

Not `7zz` behaviour, but discovered driving it and equally load-bearing:

- **Blocking pipe reads must not run on the Swift cooperative thread pool.**
  `Task.detached` still uses that pool, and `FileHandle.availableData` blocks. A few
  concurrent operations exhaust the pool and deadlock the process. `ProcessRunner`
  uses dispatch queues, which grow a thread per blocked work item.
- **Never call `Process.waitUntilExit()` from a queue.** It deadlocks reproducibly
  once several processes are in flight. Use `terminationHandler`, and gate completion
  on *both* the exit notification and pipe EOF, since those two race in either order.

### A.5 Re-verification

`Tests/ArchiveCoreTests/LiveEngineTests.swift` encodes all of the above against the
real binary. It skips itself when `vendor/bin/7zz` is absent, so a bare checkout still
passes `swift test`. **Re-run it on every upstream version bump** — that is the whole
reason it exists.
