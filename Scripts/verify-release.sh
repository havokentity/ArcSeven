#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# verify-release.sh — the gate that runs before anything is published.
#
# It answers two questions:
#
#   1. Will this launch on a stranger's Mac?   signature, hardened runtime,
#      Team ID on every Mach-O, Gatekeeper assessment, stapled ticket.
#   2. Are we allowed to ship it?              LICENSE, NOTICE and
#      THIRD_PARTY_LICENSES inside the bundle, the unRAR statement, the
#      recorded provenance of the bundled 7zz, and the trademark posture.
#
# Exits non-zero if any check fails. Warnings are reported but do not fail the
# run; read them anyway.
#
# usage:  verify-release.sh ArcSeven.app
#         verify-release.sh ArcSeven-1.0.0.dmg
#         verify-release.sh ArcSeven.app ArcSeven-1.0.0.dmg

set -euo pipefail

# sandbox_state <entitlements-xml> -> "on" | "off" | "absent"
#
# Greping for the key name alone is wrong in both directions: the main app DECLARES
# com.apple.security.app-sandbox and sets it to <false/>, which a name-only match reports
# as sandboxed; and an extension could ship the key set to false and be reported as
# correctly sandboxed. Read the value.
sandbox_state() {
    local ents="$1" tmp state
    case "$ents" in
        *com.apple.security.app-sandbox*) ;;
        *) printf 'absent'; return 0 ;;
    esac
    tmp="$(mktemp -t arcseven-ents)"
    printf '%s' "$ents" > "$tmp"
    # PlistBuddy, not `plutil -extract`. plutil treats "." as a KEY-PATH SEPARATOR, so
    # `-extract com.apple.security.app-sandbox` looks for a nested com > apple > security
    # dictionary and reports "No value at that key path" for a key that is plainly there.
    # PlistBuddy separates with ":" and so handles dotted key names literally.
    state="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$tmp" 2>/dev/null || true)"
    rm -f "$tmp"
    case "$state" in
        true|1|YES) printf 'on' ;;
        false|0|NO) printf 'off' ;;
        *) printf 'absent' ;;
    esac
}


SCRIPT_NAME="$(basename "$0")"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

TEAM_ID="${TEAM_ID:-HAMH7N3PJR}"
BUNDLE_ID_PREFIX="${BUNDLE_ID_PREFIX:-com.havokentity.ArcSeven}"
ALLOW_UNNOTARIZED="${ALLOW_UNNOTARIZED:-0}"
UNRAR_CLAUSE="MAY NOT BE USED TO DEVELOP A RAR"

FAILURES=0
WARNINGS=0
MOUNT_DEV=""

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME <ArcSeven.app | release.dmg> [release.dmg]

environment:
  TEAM_ID             expected Team Identifier (default $TEAM_ID)
  BUNDLE_ID_PREFIX    expected bundle identifier root (default $BUNDLE_ID_PREFIX)
  ALLOW_UNNOTARIZED=1 downgrade notarization/Gatekeeper checks to warnings,
                      for verifying a build before it has been submitted
USAGE
}

if [ -t 1 ]; then
    C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_OK=""; C_BAD=""; C_WARN=""; C_DIM=""; C_OFF=""
fi

