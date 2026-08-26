<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# Releasing ArcSeven

End-to-end runbook: from a clean checkout to a notarized DMG, a signed Sparkle
appcast, a GitHub Release and a Homebrew Cask bump.

Everything here is scripted. The scripts are the source of truth; this document
explains *why* each step is shaped the way it is, and what to do when a step
fails.

| Script | What it does |
|---|---|
| [`Scripts/sign.sh`](../Scripts/sign.sh) | Inside-out Developer ID signing, hardened runtime, secure timestamp |
| [`Scripts/make-dmg.sh`](../Scripts/make-dmg.sh) | Disk image with `/Applications` symlink and the legal notices |
| [`Scripts/notarize.sh`](../Scripts/notarize.sh) | `notarytool submit --wait`, then `stapler staple` + `validate` |
| [`Scripts/verify-release.sh`](../Scripts/verify-release.sh) | The publish gate — signature, Gatekeeper, ticket **and** compliance |

**The short version**

```sh
Scripts/sign.sh            build/export/ArcSeven.app
Scripts/notarize.sh        build/export/ArcSeven.app          # zips, submits, staples the .app
Scripts/make-dmg.sh        build/export/ArcSeven.app build/ArcSeven-1.0.0.dmg
Scripts/notarize.sh        build/ArcSeven-1.0.0.dmg
Scripts/verify-release.sh  build/export/ArcSeven.app build/ArcSeven-1.0.0.dmg
```

Nothing is published until `verify-release.sh` exits `0`.

---

## 0. Prerequisites (one-time)

