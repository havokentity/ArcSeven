#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# sign.sh — inside-out Developer ID code signing for the ArcSeven app bundle.
#
# Signing order is not a style preference: codesign seals a bundle by hashing its
# contents, so anything nested must already carry its final signature before the
# container is signed. We therefore sign:
#
#   1. every nested Mach-O file (bundled 7zz helper, dylibs, Sparkle's Autoupdate…)
#   2. every nested bundle, deepest first (XPC services, Updater.app, frameworks)
#   3. every app extension (.appex), with its own entitlements
#   4. the .app itself, last
#
# NOTE: --deep is used ONLY to verify, never to sign. Deep-signing applies the
# host's entitlements to nested code and silently produces a bundle that will be
# rejected by notarization or will crash a sandboxed appex at launch.
#
# Spawning the bundled 7zz needs NO com.apple.security.cs.* entitlement:
# library validation is satisfied by same-Team-ID signing, and exec of a
# separate process was never gated by library validation in the first place.

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
# Entitlements live next to the code they belong to, not in a central directory:
# Extensions/<Name>/<Name>.entitlements and Sources/App/Resources/ArcSeven.entitlements.
# That is what project.yml points at, so a central copy would be a second source of truth
# that drifts. ENTITLEMENTS_DIR is still honoured as an override and is searched first.
ENTITLEMENTS_DIR="${ENTITLEMENTS_DIR:-}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
DO_VERIFY=1
DO_XATTR_CLEAN=1

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME [options] /path/to/ArcSeven.app

Signs a built app bundle inside-out with the hardened runtime and a secure
timestamp, then verifies the result the way Gatekeeper will.

options:
  -i, --identity <name>      signing identity (default: \$CODESIGN_IDENTITY)
  -e, --entitlements <dir>   directory of <BundleName>.entitlements files
                             (default: $ENTITLEMENTS_DIR)
  -k, --keychain <path>      keychain to search for the identity
      --no-verify            skip the final verification pass
      --keep-xattrs          do not run 'xattr -cr' before signing
  -h, --help                 this text

environment:
  CODESIGN_IDENTITY   default "Developer ID Application: Rajesh DMonte (HAMH7N3PJR)"
  ENTITLEMENTS_DIR    default <repo>/Resources/Entitlements
  CODESIGN_KEYCHAIN   optional keychain path (CI uses an ephemeral keychain)
USAGE
}

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

APP=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--identity)      [ $# -ge 2 ] || die "$1 needs a value"; CODESIGN_IDENTITY="$2"; shift 2 ;;
        -e|--entitlements)  [ $# -ge 2 ] || die "$1 needs a value"; ENTITLEMENTS_DIR="$2";  shift 2 ;;
        -k|--keychain)      [ $# -ge 2 ] || die "$1 needs a value"; CODESIGN_KEYCHAIN="$2"; shift 2 ;;
        --no-verify)        DO_VERIFY=0; shift ;;
        --keep-xattrs)      DO_XATTR_CLEAN=0; shift ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 die "unknown option '$1' (try --help)" ;;
        *)                  [ -z "$APP" ] || die "only one .app path may be given"; APP="$1"; shift ;;
    esac
done

[ -n "$APP" ] || { usage >&2; exit 2; }
APP="${APP%/}"
[ -d "$APP" ] || die "no such bundle: $APP"
case "$APP" in
    *.app) : ;;
    *) die "expected a .app bundle, got: $APP" ;;
esac
[ -f "$APP/Contents/Info.plist" ] || die "not an app bundle (no Contents/Info.plist): $APP"

command -v codesign >/dev/null 2>&1 || die "codesign not found — install the Xcode command line tools"

MAIN_EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$MAIN_EXE" ] || die "Info.plist has no CFBundleExecutable"

# ---------------------------------------------------------------- identity ---
step "Signing identity"
IDENTITY_LIST="$(security find-identity -v -p codesigning ${CODESIGN_KEYCHAIN:+"$CODESIGN_KEYCHAIN"} 2>/dev/null || true)"
if ! printf '%s\n' "$IDENTITY_LIST" | grep -qF "$CODESIGN_IDENTITY"; then
    printf '%s: error: identity not found in the keychain:\n    %s\n\n' \
        "$SCRIPT_NAME" "$CODESIGN_IDENTITY" >&2
    printf 'Available codesigning identities:\n%s\n' "${IDENTITY_LIST:-  (none)}" >&2
    exit 1
