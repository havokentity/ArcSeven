#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Rajesh D'Monte
#
# refresh-third-party-licenses.sh
#
# Re-vendors ArcSeven's third-party licence tree for the bundled 7-Zip "7zz"
# console binary, and keeps THIRD_PARTY_LICENSES/7-Zip/VERSION.txt honest.
#
# It does three things:
#
#   1. Re-fetches https://www.7-zip.org/license.txt and compares it, byte for
#      byte, with the copy vendored at THIRD_PARTY_LICENSES/7-Zip/LICENSE.txt.
#      If upstream has changed the licence text, the script FAILS LOUDLY and
#      refuses to touch anything, because a changed licence means NOTICE, the
#      THIRD_PARTY_LICENSES index and the in-app Acknowledgements all have to be
#      re-read by a human before the change is accepted.
#   2. Recomputes the SHA-256 of the 7zz binary that will be shipped and of the
#      upstream source archive that discharges the LGPL-2.1 section 4 source
#      offer, and rewrites those fields in VERSION.txt.
#   3. Verifies the LGPL-2.1 text is present, and (if the app bundle's legal
#      resources directory exists) syncs the vendored files into it.
#
# Run it whenever the bundled 7zz is rebuilt or bumped, and in CI before every
# release.  `--check` makes it read-only and non-zero on any drift.
#
# Requires: bash 3.2+ (stock macOS), curl, awk, and shasum or sha256sum.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LICENSE_URL="https://www.7-zip.org/license.txt"
LGPL_URL="https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt"
LGPL_FIRST_LINE_MATCH="GNU LESSER GENERAL PUBLIC LICENSE"

# Where a built or downloaded 7zz might be found, relative to the repo root.
# The first one that exists wins; --binary overrides all of them.
BINARY_CANDIDATES="
vendor/7zz
vendor/bin/7zz
vendor/7zip-bin/7zz
Resources/Helpers/7zz
build/Helpers/7zz
"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

PROG="$(basename "$0")"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_BLD=''; C_OFF=''
fi

info()  { printf '%s\n' "  $*"; }
ok()    { printf '%s\n' "${C_GRN}  ok${C_OFF}   $*"; }
step()  { printf '\n%s\n' "${C_BLD}$*${C_OFF}"; }
warn()  { printf '%s\n' "${C_YEL}  warn${C_OFF} $*" >&2; }
die()   { printf '%s\n' "${C_RED}${PROG}: error:${C_OFF} $*" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: $PROG [options]

Re-vendors the 7-Zip licence tree and refreshes the checksums recorded in
THIRD_PARTY_LICENSES/7-Zip/VERSION.txt.

Options:
  --binary PATH             Hash this 7zz binary (default: first of
                            $(printf '%s' "$BINARY_CANDIDATES" | tr '\n' ' ' | sed 's/  */ /g')
                            that exists, then a search under vendor/ and build/).
  --source PATH             Hash this source tarball instead of downloading it.
  --version X.YZ            Bump to a new upstream 7-Zip version (e.g. 26.02).
                            Rewrites the version, tag, tarball names and URLs;
                            you must still set "Upstream released" by hand.
  --accept-license-change   Accept a changed upstream licence text and vendor
                            it.  Only pass this AFTER updating NOTICE, the
                            THIRD_PARTY_LICENSES index and the in-app
                            Acknowledgements to match the new text.
  --require-binary          Fail if no 7zz binary can be found (use in release CI).
  --no-download             Never reach for the source tarball over the network.
  --check                   Read-only. Changes nothing; exits non-zero if the
                            vendored tree or the recorded checksums are stale.
  -h, --help                This message.

Exit status: 0 clean, 1 error or (with --check) drift detected.
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

BINARY_PATH=""
SOURCE_PATH=""
NEW_VERSION=""
ACCEPT_LICENSE_CHANGE=false
REQUIRE_BINARY=false
ALLOW_DOWNLOAD=true
CHECK_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)   [ $# -ge 2 ] || die "--binary needs a path";  BINARY_PATH="$2"; shift 2 ;;
        --source)   [ $# -ge 2 ] || die "--source needs a path";  SOURCE_PATH="$2"; shift 2 ;;
        --version)  [ $# -ge 2 ] || die "--version needs a value"; NEW_VERSION="$2"; shift 2 ;;
        --accept-license-change) ACCEPT_LICENSE_CHANGE=true; shift ;;
        --require-binary)        REQUIRE_BINARY=true;        shift ;;
        --no-download)           ALLOW_DOWNLOAD=false;       shift ;;
        --check)                 CHECK_ONLY=true;            shift ;;
        -h|--help)               usage; exit 0 ;;
        *)                       usage >&2; die "unknown argument: $1" ;;
    esac
