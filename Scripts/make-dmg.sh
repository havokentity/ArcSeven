#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# make-dmg.sh — build the distributable disk image for ArcSeven.
#
# Uses create-dmg when it is installed (window layout, icon positions, optional
# background) and falls back to plain hdiutil otherwise. Both paths produce the
# same contents:
#
#   ArcSeven.app          the signed application
#   Applications ->    symlink, so the drag-to-install gesture works
#   Legal/             LICENSE, NOTICE and THIRD_PARTY_LICENSES
#
# The Legal folder is not decoration. 7-Zip's license.txt requires binary
# redistributions to reproduce its license information, and someone who receives
# only the DMG must be able to read every notice without visiting GitHub.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Accept SIGN_IDENTITY as an alias for CODESIGN_IDENTITY.
#
# release.yml exports SIGN_IDENTITY while this script reads CODESIGN_IDENTITY. The
# mismatch went unnoticed because the default below happens to be the correct identity on
# the maintainer's machine: the step "passed" while silently ignoring what the workflow
# told it. That would break for any other signer, and would hide the default drifting out
# of date. Prefer an explicit value from either spelling; fall back to the default only
# when neither is set.
: "${CODESIGN_IDENTITY:=${SIGN_IDENTITY:-}}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Rajesh DMonte (HAMH7N3PJR)}"
SKIP_DMG_SIGN="${SKIP_DMG_SIGN:-0}"

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME /path/to/ArcSeven.app [output.dmg]

Creates a compressed, signed disk image containing the app, an /Applications
symlink and the legal notices.

environment:
  DMG_VOLUME_NAME    volume name (default: "<CFBundleName> <version>")
  CODESIGN_IDENTITY  identity used to sign the finished image
  SKIP_DMG_SIGN=1    do not sign the image (local testing only)
USAGE
}

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
esac

APP="${1%/}"
DMG="${2:-}"

[ -d "$APP" ] || die "no such bundle: $APP"
case "$APP" in *.app) : ;; *) die "expected a .app bundle, got: $APP" ;; esac
[ -f "$APP/Contents/Info.plist" ] || die "not an app bundle: $APP"

APP_BASENAME="$(basename "$APP")"

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }

APP_NAME="$(plist_value CFBundleName)"
[ -n "$APP_NAME" ] || APP_NAME="${APP_BASENAME%.app}"
VERSION="$(plist_value CFBundleShortVersionString)"
[ -n "$VERSION" ] || die "Info.plist has no CFBundleShortVersionString"
BUILD="$(plist_value CFBundleVersion)"

VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME $VERSION}"
[ -n "$DMG" ] || DMG="$(cd -- "$(dirname -- "$APP")" && pwd)/${APP_NAME}-${VERSION}.dmg"

# Trademark posture: nominative use only. "7-Zip" must never appear in the
# product identifier, and the volume name is a product identifier.
if printf '%s' "$VOLUME_NAME" | grep -Eqi '7[-_ ]?zip'; then
    die "volume name '$VOLUME_NAME' contains '7-Zip'. The volume name is a product identifier; keep 7-Zip out of it."
fi

step "Input"
info "app:      $APP"
info "name:     $APP_NAME"
info "version:  $VERSION${BUILD:+ (build $BUILD)}"
info "volume:   $VOLUME_NAME"
info "output:   $DMG"

# ------------------------------------------------- refuse to ship unsigned ---
step "Checking the app signature"
codesign --verify --strict --verbose=2 "$APP" \
    || die "the app is not validly signed — run Scripts/sign.sh before building the image"
# Capture first, then test. Piping a slow producer into `grep -q` is a trap under
# `set -o pipefail`: grep exits the instant it matches, the write end SIGPIPEs codesign,
# and the pipeline reports 141 — so a CORRECT signature is reported as a missing hardened
# runtime. This exact line blocked every release until it was traced.
APP_SIGN_INFO="$(codesign --display --verbose=2 "$APP" 2>&1 || true)"
case "$APP_SIGN_INFO" in
    *"flags="*runtime*) ;;
    *) die "the app is signed without the hardened runtime — notarization would reject it" ;;
esac
info "signature and hardened runtime OK"

# ------------------------------------------------------------- staging ------
step "Staging the image contents"
STAGE="$(mktemp -d -t arcseven-dmg)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ditto "$APP" "$STAGE/$APP_BASENAME"          # ditto preserves the signature and xattrs
ln -s /Applications "$STAGE/Applications"
info "$APP_BASENAME"
info "Applications -> /Applications"

