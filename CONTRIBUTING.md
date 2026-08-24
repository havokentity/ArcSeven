<!--
SPDX-FileCopyrightText: 2026 Rajesh D'Monte
SPDX-License-Identifier: GPL-3.0-or-later
-->

# Contributing to ArcSeven

Thanks for wanting to help. This document covers the four things that are non-negotiable —
licensing, provenance, code style, and fidelity — and then the mechanics.

Please read [Clean-room rule](#clean-room-rule-non-negotiable) before you write a single line.
It is the one rule that, if broken, cannot be fixed by a follow-up commit.

---

## Licensing of contributions: inbound = outbound

ArcSeven is **`GPL-3.0-or-later`**. Contributions are accepted under that same license — *inbound =
outbound*. There is **no CLA and no copyright assignment**: you keep the copyright in your work, and
you license it to the project and to everyone downstream under the GPL, exactly as the project is
already licensed.

Every new first-party file must begin with the SPDX header, using the comment syntax of its
language:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Rajesh D'Monte
```

```bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
```

Use the deprecated identifiers `GPL-3.0` or `GPL-3.0+` nowhere. CI runs `reuse lint`, which fails
the build on any file that is not accounted for.

If you contribute substantially, add your own `SPDX-FileCopyrightText:` line above the existing
one rather than replacing it. You are not signing your copyright away.

---

## Developer Certificate of Origin (DCO)

Every commit must be signed off. The sign-off is your statement that you have the right to submit
the work under the project's license — it is the
[Developer Certificate of Origin 1.1](https://developercertificate.org/), the same mechanism the
Linux kernel uses. In short, you are certifying that the contribution is either your own original
work, or is derived from work covered by a compatible open-source license which you are permitted
to submit, or was provided to you by someone who made one of those certifications; that you
understand the contribution and the record of it are public and are maintained indefinitely; and
that it may be redistributed consistently with this project's license.

Sign off by committing with `-s`:

```bash
git commit -s -m "FMKit: implement the 7zFM sort comparator"
```

which appends exactly this trailer as the last line of the commit message:

```
Signed-off-by: Random J Developer <random@developer.example.org>
```

The name and email must be your real name and a reachable address, and must match your git
`user.name` / `user.email`. Pseudonyms and `noreply` addresses are not accepted. Anonymous or
corporate-placeholder sign-offs defeat the entire point of the DCO.

To fix a missing sign-off on the last commit:

```bash
git commit --amend -s --no-edit
```

To fix a whole branch:

```bash
git rebase --signoff origin/main
```

CI rejects any pull request containing a commit without a valid `Signed-off-by` trailer.

---

## Clean-room rule (non-negotiable)

**No source code from 7-Zip, unRAR, WinRAR, p7zip, or NanaZip may ever be pasted, copied,
transcribed, machine-translated, or otherwise carried into this repository — in any form, in any
language, in any quantity, ever.**

This is not stylistic purity. It is the load-bearing beam of the project's legal position:

- 7-Zip is **LGPL-2.1-or-later** with **BSD-2/BSD-3** parts and, critically, an **unRAR use
  restriction** on the RAR decoder. That restriction — *"the code may not be used to develop a
  RAR (WinRAR) compatible archiver"* — is a **further restriction**, forbidden by GPLv3 §10 and
  classified as such by GPLv3 §7. Fedora's determination is that it makes the code
  "GPL-Incompatible and non-free".
- ArcSeven stays GPL-clean *only* because the RAR-capable code lives in a **separate process** we do
  not link, embed, or modify. That is mere aggregation. One convenient copy-paste of a
  `Rar5Handler` helper, one "I just ported this small function", and the aggregation argument
  collapses into a combined work that we have no right to distribute.
- p7zip is a dead 2016 fork of 7-Zip carrying the same restriction. NanaZip is a 7-Zip derivative
  whose `SevenZip` directories remain under the 7-Zip license. Neither is a laundering route.

Also do not paste from **ShichiZip**, **7-Zip-zstd**, **PeaZip**, **Double Commander**, or any other
archiver: they are either 7-Zip derivatives, or differently licensed, or both. If you want to bring
in third-party code under a GPL-compatible license, open an issue *first* and we will vendor it
properly with its own directory, its own license file, and an entry in `THIRD_PARTY_LICENSES/`.

### What you do instead

The upstream `.rc` resource scripts and C++ sources are the **behavioural specification**. Read
them, understand what they do, write down what they do, then implement that in Swift from the
description.

1. **Keep upstream outside this repository.** Clone `github.com/ip7z/7zip` somewhere else on your
   disk. Never `git add` an upstream file. `vendor/` is git-ignored precisely so the `7zz` binary
   cannot be committed by accident.
2. **Cite file and line in a comment above your implementation**, with the upstream version so a
   future reader can find it again after the line numbers move:

   ```swift
   // Behaviour spec: CPP/7zip/UI/FileManager/PanelSort.cpp:213-268 (7-Zip 26.02).
   // "..", when present, sorts first and is immune to the descending flag; folders then sort
   // before files, also immune; only then is the sort PROPID compared, cascading through
   // kpidName and kpidPrefix for at most three iterations, falling back to the stable
   // enumeration index; the descending negation is applied last, to the cascaded result only.
   ```

3. **Describe behaviour, not text.** "Level combo is populated from a per-format bitmask; Zip
   exposes 0, 1, 3, 5, 7, 9" is a description. A transliterated `switch` copied structure-for-
   structure from `CompressDialog.cpp` is not, however much you rename the variables.
4. **User-visible strings are a special case.** Reproducing 7zFM's exact wording in a dialog is a
   compatibility requirement, and short functional UI strings are the kind of thing fidelity
   demands. Reproducing *code* is not. If you are unsure which side of that line you are on, ask in
   the issue before writing the PR.
5. **If you have read the upstream source for a given subsystem, say so in the PR.** That is
   expected and fine — it is how the spec gets written. What is not fine is the code arriving with
   upstream's structure intact.

A PR that appears to contain copied code will be closed rather than revised, and the branch will not
be merged even after cleanup, because the provenance is already muddied. Please do not put us in
that position.

---

## Code style

### Swift 6, strict concurrency, no exceptions

- The project builds in **Swift 6 language mode** with **complete strict concurrency checking**, and
  warnings are errors in CI. Code that only compiles with the checks relaxed does not land.
- Shared mutable state lives in an `actor` or is protected by one. AppKit code is `@MainActor`.
  `ArchiveCore` and `FMKit` contain **no AppKit** and no main-actor assumptions — they are the parts
  that must remain testable off the main thread.
- `@preconcurrency`, `nonisolated(unsafe)`, and `@unchecked Sendable` each require a comment on the
  same declaration explaining precisely why the escape hatch is sound. "To silence the warning" is
  not a reason.
- Prefer structured concurrency (`async`/`await`, task groups) over `DispatchQueue` chaining.
  Long-running work is cancellable, and cancellation must actually kill the `7zz` process group, not
  just abandon the read loop.
- No `try!`, no force-unwrap, and no `fatalError` outside genuinely unreachable `switch` defaults
  and test code. Parsers must survive hostile input: the golden corpus deliberately includes a
  corrupted archive and a filename containing a newline.

### SwiftLint

`.swiftlint.yml` at the repo root is authoritative. Run it before you push:

```bash
swiftlint --strict
swiftlint --fix        # applies the autocorrectable rules
```

CI runs `swiftlint --strict`; any violation fails the build. If a rule is genuinely wrong for a
piece of code, disable it for the narrowest possible scope with
`// swiftlint:disable:next <rule>` plus a reason — never file-wide, never repo-wide without
discussion.

### Structure and naming

- Module and target name is **`ArcSeven`** (Swift module names cannot begin with a digit); the
  user-facing product is **ArcSeven**. Bundle identifiers are `com.havokentity.ArcSeven` and
  `com.havokentity.ArcSeven.<ext>` for app extensions.
- Put code in the right module — `ArchiveCore` (engine, parsers, models; no AppKit), `FMKit`
  (file-manager domain; no views), `FMUI` (AppKit), `Dialogs`, `SettingsUI`, `Support`. The module
  boundaries are what make the M5 in-process engine swap a one-file change.
- Dense file panes are **view-based `NSTableView`** with a fixed `rowHeight`. Do not reach for
  SwiftUI `Table` or `usesAutomaticRowHeights`; both fall over at 100k rows, and 200k-entry
  archives are in the test corpus for that reason. SwiftUI belongs inside `NSHostingController`
  for Settings and small surfaces only.
- Commit subjects are imperative and scoped: `ArchiveCore: handle exit code 1 as success-with-warnings`.

---

## Running the tests

```bash
Scripts/bootstrap.sh                                    # once: fetches 7zz into vendor/, installs tooling
xcodegen generate                                       # regenerate ArcSeven.xcodeproj from project.yml
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven test
```

To run a single suite while iterating:

```bash
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven test \
  -only-testing:ArchiveCoreTests
```

### The golden-file corpus

`Tests/Fixtures/` holds the archives that every parser change must be re-run against: 7z solid and
non-solid, zip, tar.gz, rar, encrypted bodies, encrypted headers, multi-volume, a 200k-entry
archive, UTF-8 filenames (`café_日本.txt`), NFD-vs-NFC pairs, a legacy CP932 zip, a deliberately
corrupted archive, and a filename containing a newline.

Rules for the corpus:

- **Any change to the `l -slt` parser, the byte-stream tokenizer, or the exit-code mapper must run
  the full corpus.** These are the components where a plausible-looking refactor silently breaks one
  format.
- Fixtures are generated by a script, not committed by hand, so they can be rebuilt against a new
  `7zz`. If you add a fixture, add its generator too.
- Add a regression fixture with every parser bug fix. A bug report that comes with an archive that
  reproduces it is worth ten that do not.
- Behavioural expectations are asserted against **observed `7zz` output**, not against what the
  documentation claims. Progress is backspace-delimited, exit code `1` means *success with
  warnings*, and both were verified empirically rather than assumed.

---

## The fidelity principle

ArcSeven's premise is that it behaves the way the Windows 7-Zip File Manager behaves. When the source
and your intuition disagree, **the source wins** — including where 7zFM is arguably wrong. Some of
its quirks are load-bearing for users with twenty years of muscle memory.

But not every Windows behaviour survives contact with macOS, and some are outright bugs. Those
divergences are *allowed* — they are just not allowed to be *silent*.

**Every behaviour that differs from Windows 7zFM must be recorded in
[`docs/DIVERGENCES.md`](docs/DIVERGENCES.md), in the same pull request that introduces it.** A PR
that changes observable behaviour without a `DIVERGENCES.md` entry will be sent back.

Each entry states the upstream behaviour with its file/line citation, our behaviour, and the reason,
classified as one of:

- **adapted** — same capability, macOS-native mechanism (`F2` rename → `Return`, because `Return`
  means rename on this platform; `Del`→Recycle Bin → `⌘⌫`→Trash; polling `SetTimer` auto-refresh →
  FSEvents).
- **dropped** — not shipped, with the reason (NTFS directory junctions and WSL links have no macOS
  analogue; `Use large memory pages` has no equivalent; the `MFT_MENUBARBREAK` two-column Edit menu
  is a Win32 construct with no counterpart).
- **fixed** — an upstream defect we correct, e.g. the shipped strings
  `"File {0} is already exist"` and `"Split to &volumes,  bytes:"` with its double space, and the
  fact that on Windows almost every shortcut fires only when the list view has focus.
- **improved** — additive behaviour that does not alter the 1:1 path, such as a non-modal Properties
  inspector or proper `validateToolbarItem` enable state (with the never-disabled Windows behaviour
  preserved under the "7-Zip Classic" preset).

If you find a place where ArcSeven diverges from 7zFM and `DIVERGENCES.md` does not say so, that is a
bug — please file it. Discrepancy reports are among the most valuable contributions to this project.

---

## Pull requests

1. Open an issue first for anything larger than a bug fix, so the design gets settled before the
   code does.
2. Branch from `main`. Keep the PR to one concern.
3. Make sure `swiftlint --strict`, `reuse lint`, and the full test suite pass locally.
4. Every commit signed off (`git commit -s`).
5. Say in the PR description which milestone (M0–M6) the work belongs to, and — if you read upstream
   sources to write it — which files, so the clean-room trail is visible.
6. New behaviour that differs from Windows 7zFM ships with its `docs/DIVERGENCES.md` entry.

---

## Reporting security issues

Do not open a public issue for a security problem. Email the maintainer instead. Of particular
interest: anything touching the App Group / XPC transport used by the Finder Quick Actions
(an unauthenticated transport there is a confused-deputy hole that has already bitten a comparable
project), password handling, Keychain access control, or `com.apple.quarantine` propagation.