done

for tool in curl awk; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 \
    || die "need shasum or sha256sum to compute checksums"

if [ -n "$NEW_VERSION" ]; then
    case "$NEW_VERSION" in
        [0-9][0-9].[0-9][0-9]) : ;;
        *) die "--version must look like 26.02, got: $NEW_VERSION" ;;
    esac
    [ "$CHECK_ONLY" = true ] && die "--version and --check are mutually exclusive"
fi

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT/THIRD_PARTY_LICENSES/7-Zip"
VERSION_FILE="$VENDOR_DIR/VERSION.txt"
LICENSE_FILE="$VENDOR_DIR/LICENSE.txt"
LGPL_FILE="$VENDOR_DIR/LGPL-2.1.txt"
APP_LEGAL_DIR="$ROOT/Resources/Legal/7-Zip"

[ -f "$VERSION_FILE" ] || die "not found: $VERSION_FILE (run this from inside the ArcSeven repo)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/arcseven-licences.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------------------
# VERSION.txt field access.  Format: "Key:" padded to column 24, then the value.
# ---------------------------------------------------------------------------

FIELD_COLUMN=23

get_field() {
    KEY="$1" awk '
        BEGIN { k = ENVIRON["KEY"] ":" }
        substr($0, 1, length(k)) == k {
            v = substr($0, length(k) + 1)
            sub(/^[ \t]+/, "", v)
            sub(/[ \t\r]+$/, "", v)
            print v
            exit
        }
    ' "$VERSION_FILE"
}

write_field() {
    local key="$1" value="$2" tmp
    tmp="$WORK/VERSION.txt.new"
    KEY="$key" VALUE="$value" WIDTH="$FIELD_COLUMN" awk '
        BEGIN { k = ENVIRON["KEY"] ":"; v = ENVIRON["VALUE"]; w = ENVIRON["WIDTH"] + 0; found = 0 }
        substr($0, 1, length(k)) == k && found == 0 {
            printf "%-*s%s\n", w, k, v
            found = 1
            next
        }
        { print }
        END { if (found == 0) exit 3 }
    ' "$VERSION_FILE" > "$tmp" || {
        rm -f "$tmp"
        die "VERSION.txt has no \"$key:\" field — the record and this script have drifted apart"
    }
    mv "$tmp" "$VERSION_FILE"
}

# Queued updates, applied (or merely compared, under --check) at the end.
PENDING_KEYS=()
PENDING_VALS=()

