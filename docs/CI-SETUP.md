<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# CI and release setup

Two workflows:

| Workflow | Trigger | Needs secrets |
| --- | --- | --- |
| `.github/workflows/ci.yml` | every push to `master` and every PR | **No** |
| `.github/workflows/release.yml` | pushing a tag matching `v*` | **Yes** — see below |

CI deliberately needs no secrets. Pull requests from forks never receive them, so a
pipeline that needs a Developer ID to go green is permanently red for outside
contributors. That is the reason `ArchiveCore` and `FMKit` are AppKit-free and driven by
`Package.swift`: `swift build` and `swift test` need neither Xcode's signing machinery
nor the vendored `7zz`, so the parsers, the sort comparator and the exit-code mapper —
the parts that actually break — are covered on every push.

## Cost

This repository is **private**, and GitHub bills macOS runners at a **10× minute
multiplier**. A personal account's 2,000 free minutes per month is therefore about
**200 macOS minutes**. A full CI run is three jobs; the release workflow is longer
because it builds the vendored 7-Zip from source and waits on Apple's notary service.

`ci.yml` already has `paths-ignore` for docs and Markdown, and
`concurrency: cancel-in-progress`, so pushing twice in a minute does not pay twice.
If minutes get tight, the honest lever is to drop the `pull_request` trigger to
`types: [opened, synchronize]` or run the lint job on `ubuntu-latest` — SwiftLint has a
Linux build and the lint job needs no Xcode.

## Release secrets

Eight, all required for a stable release. Set them with
`gh secret set NAME --repo havokentity/ArcSeven`, which reads the value from stdin so it
never lands in your shell history.

### Signing certificate

1. Keychain Access ▸ **login** ▸ My Certificates ▸ your **Developer ID Application**
   certificate ▸ right-click ▸ Export ▸ `.p12`. Give it a strong password.
2. Then:

```bash
base64 -i DeveloperID.p12 | gh secret set BUILD_CERTIFICATE_BASE64 --repo havokentity/ArcSeven
```

- `P12_PASSWORD` — the password you set on the `.p12`.
- `KEYCHAIN_PASSWORD` — any random string; it protects the throwaway keychain the
  runner creates and destroys within the job. `openssl rand -base64 24` is fine.
- `APPLE_TEAM_ID` — `HAMH7N3PJR`.

Delete the exported `.p12` afterwards. It is a signing identity; treat it like a key.

### Notarisation

App Store Connect ▸ Users and Access ▸ Integrations ▸ Keys ▸ **App Store Connect API**,
create a key with the **Developer** role. You can download the `.p8` exactly once.

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8_BASE64 --repo havokentity/ArcSeven
```

- `NOTARY_KEY_ID` — the 10-character Key ID.
- `NOTARY_ISSUER_ID` — the UUID shown above the key list.

### Auto-update signing

- `SPARKLE_ED_PRIVATE_KEY` — from Sparkle's `generate_keys`.

This one used to be optional, and is not any more. Every shipped bundle carries a real
`SUPublicEDKey` and a `SUFeedURL` of
`https://github.com/havokentity/ArcSeven/releases/latest/download/appcast.xml`. A stable
release publishes and immediately *becomes* `releases/latest`, so a release with no
`appcast.xml` attached makes that URL 404 for **every already-installed copy**, not only
the ones that would have updated to it. Scheduled checks fail quietly by design, so
nobody sees an error: the installed base just stops receiving updates until some later
release repairs the feed.

So `release.yml` now fails the run when the secret is missing on a stable tag, before
anything is published. A **prerelease** tag (`v1.2.0-beta.1`) may still be built without
it — GitHub's `releases/latest` alias excludes prereleases, so such a release can never
become the feed an installed copy reads.

## Cutting a release

```bash
git tag -a v0.1.0 -m "ArcSeven 0.1.0" && git push origin v0.1.0
```

The workflow builds a universal Release bundle, signs it, notarises and staples the app
and the DMG, verifies signature/notarisation/architectures, and publishes a GitHub
Release.

## The compliance step is not optional

`release.yml` builds and attaches the **7-Zip corresponding-source tarball** to the same
release as the DMG. That is how the LGPL-2.1 §4 source offer is discharged — "equivalent
access to copy the source code from the same place". Do not remove that step, and do not
publish a release where it failed. See `NOTICE` and `docs/RELEASING.md`.

---

## Making ArcSeven the default archive app

```bash
swiftc -O -o .build/setdefault Scripts/tools/SetDefaultHandler.swift
.build/setdefault show     # what opens each type today
.build/setdefault set      # claim them for ArcSeven
```

**macOS asks you to confirm every type, one modal dialog each.** There are 25, so expect
25 clicks. That is the system's behaviour — there is no supported batch API and no way to
suppress the prompt. The tool warns and asks before it starts, and skips any type that
already points at the target, so re-running it is a no-op rather than another 25 dialogs.

To hand them back:

```bash
.build/setdefault set com.aone.keka
```

Six declared types are deliberately never claimed: `public.data` (matches every file with
no better type), `.dmg`, `.pkg`, `.msi`, `.jar` and `.war`. Each of those double-clicks is
*doing something* rather than *looking inside*, and taking them over would be hostile.