fi
info "$CODESIGN_IDENTITY"
[ -n "$CODESIGN_KEYCHAIN" ] && info "keychain: $CODESIGN_KEYCHAIN"

# -------------------------------------------------------------- primitives ---
CODESIGN_BASE_ARGS=(--force --options runtime --timestamp --sign "$CODESIGN_IDENTITY")
[ -n "$CODESIGN_KEYCHAIN" ] && CODESIGN_BASE_ARGS+=(--keychain "$CODESIGN_KEYCHAIN")

SIGNED_COUNT=0

# entitlements_for <bundle-or-file-path> -> echoes a path, or nothing
entitlements_for() {
    local base
    base="$(basename "$1")"
    base="${base%.*}"
    # 1. explicit override directory, when given
    if [ -n "$ENTITLEMENTS_DIR" ] && [ -f "$ENTITLEMENTS_DIR/$base.entitlements" ]; then
        printf '%s' "$ENTITLEMENTS_DIR/$base.entitlements"
        return 0
    fi
    # 2. beside the extension's own sources
    if [ -f "$REPO_ROOT/Extensions/$base/$base.entitlements" ]; then
        printf '%s' "$REPO_ROOT/Extensions/$base/$base.entitlements"
        return 0
    fi
    # 3. the app itself
    if [ -f "$REPO_ROOT/Sources/App/Resources/$base.entitlements" ]; then
        printf '%s' "$REPO_ROOT/Sources/App/Resources/$base.entitlements"
        return 0
    fi
    # 4. last resort: any entitlements file whose name matches, wherever it lives.
    #    Kept as a safety net, but the directory, the product and the entitlements file
    #    are deliberately all named the same thing so it should never be needed.
    local found
    found="$(find "$REPO_ROOT/Extensions" "$REPO_ROOT/Sources" -name "$base.entitlements" 2>/dev/null | head -n 1)"
    if [ -n "$found" ]; then
        printf '%s' "$found"
    fi
}

sign_one() {
    local target="$1"
    local ents="${2:-}"
    local shown
    if [ "$target" = "$APP" ]; then shown="$(basename "$APP")"; else shown="${target#$APP/}"; fi
    local -a args
    args=("${CODESIGN_BASE_ARGS[@]}")
    if [ -n "$ents" ]; then
        args+=(--entitlements "$ents")
        printf '  sign  %-58s  [%s]\n' "$shown" "$(basename "$ents")"
    else
        printf '  sign  %s\n' "$shown"
    fi
    if ! codesign "${args[@]}" "$target"; then
        die "codesign failed on: $target"
    fi
    SIGNED_COUNT=$((SIGNED_COUNT + 1))
}

is_macho() {
    [ -f "$1" ] || return 1
    case "$(file -b -- "$1" 2>/dev/null)" in
        *Mach-O*) return 0 ;;
    esac
    return 1
}

# deepest paths first, so a container is always signed after its contents
deepest_first() { awk -F/ '{ print NF "\t" $0 }' | sort -rn -k1,1 | cut -f2- ; }

# ------------------------------------------------------------------ clean ----
if [ "$DO_XATTR_CLEAN" -eq 1 ]; then
    step "Stripping extended attributes"
    info "xattr -cr (Finder info and quarantine flags make codesign fail)"
    xattr -cr "$APP"
fi