queue() {
    PENDING_KEYS[${#PENDING_KEYS[@]}]="$1"
    PENDING_VALS[${#PENDING_VALS[@]}]="$2"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | awk '{print $1}'
    else
        sha256sum -- "$1" | awk '{print $1}'
    fi
}

fetch() {  # fetch <url> <dest>
    curl --fail --location --silent --show-error \
         --proto '=https' --tlsv1.2 \
         --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
         --output "$2" -- "$1"
}

human_size() {
    if [ -f "$1" ]; then
        awk -v b="$(wc -c < "$1" | tr -d ' ')" \
            'BEGIN { if (b < 1024) printf "%d B", b;
                     else if (b < 1048576) printf "%.1f KiB", b/1024;
                     else printf "%.2f MiB", b/1048576 }'
    fi
}

# ---------------------------------------------------------------------------
# Step 0 — version bump
# ---------------------------------------------------------------------------

VERSION="$(get_field 'Upstream version')"
[ -n "$VERSION" ] || die "VERSION.txt has no \"Upstream version\" value"

if [ -n "$NEW_VERSION" ]; then
    step "Bumping upstream version: $VERSION -> $NEW_VERSION"
    compact="$(printf '%s' "$NEW_VERSION" | tr -d '.')"
    base="https://github.com/ip7z/7zip/releases/download/$NEW_VERSION"
    queue 'Upstream version' "$NEW_VERSION"
    queue 'Upstream tag'     "$NEW_VERSION"
    queue 'Binary tarball'   "7z${compact}-mac.tar.xz"
    queue 'Binary URL'       "$base/7z${compact}-mac.tar.xz"
    queue 'Source tarball'   "7z${compact}-src.tar.xz"
    queue 'Source URL'       "$base/7z${compact}-src.tar.xz"
    VERSION="$NEW_VERSION"
    SOURCE_TARBALL="7z${compact}-src.tar.xz"
    SOURCE_URL="$base/7z${compact}-src.tar.xz"
    warn "set \"Upstream released\" in VERSION.txt by hand — the release date cannot be derived"
else
    SOURCE_TARBALL="$(get_field 'Source tarball')"
    SOURCE_URL="$(get_field 'Source URL')"
fi

printf '%s\n' "${C_BLD}ArcSeven third-party licence refresh${C_OFF}"
info "repo:          $ROOT"
info "7-Zip version: $VERSION"
[ "$CHECK_ONLY" = true ] && info "mode:          --check (read-only)"

# ---------------------------------------------------------------------------
# Step 1 — the upstream licence text.  This is the gate.
# ---------------------------------------------------------------------------

step "1. Upstream licence text"

FETCHED_LICENSE="$WORK/license.txt"
info "fetching $LICENSE_URL"
fetch "$LICENSE_URL" "$FETCHED_LICENSE" \
    || die "could not fetch $LICENSE_URL — refusing to proceed on a stale licence"
[ -s "$FETCHED_LICENSE" ] || die "$LICENSE_URL returned an empty document"

# Sanity-check that we got a licence and not a captive portal or an error page.
grep -q 'unRAR license restriction' "$FETCHED_LICENSE" \
    || die "the document at $LICENSE_URL does not look like 7-Zip's licence (no unRAR section)"

FETCHED_LICENSE_SHA="$(sha256 "$FETCHED_LICENSE")"
RECORDED_LICENSE_SHA="$(get_field 'License SHA-256')"

if [ ! -f "$LICENSE_FILE" ]; then
    [ "$CHECK_ONLY" = true ] && die "missing vendored licence: $LICENSE_FILE"
    warn "no vendored licence yet — installing $LICENSE_URL verbatim"
    cp "$FETCHED_LICENSE" "$LICENSE_FILE"
    ok "vendored $(basename "$LICENSE_FILE") ($(human_size "$LICENSE_FILE"))"
elif cmp -s "$FETCHED_LICENSE" "$LICENSE_FILE"; then
    ok "vendored licence is byte-for-byte identical to upstream"
else
    printf '\n%s\n' "${C_RED}${C_BLD}================================================================${C_OFF}"
    printf '%s\n'   "${C_RED}${C_BLD} UPSTREAM 7-Zip LICENCE TEXT HAS CHANGED${C_OFF}"
    printf '%s\n'   "${C_RED}${C_BLD}================================================================${C_OFF}"
    printf '%s\n\n' "The text at $LICENSE_URL no longer matches the copy vendored at
  $LICENSE_FILE

  vendored file: $(sha256 "$LICENSE_FILE")
  recorded:      $RECORDED_LICENSE_SHA
  upstream now:  $FETCHED_LICENSE_SHA

Diff (vendored -> upstream):"
    diff -u "$LICENSE_FILE" "$FETCHED_LICENSE" || true
    printf '\n%s\n' "This is a release blocker, not a formatting nit. Before accepting it:

  1. Read the new licence in full. Check whether the LGPL / BSD-3 / BSD-2 /
     unRAR split in NOTICE section 1.1 still describes reality.
  2. Check whether the unRAR restriction paragraph reproduced VERBATIM in
     NOTICE section 2 has changed. If it has, update it there, in README.md,
     and in the in-app Acknowledgements pane — all three are the
     \"documentation\" the unRAR licence requires.
  3. Update THIRD_PARTY_LICENSES/README.md if the SPDX expression changed.
  4. Re-run:  $PROG --accept-license-change"

    if [ "$ACCEPT_LICENSE_CHANGE" != true ] || [ "$CHECK_ONLY" = true ]; then
        die "upstream licence changed — refusing to vendor it silently"
    fi

    warn "--accept-license-change given: vendoring the new licence text"
    cp "$FETCHED_LICENSE" "$LICENSE_FILE"
    ok "vendored the new $(basename "$LICENSE_FILE") ($(human_size "$LICENSE_FILE"))"
fi

if [ "$RECORDED_LICENSE_SHA" != "$FETCHED_LICENSE_SHA" ]; then
    queue 'License SHA-256' "$FETCHED_LICENSE_SHA"
else
    ok "License SHA-256 matches the record"
fi

# ---------------------------------------------------------------------------
# Step 2 — the LGPL-2.1 text
# ---------------------------------------------------------------------------

step "2. LGPL-2.1 text"

if [ -s "$LGPL_FILE" ] && grep -q "$LGPL_FIRST_LINE_MATCH" "$LGPL_FILE"; then
    ok "$(basename "$LGPL_FILE") present ($(human_size "$LGPL_FILE"))"
else
    [ "$CHECK_ONLY" = true ] && die "missing or malformed: $LGPL_FILE"
    warn "missing or malformed — re-fetching $LGPL_URL"
    fetch "$LGPL_URL" "$WORK/lgpl-2.1.txt" || die "could not fetch $LGPL_URL"
    grep -q "$LGPL_FIRST_LINE_MATCH" "$WORK/lgpl-2.1.txt" \
        || die "the document at $LGPL_URL does not look like the LGPL-2.1 text"
    mv "$WORK/lgpl-2.1.txt" "$LGPL_FILE"
    ok "vendored $(basename "$LGPL_FILE") ($(human_size "$LGPL_FILE"))"
fi

# ---------------------------------------------------------------------------
# Step 3 — the shipped 7zz binary
# ---------------------------------------------------------------------------

step "3. Bundled 7zz binary"

resolve_binary() {
    if [ -n "$BINARY_PATH" ]; then
        [ -f "$BINARY_PATH" ] || die "--binary: no such file: $BINARY_PATH"
        printf '%s\n' "$BINARY_PATH"
        return 0
    fi
    if [ -n "${ARCSEVEN_7ZZ:-}" ] && [ -f "$ARCSEVEN_7ZZ" ]; then
        printf '%s\n' "$ARCSEVEN_7ZZ"
        return 0
    fi
    # $BINARY_CANDIDATES is newline-separated and contains no spaces, so the
    # default IFS splits it correctly.
    local candidate found
    for candidate in $BINARY_CANDIDATES; do
        if [ -f "$ROOT/$candidate" ]; then
            printf '%s\n' "$ROOT/$candidate"
            return 0
        fi
    done
    # Last resort: a shallow search of the build inputs and outputs.
    found="$(find "$ROOT/vendor" "$ROOT/build" -maxdepth 6 -type f -name 7zz -perm -u+x \
                 2>/dev/null | head -n 1 || true)"
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
        return 0
    fi
    return 1
}

BINARY=""
if BINARY="$(resolve_binary)"; then
    info "binary: $BINARY ($(human_size "$BINARY"))"
    BINARY_SHA="$(sha256 "$BINARY")"
    queue 'Binary SHA-256' "$BINARY_SHA"
    info "sha256: $BINARY_SHA"

    if command -v lipo >/dev/null 2>&1; then
        if ARCHS="$(lipo -archs "$BINARY" 2>/dev/null)"; then
            # Sorted, so slice order in the Mach-O never shows up as spurious drift.
            ARCHS="$(printf '%s' "$ARCHS" | tr ' \t' '\n\n' | grep . | sort | tr '\n' ' ' | sed 's/ $//')"
            queue 'Binary architectures' "$ARCHS"
            case " $ARCHS " in
                *" arm64 "*) case " $ARCHS " in
                                 *" x86_64 "*) ok "universal binary: $ARCHS" ;;
                                 *) warn "not universal: $ARCHS — Intel Macs will not be able to run it" ;;
                             esac ;;
                *) warn "no arm64 slice: $ARCHS" ;;
            esac
        else
            warn "lipo could not read $BINARY — is it really a Mach-O?"
        fi
    fi

    # Separateness check: a *modified* 7zz would break the aggregation argument
    # that NOTICE section 1 rests on.  We cannot prove "unmodified" here, but we
    # can prove the recorded version string matches what we are shipping.
    if [ -x "$BINARY" ]; then
        REPORTED="$("$BINARY" 2>/dev/null | awk 'NR <= 3 && /7-Zip/ { print; exit }' || true)"
        if [ -n "$REPORTED" ]; then
            info "self-reported: $REPORTED"
            case "$REPORTED" in
                *"$VERSION"*) ok "binary reports version $VERSION" ;;
                *) warn "binary does not report version $VERSION — VERSION.txt may be describing a different build" ;;
            esac
        fi
    fi
