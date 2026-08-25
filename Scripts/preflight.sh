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