section() { printf '\n%s== %s %s\n' "$C_DIM" "$*" "$C_OFF"; }
pass()    { printf '  %sPASS%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
fail()    { printf '  %sFAIL%s  %s\n' "$C_BAD" "$C_OFF" "$*"; FAILURES=$((FAILURES + 1)); }
warn()    { printf '  %sWARN%s  %s\n' "$C_WARN" "$C_OFF" "$*"; WARNINGS=$((WARNINGS + 1)); }
note()    { printf '        %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }
die()     { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 2; }

# A check that is fatal normally, but only a warning when we are deliberately
# inspecting a build that has not been through the notary service yet.
gate() {
    if [ "$ALLOW_UNNOTARIZED" = "1" ]; then warn "$* (ALLOW_UNNOTARIZED=1)"; else fail "$*"; fi
}

cleanup() {
    if [ -n "$MOUNT_DEV" ]; then
        hdiutil detach "$MOUNT_DEV" -quiet >/dev/null 2>&1 || hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
        MOUNT_DEV=""
    fi
}
trap cleanup EXIT

is_macho() {
    [ -f "$1" ] || return 1
    case "$(file -b -- "$1" 2>/dev/null)" in *Mach-O*) return 0 ;; esac
    return 1
}

macho_uuids() {
    # LC_UUID survives codesign, so it is how we prove that the signed copy in
    # the bundle is bit-for-bit the same build as the pristine vendored one.
    { dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2}' | sort | tr '\n' ' '; } || true
}

# =============================================================== app checks ==
check_app() {
    local app="$1" label="$2"
    local plist="$app/Contents/Info.plist"

    section "$label — bundle sanity"
    if [ -f "$plist" ]; then pass "Info.plist present"; else fail "no Contents/Info.plist in $app"; return; fi

    local bundle_id name display version build
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" 2>/dev/null || true)"
    display="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist" 2>/dev/null || true)"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true)"
    build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || true)"
    note "id=$bundle_id  name=$name  version=$version  build=$build"

    case "$bundle_id" in
        "$BUNDLE_ID_PREFIX") pass "bundle identifier is $BUNDLE_ID_PREFIX" ;;
        "$BUNDLE_ID_PREFIX".*) pass "bundle identifier is under $BUNDLE_ID_PREFIX" ;;
        *) fail "bundle identifier '$bundle_id' is not under $BUNDLE_ID_PREFIX" ;;
    esac
    [ -n "$version" ] || fail "CFBundleShortVersionString is empty"
    [ -n "$build" ] || fail "CFBundleVersion is empty (Sparkle compares this, not the marketing version)"

    # Trademark posture: nominative use only, never in the identifier position.
    local ident_field bad_ident=0
    for ident_field in "$bundle_id" "$name" "$display" "$(basename "$app")"; do
        if printf '%s' "$ident_field" | grep -Eqi '7[-_ ]?zip'; then
            fail "'$ident_field' puts \"7-Zip\" in a product-identifier position"
            bad_ident=1
        fi
    done
    [ "$bad_ident" -eq 0 ] && pass "no \"7-Zip\" in the app name, display name or bundle identifier"

    # ------------------------------------------------------- code signature --
    section "$label — code signature"
    local cs_out cs_rc=0
    cs_out="$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)" || cs_rc=$?
    if [ "$cs_rc" -eq 0 ]; then
        printf '%s\n' "$cs_out" | grep -E 'valid on disk|Designated Requirement' | sed 's/^/        /' || true
        pass "codesign --verify --deep --strict --verbose=2"
    else
        printf '%s\n' "$cs_out" | sed 's/^/        /'
        fail "codesign --verify --deep --strict failed (exit $cs_rc)"
    fi

    local disp
    disp="$(codesign --display --verbose=4 "$app" 2>&1 || true)"
    if printf '%s\n' "$disp" | grep -q 'flags=.*runtime'; then
        pass "hardened runtime enabled on the app"
    else
        fail "hardened runtime NOT enabled on the app (need --options runtime)"
    fi
    if printf '%s\n' "$disp" | grep -q '^Timestamp='; then
        pass "secure timestamp present"
    else
        fail "no secure timestamp (need --timestamp) — the notary service rejects this"
    fi
    if printf '%s\n' "$disp" | grep -q "^TeamIdentifier=$TEAM_ID\$"; then
        pass "Team Identifier is $TEAM_ID"
    else
        fail "unexpected Team Identifier: $(printf '%s\n' "$disp" | sed -n 's/^TeamIdentifier=//p' | head -n1)"
    fi
    if printf '%s\n' "$disp" | grep -q 'Authority=Developer ID Application'; then
        pass "signed with a Developer ID Application certificate"
    else
        fail "not signed with a Developer ID Application certificate"
    fi

    # Every Mach-O in the bundle, not just the app: this is what notarization
    # actually checks, one binary at a time.
    section "$label — every nested Mach-O"
    local total=0 bad=0 f d
    while IFS= read -r f; do
        case "$f" in */_CodeSignature/*) continue ;; esac
        is_macho "$f" || continue
        total=$((total + 1))
        d="$(codesign --display --verbose=4 "$f" 2>&1 || true)"
        if ! printf '%s\n' "$d" | grep -q "^TeamIdentifier=$TEAM_ID\$"; then
            fail "wrong or missing Team ID: ${f#$app/}"
            bad=$((bad + 1)); continue
        fi
        if ! printf '%s\n' "$d" | grep -q 'flags=.*runtime'; then
            fail "no hardened runtime: ${f#$app/}"
            bad=$((bad + 1)); continue
        fi
        if ! printf '%s\n' "$d" | grep -q '^Timestamp='; then
            fail "no secure timestamp: ${f#$app/}"
            bad=$((bad + 1)); continue
        fi
    done < <(find "$app/Contents" -type f -print)
    if [ "$bad" -eq 0 ]; then
        pass "$total Mach-O file(s): all signed by $TEAM_ID, hardened, timestamped"
    fi

    # ------------------------------------------------------------- universal --
    section "$label — architectures"
    local main_exe main_path archs
    main_exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
    main_path="$app/Contents/MacOS/$main_exe"
    if [ -f "$main_path" ]; then
        archs="$(lipo -archs "$main_path" 2>/dev/null || true)"
        if printf '%s' "$archs" | grep -q arm64 && printf '%s' "$archs" | grep -q x86_64; then
            pass "main executable is universal ($archs)"
        else
            fail "main executable is not universal (got: ${archs:-unknown}, need arm64 + x86_64)"
        fi
    else
        fail "main executable missing: $main_path"
    fi

    # --------------------------------------------------------- bundled 7zz ---
    section "$label — bundled 7-Zip engine"
    local helper="$app/Contents/Helpers/7zz"
    if [ -f "$helper" ]; then
        pass "Contents/Helpers/7zz present"
        [ -x "$helper" ] && pass "7zz is executable" || fail "7zz is not executable"
        archs="$(lipo -archs "$helper" 2>/dev/null || true)"
        if printf '%s' "$archs" | grep -q arm64 && printf '%s' "$archs" | grep -q x86_64; then
            pass "7zz is universal ($archs)"
        else
            fail "7zz is not universal (got: ${archs:-unknown})"
        fi
    else
        fail "Contents/Helpers/7zz missing — the app has no engine"
    fi

    # ------------------------------------------------------- entitlements ----
    section "$label — entitlements"
    local ents
    ents="$(codesign --display --entitlements :- "$app" 2>/dev/null || true)"
    if printf '%s' "$ents" | grep -q 'com.apple.security.cs\.'; then
        warn "the app declares com.apple.security.cs.* entitlements:"
        { printf '%s\n' "$ents" | grep -o 'com\.apple\.security\.cs\.[a-z-]*' | sort -u | sed 's/^/          /'; } || true
        note "None are needed to spawn the bundled 7zz: library validation is"
        note "satisfied because the helper carries the same Team ID, and exec of a"
        note "separate process was never gated by library validation. Remove them."
    else
        pass "no com.apple.security.cs.* entitlements (correct — same-Team-ID signing is enough)"
    fi
    case "$(sandbox_state "$ents")" in
        on)  warn "the main app is sandboxed — arbitrary-directory browsing will not work" ;;
        *)   pass "main app is not sandboxed (required for a two-pane file manager)" ;;
    esac

    local ext ext_ents appex_count=0
    if [ -d "$app/Contents/PlugIns" ]; then
        while IFS= read -r ext; do
            [ -n "$ext" ] || continue
            appex_count=$((appex_count + 1))
            ext_ents="$(codesign --display --entitlements :- "$ext" 2>/dev/null || true)"
            case "$(sandbox_state "$ext_ents")" in
                on) pass "$(basename "$ext") is sandboxed" ;;
                off) fail "$(basename "$ext") declares app-sandbox but sets it FALSE" ;;
                *)  fail "$(basename "$ext") is NOT sandboxed — app extensions must be" ;;
            esac
        done < <(find "$app/Contents/PlugIns" -maxdepth 1 -name '*.appex' -type d -print)
    fi
    [ "$appex_count" -eq 0 ] && note "no app extensions in this build"

    # -------------------------------------------------------- Gatekeeper -----
    section "$label — Gatekeeper and notarization"
    local spctl_out
    spctl_out="$(spctl --assess -vvv --type exec "$app" 2>&1 || true)"
    printf '%s\n' "$spctl_out" | sed 's/^/        /'
    if printf '%s\n' "$spctl_out" | grep -q 'source=Notarized Developer ID'; then
        pass "spctl -a -vvv -t exec: source=Notarized Developer ID"
    elif printf '%s\n' "$spctl_out" | grep -q 'accepted'; then
        gate "spctl accepted the app but it is not reported as notarized"
    else
        gate "spctl rejected the app"
    fi

    if xcrun stapler validate "$app" >/dev/null 2>&1; then
        pass "stapler validate: ticket is stapled to the app"
    else
        gate "stapler validate failed — the app has no stapled ticket (first launch offline will fail)"
    fi

    # --------------------------------------------------------- compliance ----
    section "$label — compliance"
    local legal="$app/Contents/Resources/Legal"
    if [ -d "$legal" ]; then
        pass "Contents/Resources/Legal/ present"
    else
        fail "Contents/Resources/Legal/ missing — a DMG-only recipient can read no notices"
    fi

    local required="LICENSE NOTICE"
    local item
    for item in $required; do
        if [ -f "$legal/$item" ] || [ -f "$legal/$item.txt" ]; then
            pass "Legal/$item present"
        else
            fail "Legal/$item missing"
        fi
    done

    if [ -d "$legal/THIRD_PARTY_LICENSES" ]; then
        pass "Legal/THIRD_PARTY_LICENSES/ present"
        for item in 7-Zip/LICENSE.txt 7-Zip/LGPL-2.1.txt 7-Zip/VERSION.txt; do
            if [ -f "$legal/THIRD_PARTY_LICENSES/$item" ]; then
                pass "Legal/THIRD_PARTY_LICENSES/$item present"
            else
                fail "Legal/THIRD_PARTY_LICENSES/$item missing"
            fi
        done
    else
        fail "Legal/THIRD_PARTY_LICENSES/ missing"
    fi

    if [ -f "$legal/LICENSE" ] && grep -q 'GNU GENERAL PUBLIC LICENSE' "$legal/LICENSE" 2>/dev/null; then
        pass "Legal/LICENSE is the GPL text"
    elif [ -f "$legal/LICENSE.txt" ] && grep -q 'GNU GENERAL PUBLIC LICENSE' "$legal/LICENSE.txt" 2>/dev/null; then
        pass "Legal/LICENSE.txt is the GPL text"
    else
        fail "Legal/LICENSE does not contain the GNU General Public License text"
    fi

    # unRAR: the restriction must be stated "in the documentation", which for a
    # shipped app means text the user can actually read.
    if grep -R -q -- "$UNRAR_CLAUSE" "$legal" 2>/dev/null; then
        pass "unRAR restriction present in Legal/"
    else
        fail "unRAR restriction not found in Legal/ (\"$UNRAR_CLAUSE\")"
    fi
    if grep -R -q --exclude-dir=Legal -- "$UNRAR_CLAUSE" "$app/Contents/Resources" 2>/dev/null; then
        pass "unRAR restriction reachable from the app's own resources"
    else
        warn "unRAR clause not found outside Legal/ — confirm the Acknowledgements pane renders Legal/NOTICE"
        note "(rendering the shipped NOTICE file in the pane satisfies the requirement)"
    fi

    # Provenance of the bundled engine.
    local vfile="$legal/THIRD_PARTY_LICENSES/7-Zip/VERSION.txt"
    if [ -f "$vfile" ]; then
        # vendor/bin/7zz, not vendor/7zz/7zz. The latter has never existed: the binary is
        # COMPILED to vendor/bin/ by vendor/build-7zz.sh, and vendor/bin/.gitignore is `*`.
        # So this whole block used to take the `else` branch and warn, every single time —
        # a compliance gate that could not fire, guarding the LGPL source offer.
        local recorded_ver recorded_commit vendor="$REPO_ROOT/vendor/bin/7zz"
        recorded_ver="$(sed -n 's/^7-Zip version:[[:space:]]*//p' "$vfile" | head -n1 || true)"
        recorded_commit="$(sed -n 's/^Upstream commit:[[:space:]]*//p' "$vfile" | head -n1 || true)"
        note "VERSION.txt records 7-Zip ${recorded_ver:-<unrecorded>}"
        if [ -z "$recorded_ver" ]; then fail "VERSION.txt has no '7-Zip version:' line"; fi

        # Reject placeholders as well as blanks. The file shipped for five releases with
        # "FILLED BY Scripts/refresh-third-party-licenses.sh" where the checksums belong,
        # and the old check passed it because a placeholder is not an empty string.
        if grep -qiE '^(Binary|Source|License) SHA-256:.*(FILLED BY|TODO|TBD|XXX|PLACEHOLDER)' "$vfile"; then
            fail "VERSION.txt still contains a placeholder where a value belongs"
            grep -inE '^(Binary|Source|License) SHA-256:' "$vfile" | sed 's/^/        /'
        fi

        # The commit is what makes binary and source correspond, so it is the thing worth
        # checking. A hash of the binary would not survive being rebuilt per release.
        if [ -z "$recorded_commit" ]; then
            fail "VERSION.txt has no 'Upstream commit:' line — nothing anchors the source offer"
        else
            local pinned
            pinned="$(git -C "$REPO_ROOT" submodule status vendor/7zip 2>/dev/null \
                | awk '{gsub(/^[-+U]/, "", $1); print $1}')"
            if [ -z "$pinned" ]; then
                warn "submodule vendor/7zip is not checked out — cannot confirm the recorded commit"
            elif [ "$pinned" = "$recorded_commit" ]; then
                pass "VERSION.txt commit matches the pinned submodule ($recorded_commit)"
            else
                fail "VERSION.txt records $recorded_commit but the submodule is pinned at $pinned"
            fi
        fi

        # LC_UUID survives codesign, so it is the honest way to show the shipped engine is
        # the binary that was built here.
        if [ -f "$vendor" ] && [ -f "$helper" ]; then
            local u_vendor u_bundled
            u_vendor="$(macho_uuids "$vendor")"
            u_bundled="$(macho_uuids "$helper")"
            if [ -z "$u_vendor" ] || [ -z "$u_bundled" ]; then
                warn "could not read Mach-O UUIDs (dwarfdump unavailable?) — skipping the comparison"
            elif [ "$u_vendor" = "$u_bundled" ]; then
                pass "bundled 7zz has the same Mach-O UUIDs as vendor/bin/7zz"
            else
                fail "bundled 7zz is not the built binary (UUID mismatch: '$u_bundled' vs '$u_vendor')"
            fi
        elif [ ! -f "$vendor" ]; then
            warn "vendor/bin/7zz not built — run ./vendor/build-7zz.sh to enable the UUID check"
        fi
        if grep -qi '^Modifications:[[:space:]]*NONE' "$vfile"; then
            pass "VERSION.txt asserts 'Modifications: NONE'"
        else
            fail "VERSION.txt must state 'Modifications: NONE' — it is the evidence that 7zz is not a derivative work"
        fi
    fi
}