else
    if [ "$REQUIRE_BINARY" = true ]; then
        die "no 7zz binary found — pass --binary PATH, or set ARCSEVEN_7ZZ"
    fi
    warn "no 7zz binary found; leaving \"Binary SHA-256\" untouched"
    info "build or download one, then re-run with --binary PATH"
    info "upstream: $(get_field 'Binary URL')"
fi

# ---------------------------------------------------------------------------
# Step 4 — the source archive that discharges LGPL-2.1 section 4
# ---------------------------------------------------------------------------

step "4. Upstream source archive (LGPL-2.1 s4 offer)"

resolve_source() {
    if [ -n "$SOURCE_PATH" ]; then
        [ -f "$SOURCE_PATH" ] || die "--source: no such file: $SOURCE_PATH"
        printf '%s\n' "$SOURCE_PATH"
        return 0
    fi
    local dir
    for dir in "$ROOT/vendor" "$ROOT/dist" "$ROOT/build" "$ROOT"; do
        if [ -f "$dir/$SOURCE_TARBALL" ]; then
            printf '%s\n' "$dir/$SOURCE_TARBALL"
            return 0
        fi
    done
    return 1
}

SOURCE_ARCHIVE=""
if SOURCE_ARCHIVE="$(resolve_source)"; then
    info "local copy: $SOURCE_ARCHIVE ($(human_size "$SOURCE_ARCHIVE"))"