# --------------------------------------------------- 1. nested Mach-O files ---
step "1/4  Nested Mach-O files (helpers, dylibs, embedded tools)"
MACHO_LIST="$(mktemp -t arcseven-macho)"
trap 'rm -f "$MACHO_LIST" "${MACHO_LIST}.sorted" "${BUNDLE_LIST:-}" "${BUNDLE_LIST:-}.sorted" 2>/dev/null || true' EXIT
: > "$MACHO_LIST"
while IFS= read -r f; do
    case "$f" in
        "$APP/Contents/MacOS/$MAIN_EXE") continue ;;   # sealed by the final app signature
        */_CodeSignature/*) continue ;;
    esac
    if is_macho "$f"; then printf '%s\n' "$f" >> "$MACHO_LIST"; fi
done < <(find "$APP/Contents" -type f -print)

if [ -s "$MACHO_LIST" ]; then
    deepest_first < "$MACHO_LIST" > "${MACHO_LIST}.sorted"
    while IFS= read -r f; do sign_one "$f"; done < "${MACHO_LIST}.sorted"
else
    info "(none)"
fi

if [ -x "$APP/Contents/Helpers/7zz" ]; then
    info "bundled 7zz signed with the app's own Team ID — this is what satisfies"
    info "library validation; no com.apple.security.cs.* entitlement is required."
fi

# --------------------------------------- 2. nested bundles, deepest first -----
step "2/4  Nested bundles (XPC services, frameworks, nested apps)"
BUNDLE_LIST="$(mktemp -t arcseven-bundles)"
find "$APP" -mindepth 1 \
     \( -name '*.xpc' -o -name '*.framework' -o -name '*.app' -o -name '*.bundle' -o -name '*.mdimporter' \) \
     -type d -print > "$BUNDLE_LIST" || true

if [ -s "$BUNDLE_LIST" ]; then
    deepest_first < "$BUNDLE_LIST" > "${BUNDLE_LIST}.sorted"
    while IFS= read -r b; do sign_one "$b"; done < "${BUNDLE_LIST}.sorted"
else
    info "(none)"
fi

# ------------------------------------------------------- 3. app extensions ---
step "3/4  App extensions"
FOUND_APPEX=0
if [ -d "$APP/Contents/PlugIns" ]; then
    while IFS= read -r ext; do
        [ -n "$ext" ] || continue
        FOUND_APPEX=1
        ents="$(entitlements_for "$ext")"
        if [ -z "$ents" ]; then
            printf '%s: error: no entitlements for %s\n' "$SCRIPT_NAME" "$(basename "$ext")" >&2
            printf '  App extensions must be sandboxed. Expected:\n    %s\n' \
                   "$ENTITLEMENTS_DIR/$(basename "${ext%.*}").entitlements" >&2
            exit 1
        fi
        sign_one "$ext" "$ents"
    done < <(find "$APP/Contents/PlugIns" -maxdepth 1 -name '*.appex' -type d -print | deepest_first)
fi
[ "$FOUND_APPEX" -eq 1 ] || info "(none)"

# ------------------------------------------------------------ 4. the app -----
step "4/4  The application bundle"
APP_ENTS="$(entitlements_for "$APP")"
if [ -z "$APP_ENTS" ] && [ -f "$ENTITLEMENTS_DIR/ArcSeven.entitlements" ]; then
    APP_ENTS="$ENTITLEMENTS_DIR/ArcSeven.entitlements"
fi
if [ -n "$APP_ENTS" ]; then
    sign_one "$APP" "$APP_ENTS"
else
    info "no entitlements file found — signing without one."
    info "That is correct for ArcSeven: it is not sandboxed, and the hardened"
    info "runtime is a codesign option (--options runtime), not an entitlement."
    sign_one "$APP"
fi

# ------------------------------------------------------------- verify --------
if [ "$DO_VERIFY" -eq 1 ]; then
    step "Verifying"
    codesign --verify --deep --strict --verbose=2 "$APP"

    DISPLAY_OUT="$(codesign --display --verbose=4 "$APP" 2>&1 || true)"
    printf '%s\n' "$DISPLAY_OUT" | grep -q 'flags=.*runtime' \
        || die "hardened runtime flag missing on $APP (expected flags=0x10000(runtime))"
    printf '%s\n' "$DISPLAY_OUT" | grep -q '^Timestamp=' \
        || die "no secure timestamp on $APP — notarization would reject it"

    info "hardened runtime: $(printf '%s\n' "$DISPLAY_OUT" | sed -n 's/.*\(flags=[^ ]*\).*/\1/p' | head -n1)"
    info "team:             $(printf '%s\n' "$DISPLAY_OUT" | sed -n 's/^TeamIdentifier=//p' | head -n1)"
    info "timestamp:        $(printf '%s\n' "$DISPLAY_OUT" | sed -n 's/^Timestamp=//p' | head -n1)"

    if [ -x "$APP/Contents/Helpers/7zz" ]; then
        HELPER_OUT="$(codesign --display --verbose=4 "$APP/Contents/Helpers/7zz" 2>&1 || true)"
        printf '%s\n' "$HELPER_OUT" | grep -q 'flags=.*runtime' \
            || die "bundled 7zz is missing the hardened runtime"
        info "7zz team:         $(printf '%s\n' "$HELPER_OUT" | sed -n 's/^TeamIdentifier=//p' | head -n1)"
    fi
fi

printf '\nSigned %d nested item(s) plus the app bundle.\n' "$((SIGNED_COUNT - 1))"
printf 'Next:  Scripts/notarize.sh "%s"\n' "$APP"