# =============================================================== dmg checks ==
check_dmg() {
    local dmg="$1"

    section "$(basename "$dmg") — disk image"
    local dmg_cs dmg_rc=0
    dmg_cs="$(codesign --verify --strict --verbose=2 "$dmg" 2>&1)" || dmg_rc=$?
    printf '%s\n' "$dmg_cs" | sed 's/^/        /'
    if [ "$dmg_rc" -eq 0 ]; then
        pass "the image itself is signed"
    else
        fail "the image is not validly signed (exit $dmg_rc)"
    fi

    local spctl_out
    spctl_out="$(spctl --assess -vvv --type install "$dmg" 2>&1 || true)"
    printf '%s\n' "$spctl_out" | sed 's/^/        /'
    if printf '%s\n' "$spctl_out" | grep -q 'source=Notarized Developer ID'; then
        pass "spctl -a -vvv -t install: source=Notarized Developer ID"
    else
        gate "spctl -a -vvv -t install did not report a notarized Developer ID image"
    fi

    if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
        pass "stapler validate: ticket is stapled to the image"
    else
        gate "stapler validate failed on the image"
    fi

    section "$(basename "$dmg") — contents"
    local attach_out mount_point
    attach_out="$(hdiutil attach -nobrowse -readonly -noautoopen "$dmg" 2>&1 || true)"
    mount_point="$(printf '%s\n' "$attach_out" | grep -o '/Volumes/.*' | head -n1 || true)"
    MOUNT_DEV="$(printf '%s\n' "$attach_out" | awk '/\/Volumes\//{print $1; exit}' || true)"
    if [ -z "$mount_point" ] || [ ! -d "$mount_point" ]; then
        fail "could not mount the image"
        printf '%s\n' "$attach_out" | sed 's/^/        /'
        return
    fi
    pass "mounted at $mount_point"

    local volname
    volname="$(basename "$mount_point")"
    if printf '%s' "$volname" | grep -Eqi '7[-_ ]?zip'; then
        fail "volume name '$volname' contains \"7-Zip\" — that is a product-identifier position"
    else
        pass "volume name '$volname' keeps 7-Zip out of the identifier"
    fi

    if [ -L "$mount_point/Applications" ]; then
        pass "/Applications symlink present (drag-to-install works)"
    else
        fail "no /Applications symlink in the image"
    fi

    if [ -d "$mount_point/Legal" ]; then
        pass "Legal/ folder present in the image"
    else
        warn "no Legal/ folder in the image — 7-Zip's license.txt asks binary redistributions to reproduce its license information"
    fi

    local inner
    inner="$(find "$mount_point" -maxdepth 1 -name '*.app' -type d -print | head -n1 || true)"
    if [ -n "$inner" ]; then
        check_app "$inner" "$(basename "$inner") (inside the image)"
    else
        fail "no .app found at the top level of the image"
    fi

    cleanup
}