elif [ "$ALLOW_DOWNLOAD" = true ] && [ -n "$SOURCE_URL" ]; then
    info "downloading $SOURCE_URL"
    if fetch "$SOURCE_URL" "$WORK/$SOURCE_TARBALL"; then
        SOURCE_ARCHIVE="$WORK/$SOURCE_TARBALL"
        info "downloaded $SOURCE_TARBALL ($(human_size "$SOURCE_ARCHIVE"))"
    else
        SOURCE_ARCHIVE=""
        warn "could not download $SOURCE_URL"
    fi
else
    warn "no local $SOURCE_TARBALL and downloads are disabled"
fi

if [ -n "$SOURCE_ARCHIVE" ]; then
    SOURCE_SHA="$(sha256 "$SOURCE_ARCHIVE")"
    queue 'Source SHA-256' "$SOURCE_SHA"
    info "sha256: $SOURCE_SHA"
    ok "this archive must be attached to the same GitHub Release as the .dmg"
else
    warn "leaving \"Source SHA-256\" untouched"
    warn "the LGPL-2.1 s4 offer in NOTICE is only good if $SOURCE_TARBALL ships on the release page"
fi

# ---------------------------------------------------------------------------
# Step 5 — apply (or, under --check, compare)
# ---------------------------------------------------------------------------