| Thing | Where it comes from | Notes |
|---|---|---|
| Apple Developer Program membership | developer.apple.com, USD 99/year | Non-negotiable. Without it there is no Developer ID certificate, no notarization, and macOS refuses to launch the app without a bypass most users will not perform. |
| **Developer ID Application** certificate | Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates | Signs the `.app`, every nested Mach-O, and the `.dmg`. Ours: `Developer ID Application: Rajesh DMonte (HAMH7N3PJR)`. |
| Developer ID **Installer** certificate | same place | Only needed if we ever ship a `.pkg`. We ship a DMG. Skip. |
| App Store Connect **API key** | App Store Connect ▸ Users and Access ▸ Integrations ▸ Keys | Issuer UUID + Key ID + `AuthKey_XXXXXXXX.p8`. Preferred over Apple-ID + app-specific password: scoped, revocable, and not coupled to 2FA prompts. Store the `.p8` outside the repo, mode `600`. |
| Sparkle **EdDSA** key pair | Sparkle's `generate_keys` | Private key in the login keychain (and a CI secret); public key as `SUPublicEDKey` in `Info.plist`. DSA is dead — EdDSA only. |
| A public hosting location | GitHub Releases | Must serve the DMG, `appcast.xml`, **and the 7-Zip source tarball**. See [§11](#11-github-release). |

Environment for the scripts:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Rajesh DMonte (HAMH7N3PJR)"
export AC_API_KEY_ID="XXXXXXXXXX"
export AC_API_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export AC_API_KEY_PATH="$HOME/.appstoreconnect/AuthKey_XXXXXXXXXX.p8"
```

Sanity check before you start:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
xcrun notarytool --version
xcodebuild -version
```

---

## 1. Version bump

The version lives in exactly one place — `Config/Version.xcconfig`, included by
every target — so the app, the appexes, the XPC service and the DMG name can
never disagree.

```
MARKETING_VERSION = 1.0.0          // CFBundleShortVersionString — semver, user-visible
CURRENT_PROJECT_VERSION = 101      // CFBundleVersion — monotonic integer, never reused
```

* **`MARKETING_VERSION`** is semver. Breaking changes to the on-disk settings
  format or the engine protocol bump the major.
* **`CURRENT_PROJECT_VERSION`** must increase on every single build you publish,
  including re-releases of the same marketing version. **Sparkle compares
  `CFBundleVersion`, not the marketing string** — a re-release that reuses the
  build number is invisible to every existing install.

Also update, in the same commit:

1. `CHANGELOG.md` — the release notes Sparkle will show.
2. `THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` — **only if the bundled `7zz`
   changed** (see [§3](#3-vendor-and-verify-the-7zz-engine)).
3. `docs/release-notes/<version>.md` — the body of the GitHub Release.

Verify what the build system actually resolved, rather than what you think you
typed:

```sh
xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven -showBuildSettings \
  | grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'
```

Then tag — signed, because the tag is the GPLv3 §6 Corresponding Source anchor:

```sh
git commit -am "Release 1.0.0"
git tag -s v1.0.0 -m "ArcSeven 1.0.0"
```

Do not push the tag until the build is verified; a retracted tag is worse than a
late one.

---

## 2. Build universal (arm64 + x86_64)

Both reference apps in this space are universal and `7zz` is universal, so the
app must be too. Build **unsigned**, then sign with `Scripts/sign.sh`: Xcode's
own signing phase does not give us control over the inside-out order, and
`-exportArchive` will happily re-sign nested code with the host's entitlements.

```sh
rm -rf build
xcodebuild \
  -project ArcSeven.xcodeproj \
  -scheme ArcSeven \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath build/ArcSeven.xcarchive \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  archive

mkdir -p build/export
ditto "build/ArcSeven.xcarchive/Products/Applications/ArcSeven.app" "build/export/ArcSeven.app"
```

Confirm the result really is fat — a thin binary is the single most common
release-day surprise, because `ONLY_ACTIVE_ARCH` defaults differ between local
and CI builds:

```sh
lipo -archs build/export/ArcSeven.app/Contents/MacOS/ArcSeven      # x86_64 arm64
lipo -archs build/export/ArcSeven.app/Contents/Helpers/7zz      # x86_64 arm64
```

On CI pin the runner label (`macos-26`, never `macos-latest`) and the Xcode
version (`sudo xcode-select -s /Applications/Xcode_26.app`). A runner-image
rollout that silently changes the SDK is a real failure mode.

---

## 3. Build and verify the `7zz` engine

ArcSeven ships an **unmodified upstream** `7zz` at `Contents/Helpers/7zz` and drives
it as a subprocess. It is never linked in-process while RAR handlers are present.

**We compile it; we do not mirror a download.** Upstream publishes no universal
macOS binary, and a downloaded one could not be verified against anything except
a hash somebody typed. So the tree is a git submodule pinned to an exact commit,
and `vendor/build-7zz.sh` builds both slices from it with upstream's own
makefiles:

```
vendor/7zip/                  submodule, pinned to ip7z/7zip@f9d78aff…  (tag 26.02)
vendor/bin/7zz                the universal build output — GITIGNORED, never committed
vendor/bin/7zz.sha256         its hash, for --check
vendor/bin/BUILD-INFO.txt     what was built, from which commit, with which tools
```

Nothing under `vendor/bin/` is in the repository. It is reproduced on demand:

```sh
./vendor/build-7zz.sh            # build + verify + stage into vendor/bin/
./vendor/build-7zz.sh --check    # verify an already-staged binary against the pin
```

The script refuses to build a tree that diverges from the pin unless you pass
`--allow-dirty`, and a binary built that way is marked NOT DISTRIBUTABLE so
`--check` rejects it too. That refusal is the mechanism behind the
`Modifications: NONE` claim below.

### The provenance record

`THIRD_PARTY_LICENSES/7-Zip/VERSION.txt` is the record, regenerated by
`Scripts/refresh-third-party-licenses.sh` whenever the pin moves. Read the file
itself for the current values; the shape is:

```
7-Zip version:         26.02
Upstream tag:          26.02
Upstream commit:       f9d78aff31a5f2521ae7ddbdc97c4a8855808959
Binary origin:         COMPILED, not downloaded.  vendor/build-7zz.sh builds …
Binary SHA-256:        per release -- see SHA256SUMS.txt on the GitHub release
Source SHA-256:        per release -- see SHA256SUMS.txt on that release
Modifications:         NONE - bundled verbatim as a separate executable
```

**The commit hash is the anchor, not a checksum.** A binary compiled per release
has a different hash on every build — different toolchain, different linker,
different day — so a `Binary SHA-256` committed to this file would describe one
developer's machine and be wrong for every published build. What makes the
shipped binary and the shipped source tarball *correspond* is that both come
from the same pinned commit. Per-release checksums live in `SHA256SUMS.txt` on
the release that carries them, which is where a recipient checking their
download looks anyway.

The `Modifications: NONE` line does real work: it is the evidence that we
distribute an aggregate, not a derivative.

### What `verify-release.sh` actually checks

Three things, mechanically, before anything is published:

- **`Upstream commit:` matches the pinned submodule.** A submodule bump that
  forgets to regenerate `VERSION.txt` fails here. No commit line at all is also
  a failure — nothing would anchor the source offer.
- **The bundled `7zz` is the binary that was built here**, by comparing Mach-O
  `LC_UUID`s against `vendor/bin/7zz`. Signing rewrites the file's bytes but not
  its UUID, so this survives `sign.sh`. If `vendor/bin/7zz` has not been built,
  this degrades to a warning rather than a false pass.
- **`Modifications: NONE` is present**, and no `Binary/Source/License SHA-256:`
  line still holds a placeholder (`FILLED BY …`, `TODO`, `TBD`). The file shipped
  for five releases with a placeholder where a checksum belonged and the old
  check passed it, because a placeholder is not an empty string.

> **Never re-encode, strip, `lipo -thin`, or `install_name_tool` the built
> binary.** Any of those makes it a modified work and drags the whole
> aggregation argument into question.

Bumping `7zz` also requires re-fetching `THIRD_PARTY_LICENSES/7-Zip/LICENSE.txt`
(7-Zip's own `license.txt` demands verbatim reproduction) and re-running the
golden-file parser suite — `-slt` output is a human-facing UI, not a contract.

---

## 4. Signing — inside-out, always

```sh
Scripts/sign.sh build/export/ArcSeven.app
```

`codesign` seals a bundle by hashing its contents. Anything nested must already
carry its **final** signature before the container is signed, or the container's
seal is computed over bytes that no longer exist. The order is therefore fixed:

1. **The bundled `7zz` helper first**, plus every other nested Mach-O file —
   dylibs, `Sparkle.framework/Versions/B/Autoupdate`, embedded tools.
2. **Nested bundles, deepest first** — `Downloader.xpc` and
   `InstallerLauncher.xpc` inside Sparkle, then `Updater.app`, then
   `Sparkle.framework` itself.
   *(Sparkle 2.2 renamed its XPC services; any script still referencing
   `org.sparkle-project.*` names is out of date.)*
3. **App extensions** (`.appex`), each with **its own** entitlements file. An
   appex is sandboxed even though the host app is not.
4. **The `.app` last.**

Every invocation carries:

| Flag | Why |
|---|---|
| `--options runtime` | Hardened runtime (`flags=0x10000(runtime)`). **Notarization requires it on every Mach-O.** It is a codesign option, not an entitlement. |
| `--timestamp` | Secure timestamp from Apple's TSA. **Required for notarization**, and it is what keeps the signature valid after the certificate expires. |
| `--force` | Replace any signature the build system left behind. |

> **`--deep` is for verifying, never for signing.** Deep-signing applies the
> host's entitlements to nested code. The result either fails notarization or
> produces an appex that dies in `libsystem_secinit` at launch.

`sign.sh` finishes with `codesign --verify --deep --strict --verbose=2` and
asserts that the hardened-runtime flag, the Team Identifier and the timestamp are
all present on the app and on the bundled `7zz`.

### 4a. The entitlements we actually need

This is the part that everyone gets wrong, so it is stated plainly:

> **Spawning the bundled `7zz` requires NO `com.apple.security.cs.*` entitlement
> whatsoever.**
>
> Library validation requires that loaded code be signed by the **same Team ID**
> as the host (or by Apple). We sign `7zz` with our own Developer ID, so
> validation passes. And `posix_spawn`/`NSTask` of a separate process was never
> gated by library validation in the first place — that mechanism governs code
> loaded *into* your address space, not child processes.
>
> You would only need `com.apple.security.cs.disable-library-validation` to load
> a plugin signed by a *different* team, or an unsigned one — which we never do,
> and which notarization would reject anyway.

Verified against a shipping notarized archiver on macOS: its main app carries
**zero** `cs.*` keys, and its bundled 7-Zip binary carries exactly two
entitlements (`app-sandbox`, `inherit`) because that app is sandboxed. We are
not, so ours carries none.

The full `com.apple.security.cs.*` family and our answer for each:

| Entitlement | Purpose | Needed? |
|---|---|---|
| `cs.allow-jit` | `MAP_JIT` executable memory | ❌ (this is why Electron apps need it) |
| `cs.allow-unsigned-executable-memory` | unsigned executable pages | ❌ |
| `cs.allow-dyld-environment-variables` | honour `DYLD_*` | ❌ |
| `cs.disable-library-validation` | load code signed by another Team ID | ❌ **not needed — we sign our own helper** |
| `cs.disable-executable-page-protection` | disable W^X | ❌ (very invasive) |
| `cs.debugger` | attach as a debugger | ❌ |
| `cs.jit-write-allowlist` / `-freeze-late` | newer JIT hardening | ❌ |

What we *do* declare:

* **Main app** — not sandboxed, so its entitlements file is empty or absent.
  Filesystem access to Desktop/Documents/Downloads/removable volumes is governed
  by **TCC**, which is driven by `Info.plist` usage strings
  (`NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
  `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`) —
  those are Info.plist keys, not entitlements. Supply all four with honest
  strings.
* **App extensions** — `com.apple.security.app-sandbox` plus
  `com.apple.security.application-groups`
  (`HAMH7N3PJR.group.com.havokentity.ArcSeven`). Nothing else.
  `verify-release.sh` fails the build if an appex is not sandboxed.
* **`7zz`** — no entitlements at all. (If we ever sandbox, and only then, it gets
  exactly two keys: `app-sandbox` and `inherit`. A third key breaks inheritance
  and the child dies at launch.)

Not sandboxing the main app is a deliberate, settled decision: a two-pane file
manager with a location bar cannot work under the App Sandbox, where every
directory change becomes a PowerBox open panel. The consequence — no Mac App
Store — is one we would incur regardless, because Apple's Licensed Application
EULA is incompatible with the GPL.

---

## 5. Notarize the app, then staple it

```sh
Scripts/notarize.sh build/export/ArcSeven.app
```

The script zips the bundle for transport (`ditto -c -k --keepParent
--sequesterRsrc`), submits with `xcrun notarytool submit --wait`, and staples the
**`.app`** — a ticket cannot be attached to a `.zip`.

```sh
xcrun notarytool submit "$ZIP" \
  --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID" \
  --wait --timeout 45m
xcrun stapler staple  build/export/ArcSeven.app
xcrun stapler validate build/export/ArcSeven.app
```

`--wait` blocks until the verdict — no polling loop, unlike the old `altool`.

We notarize the app **and** the DMG. Stapling both means each survives being
separated from the other, and a stapled ticket is what makes first launch work
on a machine with no network.

**When it fails**, `notarize.sh` prints the per-binary reasons automatically:

```sh
xcrun notarytool log <submission-id> \
  --key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID"
```

In practice it is always one of three things: an unsigned nested Mach-O, a
signature made without `--timestamp`, or a binary signed without
`--options runtime`. All three are prevented by using `sign.sh` instead of
signing by hand.

---

## 6. Build the DMG

```sh
Scripts/make-dmg.sh build/export/ArcSeven.app build/ArcSeven-1.0.0.dmg
```

Contents:

```
ArcSeven.app        the signed, notarized, stapled application
Applications ->  symlink, so the drag-to-install gesture works
Legal/           LICENSE, NOTICE, THIRD_PARTY_LICENSES/
```

`Legal/` is not decoration: 7-Zip's `license.txt` requires binary
redistributions to reproduce its license information, and someone who receives
only the DMG must be able to read every notice without visiting GitHub.

The script uses `create-dmg` when the flag-driven variant is installed (window
layout, icon positions, optional background from `Resources/DMG/background.png`)
and falls back to `hdiutil create -format UDZO` otherwise — `create-dmg` drives
Finder over AppleScript and is unreliable on headless runners, so the fallback is
not hypothetical.

The volume name defaults to `ArcSeven <version>`. The script **refuses** a volume
name matching `7-Zip`: a volume name is a product identifier, and our trademark
posture is nominative use only.

The DMG is signed (`codesign --force --sign … --timestamp`) before it leaves the
script, because an unsigned image cannot be notarized. It prints the SHA-256 you
will paste into the Homebrew cask.

Keep the image small. A 50 MB archiver is normal; a 200 MB one makes users
bounce.

---

## 7. Notarize the DMG

```sh
Scripts/notarize.sh build/ArcSeven-1.0.0.dmg
xcrun stapler validate build/ArcSeven-1.0.0.dmg      # the script already did this
```

---

## 8. Verify — the publish gate

```sh
Scripts/verify-release.sh build/export/ArcSeven.app build/ArcSeven-1.0.0.dmg
```

This is the only step that is allowed to stop a release, and it must run against
the **final artifacts**, not intermediate ones. It performs:

```sh
codesign --verify --deep --strict --verbose=2 ArcSeven.app
spctl -a -vvv -t exec    ArcSeven.app     # expect: source=Notarized Developer ID
spctl -a -vvv -t install ArcSeven-1.0.0.dmg
xcrun stapler validate   ArcSeven.app
xcrun stapler validate   ArcSeven-1.0.0.dmg
```

plus, on every Mach-O in the bundle: correct Team ID, hardened runtime, secure
timestamp; universal slices on the app binary and on `7zz`; the bundle-identifier
root; the sandbox posture of each appex; the absence of `cs.*` entitlements; and
the whole compliance checklist below. It then **mounts the DMG** and re-runs the
app checks against the copy a user would actually install, checking the volume
name and the `/Applications` symlink on the way.

`ALLOW_UNNOTARIZED=1` downgrades the Gatekeeper and stapler checks to warnings,
for inspecting a build before it has been submitted. Never set it in the release
job.

Exit code `0` — and only exit code `0` — means you may publish.

---

## 9. Sign the Sparkle appcast

Sparkle 2 verifies updates with **EdDSA**; DSA-only updates are no longer
supported. The key pair is generated once:

```sh
./bin/generate_keys                    # writes the private key to the login keychain
                                       # and prints the public key
```

Put the printed public key in `Info.plist` as `SUPublicEDKey`, next to
`SUFeedURL` (**HTTPS only**), `SUEnableAutomaticChecks` and
`SUScheduledCheckInterval`.

Per release, sign the notarized DMG and regenerate the feed:

```sh
./bin/sign_update build/ArcSeven-1.0.0.dmg
# -> sparkle:edSignature="…" length="…"

./bin/generate_appcast build/updates/          # every DMG in the folder
```

`generate_appcast` reads the private key from the login keychain; in CI pass it
on stdin with `--ed-key-file -` from the `SPARKLE_ED_PRIVATE_KEY` secret. The
private key must never enter the repository.

Check the generated `appcast.xml` before publishing:

* `sparkle:version` = `CFBundleVersion` (the monotonic integer), and
  `sparkle:shortVersionString` = `MARKETING_VERSION`.
* `sparkle:edSignature` present on the enclosure.
* `sparkle:minimumSystemVersion` = `14.0`.
* The enclosure URL is the **public** GitHub Releases download URL, over HTTPS.

Because the app is **not sandboxed**, none of Sparkle's installer-service
plumbing is needed: no `SUEnableInstallerLauncherService`, no
`com.apple.security.temporary-exception.mach-lookup.global-name`. That is one
more point in favour of not sandboxing.

---

## 10. Test the update path

Before publishing, install the **previous** release from a DMG, point it at a
staging appcast, and take the update. An appcast that only works for fresh
installs is not an update mechanism. Verify the updated app is still notarized
and stapled afterwards.

---

## 11. GitHub Release

`havokentity/ArcSeven` is public, so release assets are publicly downloadable and
the LGPL source offer below is actually discharged by attaching the tarball. It
was private while this document was first written; if it is ever made private
again, that stops being true the moment anyone receives a DMG, and the DMG, the
source tarball and the appcast have to move to a public host instead.

In practice `.github/workflows/release.yml` does all of this — pushing the tag is
the whole trigger. The commands below are what it runs, and what you would run by
hand if CI were unavailable. CI assembles every asset into `dist/`; a by-hand run
following §6 leaves the DMG in `build/`, so collect the four into one directory
first or adjust the paths.

```sh
git push origin master        # NOT main; master is this repository's default branch
git push origin v1.0.0

gh release create v1.0.0 \
  --repo havokentity/ArcSeven \
  --title "ArcSeven 1.0.0" \
  --notes-file docs/release-notes/1.0.0.md \
  dist/ArcSeven-1.0.0.dmg \
  dist/7zip-26.02-src.tar.xz \
  dist/SHA256SUMS.txt \
  dist/appcast.xml
```

The tarball name comes from `Scripts/make-source-tarball.sh`, which writes
`dist/7zip-<version>-src.tar.xz` where `<version>` is the submodule's exact tag —
or, if the pin sits on an untagged commit, the first twelve characters of the
commit hash. It is `7zip-`, not upstream's `7z2602-`: this is our archive of the
pinned tree, produced by `git archive`, not a mirror of upstream's own tarball.

The second and third assets are not optional and are not niceties. The fourth is
not optional either — `releases/latest/download/appcast.xml` is the feed URL in
every shipped bundle, so a stable release without it 404s the installed base.
`release.yml` fails rather than publish one; see `docs/CI-SETUP.md`.

> **The 7-Zip source tarball must be attached to the same Release as the DMG.**
> LGPL-2.1 §4: *if distribution of object code is made by offering access to copy
> from a designated place, then offering equivalent access to copy the source
> code from the same place satisfies the requirement to distribute the source
> code.* Attaching `7zip-<ver>-src.tar.xz` to the release that carries the DMG
> discharges §4 completely — no three-year written offer, no mailing anything.
>
> A hyperlink to 7-zip.org does **not** do this. "The same place" means *our*
> distribution point — and it is also why the tarball is generated from our own
> pinned submodule rather than mirrored: upstream moves old files when a new
> version lands, and a `git archive` of the exact commit we compiled cannot go
> stale or disagree with the binary.

The signed tag covers our own Corresponding Source under GPLv3 §6.

Also verify the release page carries `SHA256SUMS.txt`, so users can check what
they downloaded — and so the per-release binary and source hashes that
`VERSION.txt` deliberately does not pin have somewhere to live:

```sh
shasum -a 256 dist/*.dmg dist/*.tar.xz
```

---

## 12. Homebrew Cask

Notarization is effectively mandatory for casks now — unsigned, un-notarized
casks are deprecated and slated for removal from the official tap. We are
already compliant.

```ruby
cask "arcseven" do
  version "1.0.0"
  sha256 "<sha256 printed by make-dmg.sh>"

  url "https://github.com/havokentity/ArcSeven/releases/download/v#{version}/ArcSeven-#{version}.dmg",
      verified: "github.com/havokentity/ArcSeven/"
  name "ArcSeven"
  desc "Graphical archive manager compatible with 7-Zip formats"
  homepage "https://github.com/havokentity/ArcSeven"

  livecheck do
    url "https://github.com/havokentity/ArcSeven/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  depends_on macos: ">= :sonoma"

  app "ArcSeven.app"

  zap trash: [
    "~/Library/Application Support/ArcSeven",
    "~/Library/Caches/com.havokentity.ArcSeven",
    "~/Library/Group Containers/HAMH7N3PJR.group.com.havokentity.ArcSeven",
    "~/Library/Preferences/com.havokentity.ArcSeven.plist",
    "~/Library/Saved Application State/com.havokentity.ArcSeven.savedState",
  ]
end
```

Submission checklist:

```sh
brew audit --cask --online arcseven
brew audit --cask --new arcseven            # first submission only
brew style --fix arcseven
HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask arcseven
```

All four must be clean, and the cask must work on the latest major macOS.

Subsequent releases are a one-liner:

```sh
brew bump-cask-pr --version 1.0.1 arcseven
```

---

## COMPLIANCE CHECKLIST

**Every box must be ticked before the release is published.** `verify-release.sh`
checks the mechanical ones and exits non-zero if any fail; the rest are yours.

### Licence files — shipped, not just committed

- [ ] **`LICENSE` present** — the complete, unmodified GPL-3.0 text, at the repo
      root **and** inside the bundle at `Contents/Resources/Legal/LICENSE`.
      *(checked by `verify-release.sh`)*
- [ ] **`NOTICE` present** — at the repo root **and** at
      `Contents/Resources/Legal/NOTICE`. It carries the 7-Zip attribution triple
      ("uses parts of the 7-Zip program" / "7-Zip is licensed under the GNU LGPL"
      / a link to `https://www.7-zip.org`), the unRAR paragraph, the source
      offer, and the non-affiliation statement. *(checked)*
- [ ] **`THIRD_PARTY_LICENSES` current** — at
      `Contents/Resources/Legal/THIRD_PARTY_LICENSES/`, containing
      `7-Zip/LICENSE.txt` (verbatim from 7-zip.org, re-fetched if `7zz` was
      bumped), `7-Zip/LGPL-2.1.txt`, `7-Zip/VERSION.txt` with the exact version,
      the `Upstream commit:` the binary was built from, and
      `Modifications: NONE`, and one directory per other bundled dependency
      (Sparkle). *(checked)*
- [ ] The DMG carries `Legal/` too — a DMG-only recipient must be able to read
      every notice offline. *(checked)*

### The LGPL source offer — the one that is easy to forget

- [ ] **The 7-Zip SOURCE TARBALL is attached as an asset on the same GitHub
      Release as the DMG.** This is how the LGPL-2.1 §4 source offer is
      discharged: *equivalent access to copy the source from the same place.*
      Same release, same page, same version as the `7zz` in the bundle.
      A link to 7-zip.org does not satisfy it.
- [ ] `SHA256SUMS.txt` is attached too, and its tarball line matches the
      `.sha256` that `make-source-tarball.sh` wrote beside the tarball.
      `VERSION.txt` deliberately records no per-release checksum — the binary is
      compiled per release, so the release's own checksum file is the only place
      a true one can live.
- [ ] A signed git tag for this exact release is pushed, so ArcSeven's own
      Corresponding Source is available (GPLv3 §6).

### unRAR

- [ ] **The unRAR notice is present in-app** — verbatim, in the Acknowledgements
      pane, not only in a file in the repo. The unRAR licence requires the
      statement *"in the documentation"*, and for a shipped application that
      means text the user can actually read. Rendering the shipped
      `Legal/NOTICE` in the pane satisfies this. *(partially checked)*
- [ ] The same paragraph appears in `README.md` and `NOTICE`.
- [ ] **No "create RAR archive" affordance anywhere in the UI**, and no RAR
      compression code in the repository. RAR is read-only, forever.

### GPL obligations in the UI

- [ ] The About panel shows the copyright, "no warranty", "you may convey this
      work under the GPL", and how to view the licence — GPLv3 §5(d) Appropriate
      Legal Notices. A prominent menu item satisfies it.
- [ ] Help ▸ Legal Notices opens the Acknowledgements pane.

### Trademark posture

- [ ] No "7-Zip" / "7Zip" in the app name, bundle identifier, DMG volume name or
      repository name. *(checked)*
- [ ] Every user-facing mention of 7-Zip is nominative — "compatible with",
      "reimplementation of" — never possessive and never implying endorsement.
- [ ] The non-affiliation line is present in the About panel, `README.md` and
      `NOTICE`.

### Build integrity

- [ ] Signed inside-out, hardened runtime and secure timestamp on **every**
      Mach-O, notarized, stapled, `spctl` reports `source=Notarized Developer ID`
      for both app and DMG. *(checked)*
- [ ] App binary and `7zz` are universal (arm64 + x86_64). *(checked)*
- [ ] Bundled `7zz` is the build produced from the pinned submodule — Mach-O
      UUIDs match `vendor/bin/7zz`, and `VERSION.txt`'s `Upstream commit:`
      matches what the submodule is pinned at. *(checked)*
- [ ] `reuse lint` passes: every first-party file carries
      `SPDX-License-Identifier: GPL-3.0-or-later`.
- [ ] No `com.apple.security.cs.*` entitlements. *(checked)*
- [ ] Every appex is sandboxed. *(checked)*

---

## Failure playbook

| Symptom | Cause | Fix |
|---|---|---|
| `notarytool` returns `Invalid` | An unsigned nested Mach-O, a missing `--timestamp`, or a missing `--options runtime` | `xcrun notarytool log <id> …` names the file. Re-run `sign.sh`; never hand-sign one binary. |
| `codesign` hangs forever in CI | The keychain is locked, or `security set-key-partition-list` was not run | Add `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PW" "$KC"` after importing the `.p12`. Without it codesign waits on an invisible dialog until the job times out. |
| `spctl` says `rejected` on a notarized build | Assessment cached, or the ticket is not stapled | `xcrun stapler staple` then re-assess. `spctl --assess -vvv` prints the real reason. |
| `stapler` says `Error 65` | The notarization ticket is not published yet | Wait a minute and retry; `--wait` returned before Apple's CDN caught up. |
| App launches for you, "damaged" for users | You never stapled, or a nested binary is signed by a different team | `verify-release.sh` catches both. Run it on the DMG, not the build directory. |
| Sparkle offers no update | `CFBundleVersion` was not incremented | Sparkle compares `CFBundleVersion`, not the marketing version. Bump `CURRENT_PROJECT_VERSION` and re-release. |
| `brew audit` fails on `livecheck` | Feed URL unreachable or not a valid appcast | The appcast must be a public HTTPS URL, and `releases/latest/download/appcast.xml` only resolves once a stable release has actually carried that asset. |

---

## CI shape

* **Pull request** → `macos-26`, build + tests, **no signing**. Secrets are not
  exposed to fork PRs; design for that rather than fighting it.
* **Tag `v*`** → build universal → `sign.sh` → notarize the app → `make-dmg.sh` →
  notarize the DMG → **`verify-release.sh` as a required gate** → `sign_update` →
  `generate_appcast` → `gh release create` (DMG **and** the 7-Zip source tarball)
  → `brew bump-cask-pr`.

Secrets: `BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`,
`APPLE_TEAM_ID`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`, `NOTARY_KEY_P8_BASE64`,
`SPARKLE_ED_PRIVATE_KEY`. All eight are required for a stable tag — the last one
stopped being optional when a real `SUPublicEDKey` started shipping in every
bundle; see `docs/CI-SETUP.md`.

Always clean up in an `if: always()` step:

```sh
rm -f "$RUNNER_TEMP"/*.p8 "$RUNNER_TEMP"/*.p12
security delete-keychain "$RUNNER_TEMP/build.keychain-db" || true
```
