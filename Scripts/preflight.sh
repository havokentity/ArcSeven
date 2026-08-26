#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# Everything CI checks, run locally, before you push.
#
# CI went red three pushes in a row for a single SwiftLint violation that took one
# command to find. The tooling was installed; it just was not being run. This is that
# command, and Scripts/install-git-hooks.sh wires it to pre-push so remembering is not
# required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAILED=0

step() { printf '\033[34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*"; }
bad()  { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAILED=1; }

step "Regenerating the Xcode project"
# Always. A source file added without this builds locally against a stale project and
# then fails for everyone else — it has happened three times.
if command -v xcodegen >/dev/null; then
  xcodegen generate --quiet && ok "project regenerated"
else
  bad "xcodegen not installed (brew install xcodegen)"
fi

step "swift build"
# Capture rather than pipe into `grep -q`: under pipefail, grep exiting early SIGPIPEs
# the producer and the pipeline reports 141 even on success.
BUILD_OUT="$(swift build 2>&1 || true)"
case "$BUILD_OUT" in (*"Build complete"*) ok "builds" ;; (*) bad "swift build" ;; esac

step "swift test"
# Match the FINAL run summary, not "passed after".
#
# "passed after" appears on every individual SUITE line — including the suites that
# passed inside a run that FAILED. Matching it reported swift test as ok while five
# tests were failing, which is the worst possible bug in a pre-push gate: it does not
# fail loudly, it waves broken code through. The only line that speaks for the whole run
# is "Test run with N tests in M suites passed".
TEST_OUT="$(swift test 2>&1 || true)"
TEST_SUMMARY="$(printf '%s\n' "$TEST_OUT" | grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites (passed|failed)' | tail -1)"
case "$TEST_SUMMARY" in
  (*" passed")
    ok "$TEST_SUMMARY" ;;
  (*" failed")
    bad "$TEST_SUMMARY"
    printf '%s\n' "$TEST_OUT" | grep -E "✘" | head -12 ;;
  (*)
    # No summary at all means the run did not complete — a crash, a hang that was
    # killed, or a compile failure. Never treat an absent summary as success.
    bad "swift test produced no run summary (did it build?)"
    printf '%s\n' "$TEST_OUT" | grep -E "error:|✘" | head -12 ;;
esac

step "swiftlint --strict"
if command -v swiftlint >/dev/null; then
  COUNT="$(swiftlint lint --strict --quiet 2>/dev/null | grep -c ': error:' || true)"
  if [ "$COUNT" = "0" ]; then ok "no violations"
  else
    bad "$COUNT violation(s)"
    swiftlint lint --strict --quiet 2>/dev/null | sed "s|$ROOT/||" | head -15
  fi
else
  bad "swiftlint not installed (brew install swiftlint)"
fi

step "Xcode app build (Debug and Release, unsigned)"
for config in Debug Release; do
  if xcodebuild -project ArcSeven.xcodeproj -scheme ArcSeven -configuration "$config" \
      -derivedDataPath ".build/preflight-$config" \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      build > ".build/preflight-$config.log" 2>&1; then
    ok "$config"
  else
    bad "$config"
    grep -E "error:" ".build/preflight-$config.log" | sort -u | head -10
  fi
done

step "Sparkle configuration lands in the app bundle"
# Sparkle reads its settings from the HOST APP's Info.plist. Through 0.1.1 this whole
# block sat in QuickLookPreview's plist instead, where nothing ever read it: the shipped
# app had no feed URL and could not check for an update even once. Reading project.yml
# would not have caught it - the keys were present and correctly spelled, just attached
# to the wrong target - so this asserts against the BUILT bundle.
SPARKLE_APP=".build/preflight-Release/Build/Products/Release/ArcSeven.app"
if [ -d "$SPARKLE_APP" ]; then
  sparkle_missing=""
  for key in SUPublicEDKey SUFeedURL; do
    if ! /usr/bin/plutil -extract "$key" raw "$SPARKLE_APP/Contents/Info.plist" >/dev/null 2>&1; then
      sparkle_missing="$sparkle_missing $key"
    fi
  done
  # An extension carrying these keys is the symptom of the original bug: they were moved,
  # not copied, so a reappearance means someone put them back on the wrong target.
  sparkle_strays=0
  while IFS= read -r plist; do
    for key in SUPublicEDKey SUFeedURL; do
      if /usr/bin/plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
        sparkle_strays=$((sparkle_strays + 1))
      fi
    done
  done < <(/usr/bin/find "$SPARKLE_APP/Contents/PlugIns" -name Info.plist 2>/dev/null)

  if [ -n "$sparkle_missing" ]; then
    bad "app bundle is missing:$sparkle_missing (auto-update is dead without these)"
  elif [ "$sparkle_strays" -ne 0 ]; then
    bad "$sparkle_strays Sparkle key(s) on an app extension - they belong on the app"
  else
    ok "SUPublicEDKey and SUFeedURL present on the app, absent from extensions"
  fi
else
  bad "no Release bundle to check for Sparkle keys"
fi

step "The updater is wired to something"
# Sparkle.framework shipped in 0.1.0 through 0.1.3 fully configured — embedded, signed,
# with a valid public key and a published appcast — and completely inert: nothing ever
# constructed UpdaterController, and no menu item existed to reach it. Every part looked
# correct in isolation, which is exactly why nobody noticed.
#
# Checked in the SOURCE, because the failure is an absence: there is no symbol to look
# for in the binary that distinguishes "wired" from "compiled but never called".
updater_start=$( (grep -rl "UpdaterController.shared.start()" Sources/App --include='*.swift' 2>/dev/null || true) | wc -l | tr -d ' ')
updater_menu=$( (grep -rl "UpdaterController.checkForUpdates" Sources/App --include='*.swift' 2>/dev/null || true) | wc -l | tr -d ' ')
if [ "$updater_start" -eq 0 ]; then
  bad "nothing calls UpdaterController.shared.start() - the updater never runs"
elif [ "$updater_menu" -eq 0 ]; then
  bad "no menu item targets UpdaterController.checkForUpdates - the user cannot check"
else
  ok "updater started at launch and reachable from the menu"
fi

step "The two FinderRequest copies agree on the wire format"
# FinderRequest.swift exists twice — once for the app, once for the appex — because the
# file has to compile into both targets and Xcode will not share one. Nothing keeps them
# in step, and they have already drifted: the extension gained a `launchURL` the app copy
# never got.
#
# Comments drifting is untidy. The ACTION ENUM drifting is a breakage: the extension writes
# the action as a string and the app decodes it, so a case the reader does not know fails
# the whole decode and the request is dropped on the floor with no error the user can see.
app_cases=$( (grep -oE "^    case [a-z][A-Za-z]*$" Sources/App/FinderRequest.swift || true) | sort)
ext_cases=$( (grep -oE "^    case [a-z][A-Za-z]*$" Extensions/ArcSevenFinder/FinderRequest.swift || true) | sort)
if [ -z "$app_cases" ]; then
  bad "no FinderRequestAction cases found in the app copy - has the file moved?"
elif [ "$app_cases" != "$ext_cases" ]; then
  bad "FinderRequestAction differs between the two copies"
  diff <(printf '%s\n' "$app_cases") <(printf '%s\n' "$ext_cases") | sed 's/^/    /' || true
else
  ok "$(printf '%s\n' "$app_cases" | wc -l | tr -d ' ') actions, identical in both copies"
fi

step "The README test badge matches reality"
# A hand-written count in a public README is a fact with nothing keeping it true: it was
# already two releases stale by 0.1.5, claiming 261 tests in 30 suites against an actual
# 274 in 32. Small, but it is the same drift as every other "two things that must agree"
# bug this script guards, and the README is the first thing anyone reads.
readme_badge="$(grep -oE 'tests-[0-9]+%20in%20[0-9]+%20suites' README.md | head -1)"
# Captured with sed groups, not two greps: the %20 separators contain digits, so
# `grep -oE '[0-9]+%20suites'` happily reads "2032" out of "%2032%20suites".
badge_tests="$(printf '%s' "$readme_badge" | /usr/bin/sed -E 's/^tests-([0-9]+)%20in%20([0-9]+)%20suites$/\1/')"
badge_suites="$(printf '%s' "$readme_badge" | /usr/bin/sed -E 's/^tests-([0-9]+)%20in%20([0-9]+)%20suites$/\2/')"
# Reuses the run from the `swift test` step above rather than paying for a second one.
actual="$(printf '%s' "$TEST_SUMMARY" | grep -oE '[0-9]+ tests in [0-9]+ suites')"
actual_tests="$(printf '%s' "$actual" | awk '{print $1}')"
actual_suites="$(printf '%s' "$actual" | awk '{print $4}')"
if [ -z "$actual_tests" ]; then
  bad "could not read the test count from the swift test output"
elif [ "$badge_tests" != "$actual_tests" ] || [ "$badge_suites" != "$actual_suites" ]; then
  bad "README badge says ${badge_tests:-?} tests in ${badge_suites:-?} suites; actual is $actual_tests in $actual_suites"
  printf '       fix: tests-%s%%20in%%20%s%%20suites\n' "$actual_tests" "$actual_suites"
else
  ok "$actual_tests tests in $actual_suites suites"
fi

step "Every declared Service has a selector behind it"
# The Services menu is built from the plist, and the selector is resolved only when the
# item is clicked — so a name that matches nothing produces a menu item that silently does
# nothing, with no build-time or runtime signal. "Test Archive" and "Checksum" both shipped
# that way. Checked against the BUILT plist, because project.yml is not what LaunchServices
# reads.
services_app=".build/preflight-Release/Build/Products/Release/ArcSeven.app"
if [ -d "$services_app" ]; then
  services_report="$(/usr/bin/python3 - "$services_app/Contents/Info.plist" <<'PYEOF'
import json, subprocess, sys
plist = sys.argv[1]
out = subprocess.run(["plutil", "-extract", "NSServices", "json", "-o", "-", plist],
                     capture_output=True, text=True).stdout
try:
    services = json.loads(out)
except Exception:
    print("ERROR could not read NSServices from the built plist")
    raise SystemExit
source = open("Sources/App/ServicesProvider.swift").read()
dead = [e.get("NSMessage", "") for e in services
        if f"@objc({e.get('NSMessage','')}:userData:error:)" not in source]
print(("DEAD " + " ".join(dead)) if dead else f"OK {len(services)}")
PYEOF
)"
  case "$services_report" in
    OK*)    ok "${services_report#OK } Services, every one backed by a selector" ;;
    DEAD*)  bad "Services with no implementation:${services_report#DEAD}"
            info_line="they appear in the Services menu and do nothing when clicked"
            printf '       %s\n' "$info_line" ;;
    *)      bad "$services_report" ;;
  esac
else
  bad "no Release bundle to check Services against"
fi

# Unregister the throwaway app bundles this script just built.
#
# macOS registers any .app it notices, and each one becomes its own row in
# System Settings > Login Items & Extensions offering ITS copy of the Finder and Quick
# Look extensions. Building two configurations on every push therefore accumulates
# duplicate rows pointing at directories that will be deleted — and the user is invited
# to enable an extension living inside a build folder. Deleting the directory does not
# help: Launch Services keeps the record until the path is explicitly unregistered.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREG" ]; then
  for config in Debug Release; do
    built="$ROOT/.build/preflight-$config/Build/Products/$config/ArcSeven.app"
    # Both spellings: /tmp is a symlink to /private/tmp and LS records whichever it saw.
    "$LSREG" -u "$built" >/dev/null 2>&1 || true
    "$LSREG" -u "/private${built#/private}" >/dev/null 2>&1 || true
  done
fi
rm -rf "$ROOT/.build/preflight-Debug" "$ROOT/.build/preflight-Release"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mPreflight passed.\033[0m Safe to push.\n'
else
  printf '\033[31mPreflight FAILED.\033[0m CI would reject this push.\n'
  exit 1
fi