step "5. VERSION.txt"

DRIFT=0
i=0
while [ "$i" -lt "${#PENDING_KEYS[@]}" ]; do
    key="${PENDING_KEYS[$i]}"
    val="${PENDING_VALS[$i]}"
    cur="$(get_field "$key")"
    if [ "$cur" = "$val" ]; then
        ok "$key unchanged"
    else
        DRIFT=1
        if [ "$CHECK_ONLY" = true ]; then
            warn "$key is stale"
            info "  recorded: $cur"
            info "  actual:   $val"
        else
            write_field "$key" "$val"
            info "$key -> $val"
        fi
    fi
    i=$((i + 1))
done

if [ "$CHECK_ONLY" != true ]; then
    write_field 'Last verified' "$(date -u '+%Y-%m-%d')"
    ok "Last verified -> $(get_field 'Last verified')"
else
    # An unfilled placeholder means this tree has never been pointed at a real
    # artifact, so nobody can verify the binary against the source we offer.
    for key in 'Binary SHA-256' 'Source SHA-256'; do
        case "$(get_field "$key")" in
            *"FILLED BY"*)
                DRIFT=1
                warn "$key is still a placeholder — nothing has been vendored yet"
                ;;
        esac
    done
fi

# These two are invariants of the whole design, not values to recompute.  If a
# future change ever makes them untrue, every licensing argument in NOTICE
# collapses, so assert them rather than rewrite them.
LINKAGE="$(get_field 'Linkage')"
MODIFICATIONS="$(get_field 'Modifications')"
case "$LINKAGE" in
    NONE*) : ;;
    *) die "VERSION.txt records Linkage: $LINKAGE — ArcSeven must never link 7-Zip code (see NOTICE s1, THIRD_PARTY_LICENSES/README.md)" ;;
esac
case "$MODIFICATIONS" in
    NONE*) : ;;
    *) die "VERSION.txt records Modifications: $MODIFICATIONS — a patched 7zz is a derivative work and tightens LGPL-2.1 s2/s4 sharply" ;;
esac
ok "Linkage: $LINKAGE"
ok "Modifications: $MODIFICATIONS"

# ---------------------------------------------------------------------------
# Step 6 — sync into the app bundle's legal resources, if that tree exists
# ---------------------------------------------------------------------------

if [ -d "$APP_LEGAL_DIR" ]; then
    step "6. App bundle legal resources"
    for f in LICENSE.txt LGPL-2.1.txt VERSION.txt; do
        if cmp -s "$VENDOR_DIR/$f" "$APP_LEGAL_DIR/$f"; then
            ok "$f in sync"
        elif [ "$CHECK_ONLY" = true ]; then
            DRIFT=1
            warn "Resources/Legal/7-Zip/$f is out of date"
        else
            cp "$VENDOR_DIR/$f" "$APP_LEGAL_DIR/$f"
            info "$f -> Resources/Legal/7-Zip/$f"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

if [ "$CHECK_ONLY" = true ]; then
    if [ "$DRIFT" -ne 0 ]; then
        printf '\n'
        die "third-party licence tree is stale — run $PROG without --check"
    fi
    printf '\n%s\n' "${C_GRN}${C_BLD}Third-party licence tree is current.${C_OFF}"
else
    printf '\n%s\n' "${C_GRN}${C_BLD}Third-party licence tree refreshed.${C_OFF}"
    info "review:  git diff THIRD_PARTY_LICENSES/"
    info "reminder: the unRAR paragraph must stay verbatim in NOTICE, README.md,"
    info "          and the in-app Acknowledgements pane."
fi
