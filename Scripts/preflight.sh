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
TEST_OUT="$(swift test 2>&1 || true)"
case "$TEST_OUT" in
  (*"passed after"*)
    ok "$(printf '%s\n' "$TEST_OUT" | grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites passed' | head -1)" ;;
  (*)
    bad "swift test"
    printf '%s\n' "$TEST_OUT" | grep -E "✘|error:" | head -10 ;;
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

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mPreflight passed.\033[0m Safe to push.\n'
else
  printf '\033[31mPreflight FAILED.\033[0m CI would reject this push.\n'
  exit 1
fi
