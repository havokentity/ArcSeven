<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Rajesh D'Monte -->

# Wiring up Sparkle 2

The Swift side is done and merged: `Sources/App/UpdaterController.swift`. It compiles
**with or without** Sparkle present, so nothing in this document is urgent and nothing in
it can break the build if it is applied in pieces.

What is left is project plumbing, and all of it lives in files this document does not
touch. Apply the snippets below, in order.

| Step | File | Who |
| --- | --- | --- |
| 1 | `project.yml` — package, dependency, Info.plist keys | project owner |
| 2 | `Sources/App/MainMenuBuilder.swift` — the menu item | app owner |
| 3 | `Sources/App/AppDelegate.swift` — two call sites | app owner |
| 4 | EdDSA key pair — `generate_keys` | **you, by hand, once** |
| 5 | `SPARKLE_ED_PRIVATE_KEY` repository secret | you, by hand |
| 6 | `THIRD_PARTY_LICENSES/Sparkle/` + `NOTICE` | anyone |

`Scripts/sign.sh`, `Scripts/verify-release.sh` and `.github/workflows/release.yml` need
**no changes at all**. Why, for each, is in [§6](#6-signing-and-notarisation) and
[§8](#8-the-appcast-and-github-releases).

---

## 0. What the Swift side already does

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

`project.yml` has no `packages:` key today. Add one as a **new top-level key**, at column
zero, the same indentation as `targets:`. It goes between the end of the `fileGroups:`
list — the `  - Package.swift` line — and the `# Project-wide build settings` comment
banner above `settings:`.

Anchors rather than line numbers throughout this section: `project.yml` is being edited in
parallel and the numbers will have moved by the time you read this.

```yaml
# ---------------------------------------------------------------------------------------
# Swift Package dependencies
# ---------------------------------------------------------------------------------------
# The ONLY external dependency in the whole project, and it is deliberately not in
# Package.swift: the two AppKit-free modules there must keep resolving with no network and
# no Xcode, which is what makes ci.yml work for pull requests from forks. Sources/App is
# built only by this project, so Sparkle lives only here.
#
# Sparkle 2 is MIT-licensed, which is GPL-3.0 compatible in the direction we need
# (permissive into copyleft). It is linked, not exec'd, so unlike the 7zz helper it is
# genuinely part of the combined work - see THIRD_PARTY_LICENSES and step 6 below.
#
# Pinned exactly, not `from:`. An auto-update framework that silently changes version
# between two builds of the same tag is the last place to want a floating range.
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    exactVersion: "2.7.1"
```

> **Check the tag before you paste it.** `2.7.1` is what the newest 2.x was believed to be
> when this was written and it was **not verified against the network** — see
> [§10](#10-what-was-not-verified). Open
> <https://github.com/sparkle-project/Sparkle/releases>, take the newest `2.x`, and put
> that number here. A tag that does not exist fails at `xcodegen generate` time with a
> resolution error, which is loud and harmless. `2.6.4` is a known-good floor if you want
> something conservative.

### 1.2 The target dependency

In the `dependencies:` block of the **`ArcSeven`** target — the one whose first entry is
`- target: QuickLookPreview` — add the package as the new **first** entry, above the
`- target:` entries:

```yaml
    dependencies:
      - package: Sparkle
        product: Sparkle
      - target: QuickLookPreview
        embed: true
      - target: ArcSevenFinder
        embed: true
        codeSign: false
      - target: QuickActions
        embed: true
        codeSign: false
```

No `embed:` key: Xcode embeds a dynamic framework product from a Swift package into an
application target automatically, and `LD_RUNPATH_SEARCH_PATHS` in the project's base
settings already carries `@executable_path/../Frameworks`.

**Verify it actually embedded**, once, after the first build — this is the one part of the
package plumbing that fails silently:

```sh
ls -d build/.../ArcSeven.app/Contents/Frameworks/Sparkle.framework
```

If it is missing, the app will link but die at launch with a dyld "Library not loaded"
error. The fix is an explicit copy-files phase into `frameworks`, not a rerun.

### 1.3 Info.plist keys

In the `info: ▸ properties:` block of the **`ArcSeven`** target — there are three
`NSHumanReadableCopyright` keys in the file, and this is the first one. Put the new keys
directly after that copyright string and before the `# ---- TCC:` banner, as their own
commented block:

```yaml
        # ---- Sparkle 2 auto-update ------------------------------------------------------
        # See docs/SPARKLE-INTEGRATION.md. Distribution is Developer ID + notarised DMG
        # from GitHub Releases; there is no Mac App Store build, so there is no build where
        # these keys are wrong to have.
        #
        # HTTPS only. Sparkle refuses a plaintext feed, and it should.
        SUFeedURL: https://github.com/havokentity/ArcSeven/releases/latest/download/appcast.xml
        # The public half of the EdDSA pair from generate_keys (step 4). The PRIVATE half
        # never appears in this file, in this repository, or in any build product.
        SUPublicEDKey: REPLACE_WITH_PUBLIC_KEY_FROM_generate_keys
        # False, and it stays false. UpdaterController asks the user once and writes the
        # answer through; see the consent rule in the integration doc. This key exists here
        # mainly to stop Sparkle putting up its own permission dialog on first launch.
        SUEnableAutomaticChecks: false
        # Seconds. One day. Sparkle clamps anything under 3600 up to an hour anyway, and a
        # file manager is not something anyone needs polled more often than that.
        SUScheduledCheckInterval: 86400
```

Deliberately **absent**, and it matters — see [§5](#5-sandboxing-read-this-one):
`SUEnableInstallerLauncherService`, `SUEnableDownloaderService`,
`SUEnableJavaScriptReleaseNotes`, and every
`com.apple.security.temporary-exception.mach-lookup.global-name` entitlement.

---

## 2. `MainMenuBuilder.swift`

In `applicationMenuItem()`. The application menu currently reads About → separator →
Settings…; the update command goes between the separator and Settings, which is where
every Mac app puts it.

Find:

```swift
        menu.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: Selector(("showSettings:")), keyEquivalent: ",")
```

Replace with:

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

Two lines, in `applicationDidFinishLaunching(_:)`.

**(a)** immediately after `MainMenuBuilder.install()`:

```swift
        NSApp.setActivationPolicy(.regular)
        MainMenuBuilder.install()

        // Inert with automatic checks off, which is the default: a started updater with
        // nothing scheduled opens no connection. Starting here is only what makes
        // "Check for Updates…" live, and it is what counts the launch that the consent
        // prompt below defers against.
        UpdaterController.shared.start()
```

**(b)** as the **last** statement of the method, after the queued-action replay:

```swift
        let queuedActions = pendingActions
        pendingActions.removeAll()
        for queued in queuedActions { perform(queued.action, on: queued.urls) }

        // Asked exactly once, and never on the very first launch. Deliberately after the
        // window is up and after anything Finder queued has been replayed, so the dialog
        // is never the first thing on screen.
        UpdaterController.shared.presentAutomaticUpdateConsentIfNeeded()
    }
```

Order matters between the two: `start()` increments the launch counter that the consent
prompt defers against, so (a) must precede (b).

Note that the `presentMissingEngine()` path returns early and so never asks. That is
correct — the app is about to terminate.

**Optional, later:** a Settings ▸ Updates toggle binds straight to
`UpdaterController.shared.automaticallyChecksForUpdates`, and a "Include pre-releases"
checkbox to `UpdaterPreferences.includesPrereleases`. Neither needs new plumbing.

---

## 4. Key generation — do this yourself

**This was not done for you, and must not be.** A signing key that has passed through
anyone else's hands is not a signing key.

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

`docs/CI-SETUP.md` already lists `SPARKLE_ED_PRIVATE_KEY` as the one optional secret, and
`release.yml` already skips the appcast step when it is unset. Nothing there needs
editing.

---

## 5. Sandboxing — read this one

**ArcSeven is not sandboxed, so Sparkle's XPC services are not required. Do not add
them.**

This is the single biggest source of Sparkle setup confusion, and it costs people days,
so it is worth being blunt about. Sparkle 2 ships `Downloader.xpc` and
`InstallerLauncher.xpc` for the *only* case that needs them: a **sandboxed** app, which
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

* Do **not** copy `XPCServices/` out of the Sparkle distribution into the bundle.
* Do **not** add the two `SUEnable…Service` Info.plist keys.
* Do **not** add any `temporary-exception.mach-lookup` entitlement.
* The SPM `Sparkle` product does not bring the XPC services along, so the default is
  already correct. The mistake only happens when someone follows a sandboxed-app tutorial
  and adds them by hand.

`Sparkle.framework` still contains `Autoupdate` and `Updater.app`. Those are **not** the
XPC services and are always required. See the next section.

---

## 6. Signing and notarisation

`Scripts/sign.sh` needs no changes. It already signs inside-out and generically:

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
```

None of them takes entitlements. `sign.sh` only passes `--entitlements` to `.appex`
bundles, which is right: Sparkle's helpers must **not** inherit the app's.

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

Do the same thing the 7-Zip tree does:

```
THIRD_PARTY_LICENSES/Sparkle/LICENSE.txt     # verbatim from the pinned tag
THIRD_PARTY_LICENSES/Sparkle/VERSION.txt     # the pinned version and its commit
```

`project.yml` already copies the whole `THIRD_PARTY_LICENSES` directory into
`Contents/Resources/Legal/`, so nothing else is needed to make it reachable from the About
box. Add a Sparkle paragraph to `NOTICE` and a row to
`THIRD_PARTY_LICENSES/README.md` while you are there.

`Scripts/refresh-third-party-licenses.sh` is 7-Zip-specific and does not need to learn
about Sparkle; MIT text does not change under you the way a vendored source tree does.

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

1. **The repository must be public.** Release assets on a private repo are not publicly
   downloadable — the feed 404s for everyone, including you, once you are logged out. See
   the warning at `docs/RELEASING.md` §11; the same blocker covers the Homebrew cask and
   the LGPL source offer.
2. **`/latest/` skips prereleases**, so the feed served to everyone is always the one
   attached to the newest *stable* release. `Scripts/appcast.sh` emits a one-item feed for
   whatever is in `dist/`, which is exactly right for the stable channel: each stable
   release publishes a feed naming itself, and that is all Sparkle needs to offer an
   update to anyone older.
3. **The `beta` channel therefore needs its own home.** A prerelease's `appcast.xml` is
   attached to the prerelease, which `/latest/` will never resolve to. Until that matters,
   `UpdaterPreferences.includesPrereleases` is off and stable users are never offered a
   prerelease item, which is the safe default. When it does matter, publish a cumulative
   feed to GitHub Pages and point `SUFeedURL` there instead — one file containing every
   item, `<sparkle:channel>beta</sparkle:channel>` on the prerelease ones. Note that
   changing `SUFeedURL` only affects builds shipped *after* the change.

### `Scripts/appcast.sh`

Written and tested; `release.yml` already calls it. Behaviour, which is a contract:

```sh
Scripts/appcast.sh dist/
```

* `SPARKLE_ED_PRIVATE_KEY` **unset** → prints why, writes nothing, exits **0**. The
  release pipeline works unchanged before Sparkle is wired up, which is what `release.yml`
  relies on. `release.yml` guards this too; the guard is duplicated so a local run behaves
  identically.
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
| Prerelease offered to a stable user | An item carries no `<sparkle:channel>`. Check the tag actually had a semver prerelease identifier. |

---

## 10. What was not verified

Stated plainly so nobody assumes more than was done.

* **The pinned version tag.** `2.7.1` in [§1.1](#11-the-package) was not checked against
  the network from the machine this was written on. Confirm it on the releases page before
  committing.
* **Sparkle's exact delegate signatures.** `UpdaterController` type-checks against a
  hand-written stand-in for the Sparkle API, not against real headers, because the package
  cannot be resolved here. If the first build after adding the dependency fails, it will
  fail *in the `SPUUpdaterDelegate` extension only*, and the fix is mechanical — Xcode will
  offer the correct Swift spelling of the ObjC selector. The methods implemented are
  `feedParameters(for:sendingSystemProfile:)`, `allowedChannels(for:)`,
  `updaterShouldPromptForPermissionToCheckForUpdates(_:)`, `updater(_:didAbortWithError:)`,
  `updater(_:failedToDownloadUpdate:error:)` and `updaterWillRelaunchApplication(_:)`.
  Every one is optional in the protocol, so deleting any of them compiles — read the
  comment above it first and decide whether you are giving something up.
* **`SPUUpdaterDelegate`'s actor annotation.** Every hook is declared `nonisolated`, which
  is a valid witness whether or not Sparkle annotates the protocol as main-actor, and is
  required if it does not. If a future Sparkle marks the protocol `@MainActor`, the
  `nonisolated` spellings still compile and can be relaxed at leisure.
* **The DMG-mount path of `Scripts/appcast.sh` under CI.** It was exercised locally
  against real UDZO images, single and multiple, stable and prerelease, including the
  cross-check and length-mismatch failure paths. It has not run on a GitHub runner.

What *was* verified: `Sources/App/UpdaterController.swift` compiles under Swift 6 with
`-strict-concurrency=complete` and `ExistentialAny` in **both** branches — with a stub
Sparkle module and without any Sparkle at all — and `swiftlint --strict` is clean on it.
`Scripts/appcast.sh` was run end to end: skip path, missing-`sign_update` failure,
single-DMG feed, two-DMG feed, beta-channel item, version cross-check failure,
length-mismatch failure, and empty-directory failure.
