<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# Sparkle 2 in ArcSeven

**This describes the shipped integration.** It was written as a to-do list while Sparkle
was being wired up, and every step in it has since landed — so it is now a reference for
how auto-update is put together and, more usefully, *why* each piece is the way it is.
Where a snippet appears, it is the code that is in the tree, not a patch to apply.

It arrived in pieces, which is worth knowing when reading an old build's behaviour:

| Landed | What |
| --- | --- |
| before 0.1.2 | `Sparkle.framework` embedded and signed, `UpdaterController` written |
| 0.1.2 | `SUFeedURL` and friends moved onto the **app's** Info.plist, where Sparkle reads them; `SUPublicEDKey` added |
| 0.1.3 | `UpdaterController.start()` called, and a **Check for Updates…** menu item to reach it |
| 0.1.4 | Sparkle's MIT licence actually shipped in `THIRD_PARTY_LICENSES/` |
| 0.1.5 | `release.yml` fails rather than publish a stable release with no appcast |

Two things are still open. The **beta channel does not work** and three separate pieces
make it look as though it does — [§8](#the-beta-channel-is-not-wired-up). And nobody has
yet watched a real install take a real update — [§10](#10-what-is-still-unverified).

The EdDSA key pair is generated: its public half is in `project.yml` and ships in every
bundle. Its private half exists in exactly two places, both by hand and neither of them
this repository — [§4](#4-key-generation--do-this-yourself).

---

## 0. What the Swift side does

`UpdaterController` is a `@MainActor` wrapper around `SPUStandardUpdaterController`, with
the whole implementation behind `#if canImport(Sparkle)` and a no-op twin in the `#else`
branch that reports `canCheckForUpdates == false`. That is not defensive decoration:
`Package.swift` has no external dependencies by policy, so `swift build` and `swift test`
— which is all `ci.yml` runs — never see Sparkle, and the fallback is the code path CI
compiles.

Public surface, identical in both branches:

```swift
UpdaterController.shared                              // the one updater
.start()                                              // idempotent; call at launch
.checkForUpdates(_:)                                  // @objc, menu action
.canCheckForUpdates                                   // Bool, for validation
.automaticallyChecksForUpdates                        // get/set, for a Settings toggle
.presentAutomaticUpdateConsentIfNeeded()              // asks once, from launch 2 onward
UpdaterController.willRelaunchNotification            // posted before an update relaunch
UpdaterPreferences.{automaticallyChecks, hasAskedForConsent, includesPrereleases}
```

### The consent rule

**Automatic checking defaults to off and stays off until the user has been asked.** A
scheduled check is an unattended HTTPS request carrying the app version and the OS
version. Making it on first launch, unasked, is phoning home, and a GPL tool does not get
to do that quietly. So:

* `SUEnableAutomaticChecks` is `false` in Info.plist ([§1.3](#13-infoplist-keys)).
* `UpdaterController.start()` forces `automaticallyChecksForUpdates` and
  `automaticallyDownloadsUpdates` to `false` on every launch until consent has been
  recorded.
* `updaterShouldPromptForPermissionToCheckForUpdates` returns `false`, so Sparkle never
  puts up its own permission dialog on our behalf.
* `presentAutomaticUpdateConsentIfNeeded()` asks, once, from the **second** launch
  onwards — the first thing a new user sees should be their files, not a dialog about
  network policy. The answer is recorded either way and never re-asked.
* After consent, Sparkle's own stored answer becomes authoritative, so the checkbox
  inside Sparkle's update window works and is not silently undone at the next launch.

"Check for Updates…" in the menu is always available. That one *is* the user asking.

---

## 1. `project.yml`

### 1.1 The package

`project.yml` carries a top-level `packages:` key, between `fileGroups:` and the
project-wide `settings:` banner. Sparkle is the only entry, and the only external
dependency in the whole project:

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: "2.9.6"
```

Three things about that, each deliberate:

* **It is not in `Package.swift`.** The two AppKit-free modules there must keep resolving
  with no network and no Xcode, which is what makes `ci.yml` green for pull requests from
  forks that never receive secrets. `Sources/App` is built only by the Xcode project, so
  Sparkle lives only here.
* **`exactVersion:`, not `from:`.** An auto-update framework that silently changes version
  between two builds of the same tag is the last place anyone wants a floating range. The
  resolved pin is recorded in
  `ArcSeven.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; check
  there, not here, for what a given build actually linked.
* **MIT, which is GPL-3.0 compatible in the direction we need** (permissive into
  copyleft). Sparkle is *linked*, not exec'd like the `7zz` helper, so it is genuinely
  part of the combined work — see [§7](#7-third-party-licence-bookkeeping).

Bumping it is a one-line edit plus `xcodegen`. A tag that does not exist fails at
generation time with a resolution error, which is loud and harmless.

### 1.2 The target dependency

The `ArcSeven` target's `dependencies:` block, in full:

```yaml
    dependencies:
      - package: Sparkle
        product: Sparkle
      - target: QuickLookPreview
        embed: true
      - target: ArcSevenFinder
        embed: true
        codeSign: false
```

Two appexes, not three — there is no `QuickActions` target; `Extensions/QuickActions/`
holds a `README.md`, an `Info.plist` and an entitlements file for a target nobody has
written yet.

No `embed:` key on the package: Xcode embeds a dynamic framework product from a Swift
package into an application target automatically, and `LD_RUNPATH_SEARCH_PATHS` in the
project's base settings already carries `@executable_path/../Frameworks`.

**Verify it actually embedded** after a Sparkle bump — this is the one part of the package
plumbing that fails silently:

```sh
ls -d build/.../ArcSeven.app/Contents/Frameworks/Sparkle.framework
```

If it is missing, the app will link but die at launch with a dyld "Library not loaded"
error. The fix is an explicit copy-files phase into `frameworks`, not a rerun.

### 1.3 Info.plist keys

Four keys, in the `info: ▸ properties:` block of the **`ArcSeven`** target, after the
copyright string and before the `# ---- TCC:` banner:

```yaml
        SUPublicEDKey: 5mai3p83QNIAbw/nSEOSkZXeAez+DCurHqGwihqOVhQ=
        SUFeedURL: https://github.com/havokentity/ArcSeven/releases/latest/download/appcast.xml
        SUEnableAutomaticChecks: false
        SUScheduledCheckInterval: 86400
```

* `SUPublicEDKey` is the **public** half of the EdDSA pair ([§4](#4-key-generation--do-this-yourself)).
  Publishing it is the entire point of it: it ships in every copy of the app so that an
  installed copy can verify an update was signed by the private half. Changing it strands
  every already-installed copy — they reject updates signed by the new key, and the only
  route back is a manual re-download.
* `SUFeedURL` is HTTPS, because Sparkle refuses a plaintext feed and should.
* `SUEnableAutomaticChecks: false`, and it stays false. `UpdaterController` asks the user
  once and writes the answer through; see the consent rule above. The key mainly exists to
  stop Sparkle putting up its own permission dialog on first launch.
* `SUScheduledCheckInterval` is one day in seconds. Sparkle clamps anything under 3600 up
  to an hour anyway, and a file manager is not something anyone needs polled more often.

**On the app's target, not an extension's.** Through 0.1.1 this block sat in
`QuickLookPreview`'s `Info.plist`, where Sparkle never reads it: the app shipped with no
feed URL at all, so it could not have checked for an update even once. Preflight now
asserts the keys against the built app bundle for exactly this reason.

Deliberately **absent**, and it matters — see [§5](#5-sandboxing--read-this-one):
`SUEnableInstallerLauncherService`, `SUEnableDownloaderService`,
`SUEnableJavaScriptReleaseNotes`, and every
`com.apple.security.temporary-exception.mach-lookup.global-name` entitlement.

---

## 2. `MainMenuBuilder.swift`

The application menu reads About → separator → **Check for Updates…** → separator →
Settings…, which is where every Mac app puts it. In `applicationMenuItem()`:

```swift
        menu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())

        // Target set explicitly rather than left to the responder chain: UpdaterController
        // is not in it, and an unrouted action is a permanently greyed-out menu item that
        // looks exactly like "no update available". Enablement comes from
        // UpdaterController's own validateMenuItem(_:), which returns canCheckForUpdates —
        // false in a build without Sparkle, so the item greys out honestly.
        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(UpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = UpdaterController.shared
        menu.addItem(checkForUpdates)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Settings…", action: Selector(("showSettings:")), keyEquivalent: ",")
```

No key equivalent, on purpose: there is no conventional one, and the App Store review
guideline habit of giving it ⌘U collides with nothing here but reads as invented.

`#selector` works in both builds — the fallback `UpdaterController` declares the same
`@objc` method.

---

## 3. `AppDelegate.swift`

Two call sites in `applicationDidFinishLaunching(_:)`.

**(a)** early, with the other launch-time registrations, before the window exists:

```swift
        UpdaterController.shared.start()
```

Starting is not checking. With automatic checks off — the default — a started updater
schedules nothing and opens no connection; it only makes the menu item live, and counts
the launch that (b) defers against. Nothing called this until 0.1.3, so every earlier
build shipped a fully configured, fully signed updater that was never asked anything.

**(b)** as the **last** statement of the method, after the queued Finder actions have been
replayed, deferred one runloop turn so the window is on screen first:

```swift
        DispatchQueue.main.async {
            UpdaterController.shared.presentAutomaticUpdateConsentIfNeeded()
        }
```

Order matters between the two: `start()` increments the launch counter that decides
whether this launch is the first (skip) or the second onwards (ask, once, ever).

Note that the `presentMissingEngine()` path returns early and so never asks. That is
correct — the app is about to terminate.

**Optional, later:** a Settings ▸ Updates toggle binds straight to
`UpdaterController.shared.automaticallyChecksForUpdates`, and a "Include pre-releases"
checkbox to `UpdaterPreferences.includesPrereleases`. Neither needs new plumbing.

---

## 4. Key generation — do this yourself

**This is not done for anyone, ever.** A signing key that has passed through someone
else's hands is not a signing key. The pair ArcSeven ships with was generated by the
maintainer and its private half has never been in this repository; what follows is the
procedure, kept because rotating or regenerating one day means running it again.

Sparkle ships `generate_keys` in the `bin/` directory of its release tarball (and in the
`Sparkle` cask). Run it once, ever:

```sh
./bin/generate_keys
```

It does two things:

1. Stores the **private** key in your **login keychain** as a generic password item
   (`https://sparkle-project.org`). It never writes it to disk.
2. Prints the **public** key, base64. That string goes into `SUPublicEDKey` in
   `project.yml` ([§1.3](#13-infoplist-keys)) and is safe to commit — publishing it is the
   entire point of it.

For CI, export the private half **once**, feed it straight to `gh`, and destroy the file:

```sh
./bin/generate_keys -x sparkle-private-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY --repo havokentity/ArcSeven < sparkle-private-key.txt
rm -P sparkle-private-key.txt
```

Rules, none of them optional:

* **Never commit the private key.** Not to this repo, not to a private one, not in a
  `.env`, not in a comment, not "temporarily".
* **Never paste it into a shell argument.** `gh secret set` reading stdin is used above
  precisely because `argv` is readable by every process on the machine through `ps`.
  `Scripts/appcast.sh` feeds it to `sign_update` on stdin for the same reason.
* **Back the login keychain up.** Losing the private key means no existing install can
  ever be updated again: they all verify against the `SUPublicEDKey` baked into the copy
  they already have. Recovering from that means asking every user to redownload by hand.
* Rotating the key is a two-release operation — ship the new public key first, then start
  signing with the new private key — so it is worth not needing to.

`SPARKLE_ED_PRIVATE_KEY` is **not** an optional secret, whatever older copies of this
document and `docs/CI-SETUP.md` said. Since 0.1.5 `release.yml` fails the run when it is
missing on a stable tag, because a stable release publishes with no `appcast.xml`, becomes
`releases/latest`, and 404s the `SUFeedURL` in every installed copy. A prerelease tag may
still be built without it — `releases/latest` excludes prereleases, so such a release can
never become the feed anyone reads.

---

## 5. Sandboxing — read this one

**ArcSeven is not sandboxed, so Sparkle's XPC services are not required. Do not add
them.**

This is the single biggest source of Sparkle setup confusion, and it costs people days,
so it is worth being blunt about. Sparkle 2 ships `Downloader.xpc` and
`Installer.xpc` for the *only* case that needs them: a **sandboxed** app, which
cannot make its own outbound connection for the download or launch the installer, and so
has to hand both jobs to services that carry those entitlements themselves. Wiring them
up also requires `SUEnableInstallerLauncherService`, `SUEnableDownloaderService`, and
`com.apple.security.temporary-exception.mach-lookup.global-name` entitlements naming the
services.

None of that applies here. `project.yml` sets `com.apple.security.app-sandbox: false` and
explains why: a two-pane file manager that spawns a helper, crosses volumes, writes xattrs
and vends file promises cannot live in a container. An unsandboxed app downloads and
installs its own updates directly.

Concretely:

* Do **not** add the two `SUEnable…Service` Info.plist keys. Neither is in the built
  `Info.plist`; check with `plutil -p … | grep SUEnable`, which should show only
  `SUEnableAutomaticChecks`.
* Do **not** add any `temporary-exception.mach-lookup` entitlement.
* Do **not** go looking for something to delete. The XPC services **are** in the shipped
  bundle, at
  `Sparkle.framework/Versions/B/XPCServices/{Downloader,Installer}.xpc` — the SPM
  `Sparkle` product brings them along whether you want them or not, and earlier versions
  of this document were wrong to say it does not. They are inert without the `SUEnable…`
  keys, `sign.sh` phase 2 signs them along with every other nested `*.xpc`, and removing
  them by hand would only break the framework's seal.

`Sparkle.framework` also contains `Autoupdate` and `Updater.app`. Those are **not** the
XPC services and are always required. See the next section.

---

## 6. Signing and notarisation

`Scripts/sign.sh` needed no Sparkle-specific changes, because it signs inside-out and
generically rather than by name:

* **Phase 1** signs every nested Mach-O file, deepest first. For Sparkle that is
  `Sparkle.framework/Versions/B/Autoupdate`,
  `Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater`, and the framework's
  own binary.
* **Phase 2** signs every nested bundle matching `*.xpc`, `*.framework`, `*.app`,
  `*.bundle` or `*.mdimporter`, deepest first — so `Updater.app` before
  `Sparkle.framework`. `Versions/Current` is a symlink and `find` does not follow it, so
  nothing is signed twice through the alias.
* **Phase 4** signs the app last.

Every invocation already carries `--options runtime --timestamp --force`, and the
hardened runtime on *every* Mach-O is what notarisation requires. Nothing about Sparkle
changes that.

### What `codesign --deep --strict` must cover

`--deep` is used **only to verify**, never to sign — deep-*signing* applies the host's
entitlements to nested code, which is how an appex ends up dying in `libsystem_secinit`
and how a notarisation ticket gets refused. Both `Scripts/sign.sh` and
`Scripts/verify-release.sh` already run:

```sh
codesign --verify --deep --strict --verbose=2 ArcSeven.app
```

For that to pass, every one of these must be independently, validly signed with the same
Developer ID, with the hardened runtime and a secure timestamp:

```
ArcSeven.app/Contents/Frameworks/Sparkle.framework
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
```

The last two are unused ([§5](#5-sandboxing--read-this-one)) but present, and `--deep
--strict` does not care whether code is reachable — only whether it is sealed.

None of them takes entitlements, and `sign.sh` gives them none — its phase 1 and phase 2
sign nested Mach-O files and nested bundles with no `--entitlements` at all.

Note that this is *not* the same as "sign.sh only passes `--entitlements` to `.appex`
bundles", which this document claimed for several releases and which is false: phase 4
signs the **app** with `Sources/App/Resources/ArcSeven.entitlements` as well, because the
app needs its App Group to talk to the two extensions. The rule that matters is narrower
and holds — *nested* code inside `Sparkle.framework` is signed without entitlements, so
Sparkle's helpers do not inherit the app's. That is exactly why `--deep` is never used to
sign: deep-signing would push the app's entitlements onto `Autoupdate` and `Updater.app`,
and a notarisation ticket gets refused for it.

Spot-check after a release build:

```sh
codesign -dvvv --entitlements - \
  ArcSeven.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app 2>&1 \
  | grep -E 'Authority|flags|Timestamp'
# flags must include runtime; Timestamp must be a real date, not "not set"
```

Recurring notarisation failures, and what each actually means:

| notarytool message | Cause |
| --- | --- |
| `The signature of the binary is invalid` on `Autoupdate` | The framework was signed before its nested Mach-O files. Sign inside-out. |
| `The executable does not have the hardened runtime enabled` on `Updater` | Something signed it without `--options runtime`. Xcode's copy-phase signing does this; that is why the release build sets `CODE_SIGNING_ALLOWED=NO` and lets `sign.sh` do all of it. |
| `The signature does not include a secure timestamp` | `--timestamp` missing. Debug config omits it on purpose; release adds it. Never notarise a Debug build. |
| `The binary is not signed with a valid Developer ID certificate` on a Sparkle binary | A stale ad-hoc signature from a prebuilt XCFramework survived. `--force` replaces it; make sure `xattr -cr` ran too. |

---

## 7. Third-party licence bookkeeping

Sparkle 2 is MIT with some bundled BSD-licensed pieces. Both are GPL-3.0-or-later
compatible, and unlike the 7zz helper — which is exec'd as a separate process precisely to
avoid combining with it — Sparkle is **linked**, so it is part of the combined work and
its notices ship with the binary.

Since 0.1.4 that means:

```
THIRD_PARTY_LICENSES/Sparkle/LICENSE         # verbatim from the pinned tag
```

plus a row in `THIRD_PARTY_LICENSES/README.md` recording the version, the licence, and —
the part that matters — that Sparkle is **LINKED** rather than exec'd like `7zz`.
`project.yml` copies the whole `THIRD_PARTY_LICENSES` directory into
`Contents/Resources/Legal/`, so a DMG-only recipient can read it offline. Verified in the
built bundle, not just in the repo: `Contents/Resources/Legal/THIRD_PARTY_LICENSES/Sparkle/LICENSE`.

Bumping the pin means checking the upstream `LICENSE` still matches and updating the
version in that row. `Scripts/refresh-third-party-licenses.sh` is 7-Zip-specific and does
not do it for you — MIT text does not change under you the way a vendored source tree
does, but the version number does.

---

## 8. The appcast and GitHub Releases

### URL scheme

| | URL |
| --- | --- |
| Feed (`SUFeedURL`) | `https://github.com/havokentity/ArcSeven/releases/latest/download/appcast.xml` |
| Enclosure (per item) | `https://github.com/havokentity/ArcSeven/releases/download/v<version>/ArcSeven-<version>.dmg` |

`/releases/latest/download/<asset>` is a permanent alias that GitHub redirects to the
newest **non-prerelease** release's asset of that name. That is the property the feed URL
needs: it is baked into every copy of the app ever shipped and can never be changed
without abandoning old installs, so it must not name a tag.

Three consequences, all of which have bitten someone:

1. **The repository must stay public.** `havokentity/ArcSeven` is public, so this holds
   today. Release assets on a private repo are not publicly downloadable — the feed would
   404 for everyone, including you, once you are logged out — and the same blocker would
   cover the Homebrew cask and the LGPL source offer.
2. **Every stable release must carry an `appcast.xml`.** The alias resolves to the newest
   non-prerelease release's asset *of that name*; a stable release published without one
   does not fall back to the previous release's copy, it 404s. Since 0.1.5 `release.yml`
   fails rather than publish one — see [§4](#4-key-generation--do-this-yourself).
3. **`/latest/` skips prereleases**, so the feed served to everyone is always the one
   attached to the newest *stable* release. `Scripts/appcast.sh` emits a one-item feed for
   whatever is in `dist/`, which is exactly right for the stable channel: each stable
   release publishes a feed naming itself, and that is all Sparkle needs to offer an
   update to anyone older.

### The beta channel is not wired up

Stated plainly, because three separate pieces of machinery *look* like a working
prerelease channel and none of them can currently fire:

* `Scripts/appcast.sh` puts `<sparkle:channel>beta</sparkle:channel>` on any item whose
  marketing version carries a semver prerelease identifier. Correct, and inert.
* `UpdaterController.allowedChannels(for:)` returns `["beta"]` when
  `UpdaterPreferences.includesPrereleases` is true — and **nothing ever sets it**. There
  is no Settings toggle bound to it, so it is always false and the set is always empty.
* `SUFeedURL` points at `/releases/latest/`, which excludes prereleases, so a prerelease's
  appcast is never the file an installed copy fetches even if the flag were set.

The upshot is that stable users cannot be offered a prerelease, which is the safe
direction to be broken in. Making it work is three changes, not one: a Settings toggle
writing `includesPrereleases`, a **cumulative** feed (one file carrying both stable and
beta items — a per-tag one-item feed cannot express a channel), and a `SUFeedURL` that can
reach it, most likely GitHub Pages. Note that changing `SUFeedURL` only affects builds
shipped *after* the change; every existing install keeps reading the old one forever.

### `Scripts/appcast.sh`

`release.yml` calls it after the checksums step. Behaviour, which is a contract:

```sh
Scripts/appcast.sh dist/
```

* `SPARKLE_ED_PRIVATE_KEY` **unset** → prints why, writes nothing, exits **0**. That is a
  convenience for a **local** run, where nobody has the CI secret and nobody is
  publishing. It is deliberately *not* what CI does: `release.yml` checks the secret
  itself and fails a stable tag before this script is ever reached, then asserts that
  `dist/appcast.xml` exists afterwards. Do not "fix" the asymmetry in either direction.
* `SPARKLE_ED_PRIVATE_KEY` **set** but `sign_update` **not found** → exits **non-zero**
  with an explanation. This is the important one: Sparkle rejects an enclosure with no
  `sparkle:edSignature`, so a silently unsigned feed would only surface weeks later, on a
  user's machine, as "the updater has never worked".
* `sign_update` is found via `$SIGN_UPDATE`, then `PATH`, then a search of `.build/` and
  the DerivedData `SourcePackages/artifacts` tree — the last is where SwiftPM puts
  Sparkle's tools on a CI runner, and it moves between Xcode versions, so it is searched
  rather than hard-coded.
* The private key goes to `sign_update` **on stdin** (`--ed-key-file -`), never as an
  argument.
* `sparkle:version` (CFBundleVersion) and `sparkle:shortVersionString` are read out of the
  app **inside** each DMG, by mounting it read-only, rather than parsed from the file
  name. Sparkle compares `CFBundleVersion`; getting it wrong ships a release that no
  existing install is ever offered. `APPCAST_BUILD_VERSION` / `APPCAST_SHORT_VERSION`
  exist as a fallback for environments where `hdiutil attach` is unavailable, and are
  cross-checked against the bundle whenever the bundle can be read — a disagreement is
  fatal.
* The `length` reported by `sign_update` is cross-checked against `stat -f%z`. A mismatch
  means the DMG changed after signing (a stapler pass, typically) and Sparkle would reject
  the download after making the user wait for it.
* A marketing version containing a semver prerelease identifier gets
  `<sparkle:channel>beta</sparkle:channel>`, matching `allowedChannels(for:)` in
  `UpdaterController`.
* `sparkle:minimumSystemVersion` is `14.0`, matching `MACOSX_DEPLOYMENT_TARGET`. Both are
  overridable by environment; keep them in step.
* Output is validated with `xmllint --noout` before the script reports success.

Knobs, all defaulted: `APPCAST_REPO`, `APPCAST_TITLE`, `APPCAST_DOWNLOAD_BASE`,
`APPCAST_RELEASE_BASE`, `APPCAST_FEED_URL`, `MINIMUM_SYSTEM_VERSION`, `SIGN_UPDATE`,
`APPCAST_BUILD_VERSION`, `APPCAST_SHORT_VERSION`. CI sets none of them. `--help` prints
the list.

---

## 9. Testing the update path

An appcast that only works for fresh installs is not an update mechanism. Before the first
release that anyone else takes:

1. Build and publish release **N** normally.
2. Install **N** from its DMG into `/Applications` and run it once, so its
   `SUPublicEDKey` and `SUFeedURL` are the ones a real user has.
3. Build **N+1** with a **higher `CFBundleVersion`** — `release.yml` uses
   `GITHUB_RUN_NUMBER`, which is monotonic, so this is automatic in CI and a manual
   concern only for local builds.
4. Point the installed **N** at a staging feed (`defaults write com.havokentity.ArcSeven
   SUFeedURL <url>`) and take the update.
5. Afterwards confirm the *updated* app is still signed, notarised and stapled:
   `spctl -a -t exec -vv /Applications/ArcSeven.app` must still say
   `source=Notarized Developer ID`.
6. Undo the staging override: `defaults delete com.havokentity.ArcSeven SUFeedURL`.

Also worth checking once, by hand, because it is the whole point of §0: on a machine that
has never run ArcSeven, launch it twice and confirm that **no** network request is made
before the consent dialog appears, and that answering "Don't Check" means none is made
afterwards either. `nettop -p ArcSeven` or Little Snitch is enough.

| Symptom | Cause |
| --- | --- |
| Menu item permanently greyed out | Built without Sparkle (the fallback reports `canCheckForUpdates == false`), or `target` not set on the menu item. |
| "You're up to date" on a newer release | `CFBundleVersion` was not incremented. Sparkle compares that, not `CFBundleShortVersionString`. |
| "Update is improperly signed" | `SUPublicEDKey` does not match the private key the appcast was signed with. Check you did not regenerate the pair. |
| Feed never loads, no error shown | Scheduled checks fail quietly by design. `log stream --predicate 'subsystem == "com.havokentity.ArcSeven" AND category == "updater"'` — `UpdaterController` logs the abort reason there for exactly this. |
| Update downloads, then nothing happens | `Autoupdate` or `Updater.app` is unsigned or mis-signed. See [§6](#6-signing-and-notarisation). |
| Prerelease offered to a stable user | Should be unreachable today — `/releases/latest/` never resolves to a prerelease's appcast, so a stable install cannot even fetch one. If it happens, an item is missing its `<sparkle:channel>`: check the tag actually carried a semver prerelease identifier. |
| Feed 404s for everyone after a release | That release published without `appcast.xml` and became `releases/latest`. Re-run the release, or upload the appcast to the latest release by hand; `release.yml` has refused to publish one this way since 0.1.5. |

---

## 10. What is still unverified

Stated plainly so nobody assumes more than was done. The list has shrunk as the
integration landed; what remains is what nobody has actually watched happen.

* **The DMG-mount path of `Scripts/appcast.sh` under CI.** Exercised locally against real
  UDZO images — single and multiple, stable and prerelease, including the cross-check and
  length-mismatch failure paths — but `hdiutil attach` on a GitHub runner is a different
  environment, and the fallbacks (`APPCAST_BUILD_VERSION` / `APPCAST_SHORT_VERSION`) exist
  precisely because it might not work there.
* **A real end-to-end update.** [§9](#9-testing-the-update-path) describes the test;
  nobody has yet installed release *N* from its DMG and taken *N+1* through Sparkle on a
  clean machine. Until someone has, "auto-update works" is an inference from parts that
  each work, not an observation.
* **The consent rule, observed from the network side.** That no request leaves the machine
  before the user answers is what the code says and what `start()`'s tests assert. Nobody
  has watched it in `nettop`.

Since resolved, and recorded because the reasoning is still useful:

* **The pinned version tag.** This document guessed `2.7.1` without network access. The
  tree pins `2.9.6`, resolved and recorded in `Package.resolved`.
* **Sparkle's exact delegate signatures.** `UpdaterController` was written against a
  hand-written stand-in for the Sparkle API rather than real headers, so the
  `SPUUpdaterDelegate` extension was the one place a first build could plausibly fail. It
  compiles against the real framework. The hooks implemented are
  `feedParameters(for:sendingSystemProfile:)`, `allowedChannels(for:)`,
  `updaterShouldPromptForPermissionToCheckForUpdates(_:)`, `updater(_:didAbortWithError:)`,
  `updater(_:failedToDownloadUpdate:error:)` and `updaterWillRelaunchApplication(_:)`.
  Every one is optional in the protocol, so deleting any of them still compiles — read the
  comment above it first and decide whether you are giving something up.
* **`SPUUpdaterDelegate`'s actor annotation.** Every hook is declared `nonisolated`, which
  is a valid witness whether or not Sparkle annotates the protocol as main-actor. If a
  future Sparkle marks it `@MainActor`, the `nonisolated` spellings still compile and can
  be relaxed at leisure.

`Sources/App/UpdaterController.swift` compiles under Swift 6 with
`-strict-concurrency=complete` and `ExistentialAny` in **both** branches — with Sparkle
and without it — and `swiftlint --strict` is clean on it. `Scripts/appcast.sh` was run end
to end: skip path, missing-`sign_update` failure, single-DMG feed, two-DMG feed,
beta-channel item, version cross-check failure, length-mismatch failure, and
empty-directory failure.
