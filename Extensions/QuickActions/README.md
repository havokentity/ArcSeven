<!-- SPDX-License-Identifier: Apache-2.0 -->
# QuickActions (not built)

This extension is **not in the build**. It has an `Info.plist` and entitlements but no
code, and an app extension with no executable is worse than no extension: it cannot carry
entitlements (`codesign -d --entitlements` returns nothing for it), so
`Scripts/verify-release.sh` correctly fails it with "QuickActions.appex is NOT sandboxed",
and it ships dead weight inside the bundle that the system may still try to load.

It was found this way by dry-running the release pipeline before a first release, rather
than during one.

The intent is Finder **Quick Actions** via App Intents — "Compress with ArcSeven" in the
Quick Actions submenu and in Shortcuts, alongside the Finder Sync extension that already
provides the top-level context menu.

To bring it back: add the `AppIntent` implementations here, then restore the target block
in `project.yml` (see git history for the removed block) and re-add it to the app's
`dependencies` with `embed: true`.