# ==================================================================== main ===
case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac

command -v codesign >/dev/null 2>&1 || die "codesign not found — install the Xcode command line tools"
command -v spctl >/dev/null 2>&1 || die "spctl not found"

APP_ARG=""
DMG_ARG=""
for arg in "$@"; do
    a="${arg%/}"
    [ -e "$a" ] || die "no such file: $a"
    case "$a" in
        *.app) [ -z "$APP_ARG" ] || die "only one .app may be given"; APP_ARG="$a" ;;
        *.dmg) [ -z "$DMG_ARG" ] || die "only one .dmg may be given"; DMG_ARG="$a" ;;
        *)     die "unsupported argument: $a (expected .app and/or .dmg)" ;;
    esac
done

printf '%s\n' "ArcSeven release verification"
printf '  team id:        %s\n' "$TEAM_ID"
printf '  bundle prefix:  %s\n' "$BUNDLE_ID_PREFIX"
[ "$ALLOW_UNNOTARIZED" = "1" ] && printf '  %sALLOW_UNNOTARIZED=1 — notarization failures are downgraded to warnings%s\n' "$C_WARN" "$C_OFF"

[ -n "$APP_ARG" ] && check_app "$APP_ARG" "$(basename "$APP_ARG")"
[ -n "$DMG_ARG" ] && check_dmg "$DMG_ARG"

section "Summary"
printf '  %d failure(s), %d warning(s)\n' "$FAILURES" "$WARNINGS"
if [ "$FAILURES" -gt 0 ]; then
    printf '\n%sDO NOT PUBLISH.%s Fix every FAIL above and re-run.\n' "$C_BAD" "$C_OFF"
    exit 1
fi
printf '\n%sClear to publish.%s Remember the release itself must also carry:\n' "$C_OK" "$C_OFF"
printf '  * the 7-Zip SOURCE TARBALL as an asset on the SAME release as the DMG\n'
printf '    (LGPL-2.1 section 4: equivalent access to the source from the same place)\n'
printf '  * a signed git tag, so the Corresponding Source for ArcSeven itself is public (GPLv3 section 6)\n'
exit 0
