#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# notarize.sh — submit a signed artifact to Apple's notary service, wait for the
# verdict, then staple and validate the ticket.
#
# Credentials come from an App Store Connect API key, never from an Apple ID and
# app-specific password: the key is scoped, revocable, and does not break when
# the account is re-prompted for 2FA. Same three variables work locally and in CI.
#
#   AC_API_KEY_ID      App Store Connect API Key ID     (e.g. 2X9ABC3DEF)
#   AC_API_ISSUER_ID   App Store Connect Issuer UUID
#   AC_API_KEY_PATH    path to AuthKey_<KEYID>.p8
#
# NOTARY_KEY_ID / NOTARY_ISSUER_ID / NOTARY_KEY_PATH are accepted as equivalents, because
# that is what release.yml exports and what the repository secrets are called.
#
# A .zip cannot carry a stapled ticket. Submitting a .app therefore zips it for
# transport and staples the .app itself; submitting a .zip requires you to name
# the staple target explicitly.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-45m}"

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME <artifact> [staple-target]

  artifact       .dmg, .pkg, .app or .zip to submit to the notary service
  staple-target  what to staple afterwards; required only when <artifact>
                 is a .zip (tickets cannot be stapled to a zip archive)

environment (all three required):
  AC_API_KEY_ID     App Store Connect API Key ID
  AC_API_ISSUER_ID  App Store Connect Issuer UUID
  AC_API_KEY_PATH   path to the AuthKey_<KEYID>.p8 private key

optional:
  NOTARY_TIMEOUT    how long to wait for a verdict (default $NOTARY_TIMEOUT)
USAGE
}

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
esac

ARTIFACT="${1%/}"
STAPLE_TARGET="${2:-}"

[ -e "$ARTIFACT" ] || die "no such file: $ARTIFACT"
command -v xcrun >/dev/null 2>&1 || die "xcrun not found — install the Xcode command line tools"
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not available (needs Xcode 13 or newer)"

# --------------------------------------------------------- credentials ------
step "Credentials"
# Accept either spelling.
#
# release.yml exports NOTARY_KEY_ID / NOTARY_ISSUER_ID / NOTARY_KEY_PATH, matching the
# secret names; this script was written expecting AC_API_*. Two files, two conventions,
# and the release failed at the notarisation step on its first run with
# "AC_API_KEY_ID is not set" — after a successful build and sign, which is the most
# expensive place to discover a typo.
#
# Rather than pick a winner and leave the other spelling as a trap, both work. AC_API_*
# wins when both are set, since that is what --help documents.
: "${AC_API_KEY_ID:=${NOTARY_KEY_ID:-}}"
: "${AC_API_ISSUER_ID:=${NOTARY_ISSUER_ID:-}}"
: "${AC_API_KEY_PATH:=${NOTARY_KEY_PATH:-}}"

for v in AC_API_KEY_ID AC_API_ISSUER_ID AC_API_KEY_PATH; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || die "environment variable $v is not set (see --help)"
done
[ -f "$AC_API_KEY_PATH" ] || die "AC_API_KEY_PATH does not point at a file: $AC_API_KEY_PATH"
[ -r "$AC_API_KEY_PATH" ] || die "AC_API_KEY_PATH is not readable: $AC_API_KEY_PATH"
info "key id:    $AC_API_KEY_ID"
info "issuer:    $AC_API_ISSUER_ID"
info "key file:  $AC_API_KEY_PATH"

NOTARY_AUTH=(--key "$AC_API_KEY_PATH" --key-id "$AC_API_KEY_ID" --issuer "$AC_API_ISSUER_ID")

