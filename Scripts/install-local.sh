#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# Build ArcSeven and install it to /Applications, leaving exactly ONE registered copy.
#
# Why this script exists rather than "just run xcodebuild":
#
# Every .app bundle macOS has ever seen gets its own row in
# System Settings > General > Login Items & Extensions, and its extensions are offered
# from THAT path. Building into a scratch derived-data directory and letting the system
# notice it means the user is invited to enable a Finder extension living inside a
# throwaway build folder. During development this produced four duplicate ArcSeven rows,
# with the extensions registered from /private/tmp rather than /Applications.
#
# Deleting the build directory afterwards is NOT enough: Launch Services keeps the
# record, and the stale rows persist. The path has to be unregistered explicitly.
#
# So: build, install, unregister the scratch copy, register the installed one, verify
# exactly one remains.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-Release}"
DERIVED="${ARCSEVEN_DERIVED_DATA:-$REPO_ROOT/.build/xcode-$CONFIG}"
DEST="/Applications/ArcSeven.app"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

step() { printf '\033[34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

step "Generating the Xcode project"
# Always regenerate. A source file added without this builds locally against a stale
# project and then fails for everyone else; it has happened three times.
command -v xcodegen >/dev/null || die "xcodegen not found — brew install xcodegen"
(cd "$REPO_ROOT" && xcodegen generate --quiet)
ok "project regenerated"

step "Building $CONFIG"
# -destination generic/platform=macOS forces a UNIVERSAL build. Without it xcodebuild
# targets the active destination and honours ONLY_ACTIVE_ARCH, silently producing an
# arm64-only binary that fails on Intel.
(cd "$REPO_ROOT" && xcodebuild \
  -project ArcSeven.xcodeproj -scheme ArcSeven -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" build >/dev/null) || die "build failed"
BUILT="$DERIVED/Build/Products/$CONFIG/ArcSeven.app"
[ -d "$BUILT" ] || die "no bundle at $BUILT"
ok "$BUILT"

step "Verifying the signature before installing"
codesign --verify --deep --strict "$BUILT" || die "signature verification failed"
ok "valid, and every nested binary is signed"

step "Installing to $DEST"
pkill -f "ArcSeven.app/Contents/MacOS/ArcSeven" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
ok "installed"

step "Unregistering the build copy so it cannot shadow the installed one"
"$LSREG" -u "$BUILT" 2>/dev/null || true
# Both spellings: /tmp is a symlink to /private/tmp and Launch Services records whichever
# it resolved, so unregistering only one of them leaves the other behind.
"$LSREG" -u "/private${BUILT#/private}" 2>/dev/null || true
"$LSREG" -f "$DEST"
sleep 2
ok "registered $DEST"

step "Verifying exactly one copy is registered"
COUNT="$("$LSREG" -dump 2>/dev/null | grep -oE 'path:[[:space:]]+\S*ArcSeven\.app' | sort -u | wc -l | tr -d ' ')"
"$LSREG" -dump 2>/dev/null | grep -oE 'path:[[:space:]]+\S*ArcSeven\.app' | sed 's/.*  */  /' | sort -u >&2
[ "$COUNT" = "1" ] || die "$COUNT bundles registered; expected 1. Quit System Settings and re-run."
ok "one bundle"

echo >&2
printf '\033[32mArcSeven installed.\033[0m %s\n' "$DEST" >&2
echo "Extensions: $(pluginkit -m 2>/dev/null | grep -c -i arcseven) registered" >&2
echo "If System Settings is open, quit it (Cmd+Q) and reopen — that pane caches." >&2