INCLUDED_LEGAL=0
if [ -f "$REPO_ROOT/LICENSE" ] || [ -f "$REPO_ROOT/NOTICE" ] || [ -d "$REPO_ROOT/THIRD_PARTY_LICENSES" ]; then
    mkdir -p "$STAGE/Legal"
    [ -f "$REPO_ROOT/LICENSE" ] && cp "$REPO_ROOT/LICENSE" "$STAGE/Legal/LICENSE.txt"
    [ -f "$REPO_ROOT/NOTICE" ]  && cp "$REPO_ROOT/NOTICE"  "$STAGE/Legal/NOTICE.txt"
    if [ -d "$REPO_ROOT/THIRD_PARTY_LICENSES" ]; then
        ditto "$REPO_ROOT/THIRD_PARTY_LICENSES" "$STAGE/Legal/THIRD_PARTY_LICENSES"
    fi
    INCLUDED_LEGAL=1
    info "Legal/ (LICENSE, NOTICE, THIRD_PARTY_LICENSES)"
else
    printf '%s: warning: no LICENSE/NOTICE/THIRD_PARTY_LICENSES in %s — the image will\n' \
           "$SCRIPT_NAME" "$REPO_ROOT" >&2
    printf '  ship without the notices 7-Zip'"'"'s license.txt requires. Fix before release.\n' >&2
fi

rm -f "$DMG"

# ------------------------------------------------------------ create-dmg ----
USED_CREATE_DMG=0
CREATE_DMG_USABLE=0
if command -v create-dmg >/dev/null 2>&1; then
    # Two unrelated tools ship as "create-dmg". Only the flag-driven one
    # (create-dmg/create-dmg) understands --volname; the node one does not.
    CDG_HELP="$(create-dmg --help 2>&1 || true)"
    if printf '%s\n' "$CDG_HELP" | grep -q -- '--volname'; then
        CREATE_DMG_USABLE=1
    else
        info "create-dmg found, but not the flag-driven variant — using hdiutil"
    fi
fi

if [ "$CREATE_DMG_USABLE" -eq 1 ]; then
    step "Building with create-dmg"
    CDG=(--volname "$VOLUME_NAME"
         --window-pos 200 120
         --window-size 640 400
         --icon-size 128
         --icon "$APP_BASENAME" 160 185
         --hide-extension "$APP_BASENAME"
         --app-drop-link 480 185
         --no-internet-enable)
    [ "$INCLUDED_LEGAL" -eq 1 ] && CDG+=(--icon "Legal" 320 320)
    [ -f "$REPO_ROOT/Resources/DMG/background.png" ] && CDG+=(--background "$REPO_ROOT/Resources/DMG/background.png")
    [ -f "$REPO_ROOT/Resources/DMG/volume.icns" ]    && CDG+=(--volicon "$REPO_ROOT/Resources/DMG/volume.icns")

    if create-dmg "${CDG[@]}" "$DMG" "$STAGE"; then
        USED_CREATE_DMG=1
    else
        printf '%s: warning: create-dmg failed (it drives Finder via AppleScript and is\n' "$SCRIPT_NAME" >&2
        printf '  unreliable on headless CI runners); falling back to hdiutil.\n' >&2
        rm -f "$DMG"
    fi
fi

# --------------------------------------------------------- hdiutil fallback --
if [ "$USED_CREATE_DMG" -eq 0 ]; then
    step "Building with hdiutil"
    hdiutil create \
        -volname "$VOLUME_NAME" \
        -srcfolder "$STAGE" \
        -fs HFS+ \
        -format UDZO -imagekey zlib-level=9 \
        -ov "$DMG"
fi

[ -f "$DMG" ] || die "image was not produced: $DMG"

# --------------------------------------------------------------- sign -------
if [ "$SKIP_DMG_SIGN" = "1" ]; then
    step "Skipping image signature (SKIP_DMG_SIGN=1)"
    printf '%s: warning: an unsigned image cannot be notarized.\n' "$SCRIPT_NAME" >&2
else
    step "Signing the image"
    # Same SIGPIPE hazard as above: capture, then match.
    DMG_IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    if ! printf '%s\n' "$DMG_IDENTITY_LIST" | grep -qF "$CODESIGN_IDENTITY"; then
        die "identity not found in the keychain: $CODESIGN_IDENTITY"
    fi
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
fi

# ------------------------------------------------------------- report -------
step "Result"
SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
info "path:    $DMG"
info "size:    $SIZE"
info "sha256:  $SHA"
printf '\nHomebrew cask stanza:\n'
printf '  version "%s"\n' "$VERSION"
printf '  sha256 "%s"\n' "$SHA"
printf '\nNext:  Scripts/notarize.sh "%s"\n' "$DMG"