WORKDIR="$(mktemp -d -t arcseven-notarize)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# ------------------------------------------------- what do we submit? -------
step "Preparing submission"
SUBMIT_FILE=""
case "$ARTIFACT" in
    *.app)
        [ -d "$ARTIFACT" ] || die "$ARTIFACT is not a bundle directory"
        codesign --verify --strict "$ARTIFACT" >/dev/null 2>&1 \
            || die "$ARTIFACT is not validly signed — run Scripts/sign.sh first"
        SUBMIT_FILE="$WORKDIR/$(basename "${ARTIFACT%.app}").zip"
        info "zipping the bundle for transport (ditto --keepParent --sequesterRsrc)"
        ditto -c -k --keepParent --sequesterRsrc "$ARTIFACT" "$SUBMIT_FILE"
        [ -n "$STAPLE_TARGET" ] || STAPLE_TARGET="$ARTIFACT"
        ;;
    *.zip)
        SUBMIT_FILE="$ARTIFACT"
        [ -n "$STAPLE_TARGET" ] || die "a ticket cannot be stapled to a .zip — pass the .app as the second argument"
        ;;
    *.dmg|*.pkg)
        SUBMIT_FILE="$ARTIFACT"
        [ -n "$STAPLE_TARGET" ] || STAPLE_TARGET="$ARTIFACT"
        ;;
    *)
        die "unsupported artifact type: $ARTIFACT (expected .dmg, .pkg, .app or .zip)"
        ;;
esac
[ -e "$STAPLE_TARGET" ] || die "staple target does not exist: $STAPLE_TARGET"
info "submit:  $SUBMIT_FILE"
info "staple:  $STAPLE_TARGET"

# ------------------------------------------------------------- submit -------
step "Submitting to the notary service (waiting, timeout $NOTARY_TIMEOUT)"
SUBMIT_JSON="$WORKDIR/submit.json"
set +e
xcrun notarytool submit "$SUBMIT_FILE" "${NOTARY_AUTH[@]}" \
    --wait --timeout "$NOTARY_TIMEOUT" --output-format json > "$SUBMIT_JSON" 2> "$WORKDIR/submit.err"
SUBMIT_RC=$?
set -e
[ -s "$WORKDIR/submit.err" ] && cat "$WORKDIR/submit.err" >&2

json_value() {
    local key="$1" file="$2" v
    v="$(plutil -extract "$key" raw -o - -- "$file" 2>/dev/null)" || v=""
    if [ -z "$v" ] && [ -f "$file" ]; then
        v="$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -n1 || true)"
    fi
    printf '%s' "$v"
}

SUBMISSION_ID="$(json_value id "$SUBMIT_JSON")"
STATUS="$(json_value status "$SUBMIT_JSON")"
MESSAGE="$(json_value message "$SUBMIT_JSON")"

info "submission id: ${SUBMISSION_ID:-<unknown>}"
info "status:        ${STATUS:-<unknown>}"
[ -n "$MESSAGE" ] && info "message:       $MESSAGE"

if [ "$STATUS" != "Accepted" ]; then
    printf '\n%s: notarization did not succeed (status=%s, exit=%s)\n' \
           "$SCRIPT_NAME" "${STATUS:-unknown}" "$SUBMIT_RC" >&2
    if [ -n "$SUBMISSION_ID" ]; then
        printf '\n--- notarytool log %s ---\n' "$SUBMISSION_ID" >&2
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" >&2 || true
        printf -- '--- end of log ---\n\n' >&2
        printf 'The log lists the offending binary. In practice it is always one of:\n' >&2
        printf '  * a nested Mach-O that was never signed (run Scripts/sign.sh, do not sign by hand)\n' >&2
        printf '  * a signature made without --timestamp\n' >&2
        printf '  * a binary signed without --options runtime\n' >&2
    fi
    exit 1
fi

# ------------------------------------------------------------- staple -------
step "Stapling the ticket"
xcrun stapler staple "$STAPLE_TARGET"

step "Validating the ticket"
xcrun stapler validate "$STAPLE_TARGET"

# ---------------------------------------------------------- assessment ------
step "Gatekeeper assessment"
case "$STAPLE_TARGET" in
    *.app) spctl --assess -vvv --type exec "$STAPLE_TARGET" 2>&1 || true ;;
    *.dmg) spctl --assess -vvv --type install "$STAPLE_TARGET" 2>&1 || true ;;
    *.pkg) spctl --assess -vvv --type install "$STAPLE_TARGET" 2>&1 || true ;;
esac

printf '\nNotarized and stapled: %s\n' "$STAPLE_TARGET"
printf 'Next:  Scripts/verify-release.sh "%s"\n' "$STAPLE_TARGET"
