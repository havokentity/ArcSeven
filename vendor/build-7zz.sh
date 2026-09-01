#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Rajesh D'Monte
#
# build-7zz.sh — build the pinned upstream 7-Zip source into a UNIVERSAL `7zz`
# helper binary and stage it for the Xcode "Copy Files" phase.
#
# ArcSeven ships `7zz` as a SEPARATE EXECUTABLE in ArcSeven.app/Contents/Helpers/.
# It is never linked into the app. That process boundary keeps the Apache-2.0
# first-party application distinct from the LGPL-2.1-or-later + unRAR-restricted
# helper (see vendor/README.md). The binary must be a verifiable build of
# UNMODIFIED upstream source — this script refuses to produce anything else
# without an explicit, loud override.
#
# Build recipe (empirically verified on this machine against ip7z/7zip 26.02,
# zero patches, both slices, `-Werror -Wall -Wextra` as upstream ships them):
#
#     cd CPP/7zip/Bundles/Alone2
#     make -j -f ../../cmpl_mac_arm64.mak   ->  b/m_arm64/7zz
#     make -j -f ../../cmpl_mac_x64.mak     ->  b/m_x64/7zz
#     lipo -create ... -output 7zz
#
# The `cmpl_mac_*.mak` files are three-line includes of `var_mac_*.mak`
# (PLATFORM / O=b/m_$(PLATFORM) / MY_ARCH), `warn_clang_mac.mak`, and the
# bundle's own `makefile.gcc`. Nothing else is needed; `MACOSX_DEPLOYMENT_TARGET`
# is honoured by clang directly, so no makefile edit is required to pin the
# deployment target.
#
# Usage:
#   vendor/build-7zz.sh                      build + verify + stage
#   vendor/build-7zz.sh --check              verify an already-staged binary
#   vendor/build-7zz.sh --help
#
set -euo pipefail

# --------------------------------------------------------------------------
# The pin. Change these two lines (and only these two) to bump 7-Zip.
# See "Bumping the pinned version" in vendor/README.md for the full checklist.
# --------------------------------------------------------------------------
PINNED_TAG="26.02"
PINNED_COMMIT="f9d78aff31a5f2521ae7ddbdc97c4a8855808959"
UPSTREAM_URL="https://github.com/ip7z/7zip.git"

# The version string `7zz` prints in its banner: "7-Zip (z) 26.02 (arm64) : ..."
EXPECTED_VERSION="$PINNED_TAG"

# Minimum macOS we run on. Must match MACOSX_DEPLOYMENT_TARGET in project.yml.
DEPLOYMENT_TARGET="14.0"

REQUIRED_ARCHS="arm64 x86_64"

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

SRC_DIR="${ARCSEVEN_7ZIP_SRC:-$REPO_ROOT/vendor/7zip}"
STAGING_DIR="${ARCSEVEN_STAGING_DIR:-$REPO_ROOT/vendor/bin}"

BUNDLE_SUBDIR="CPP/7zip/Bundles/Alone2"
ARM64_MAKEFILE="../../cmpl_mac_arm64.mak"
X64_MAKEFILE="../../cmpl_mac_x64.mak"
ARM64_OUT="b/m_arm64/7zz"
X64_OUT="b/m_x64/7zz"

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
MODE="build"
CHECK_BINARY=""
JOBS=""
DO_CLEAN=0
ALLOW_DIRTY=0
# Signing identity for the staged helper.
#
# Defaults to a Developer ID Application certificate when one is in the keychain, and
# falls back to ad-hoc when none is. This is NOT cosmetic: notarisation rejects any
# Mach-O in the bundle that is not Developer ID signed with the hardened runtime, and
# Xcode does NOT re-sign a plain file delivered by a copy-files phase. Verified
# empirically -- with an ad-hoc helper the app signed correctly and
# `codesign --verify --deep --strict` still passed, while the helper itself reported
# `flags=0x10002(adhoc,runtime)` and `TeamIdentifier=not set`, which fails notarisation
# only at the very end of the release process. Sign it here instead.
#
# Override with --sign, --no-sign, or $ARCSEVEN_SIGN_IDENTITY.
if [ -n "${ARCSEVEN_SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY="$ARCSEVEN_SIGN_IDENTITY"
else
  _auto_identity="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
  SIGN_IDENTITY="${_auto_identity:--}"
  unset _auto_identity
fi
DO_SIGN=1
VERBOSE=0

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m';    C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_OFF=""
fi

step() { printf '%s==>%s %s\n' "$C_BLU" "$C_OFF" "$*" >&2; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
info() { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; }

die() {
  printf '\n%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_RED" "$C_OFF" >&2
  printf '%s║  build-7zz.sh FAILED%s\n' "$C_RED" "$C_OFF" >&2
  printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_RED" "$C_OFF" >&2
  printf '\n' >&2
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done
  printf '\n' >&2
  exit 1
}

usage() {
  cat <<EOF
build-7zz.sh — build upstream 7-Zip $PINNED_TAG into a universal 7zz helper

USAGE
  vendor/build-7zz.sh [options]
  vendor/build-7zz.sh --check [--binary PATH]

MODES
  (default)          Verify the source tree is pristine, build the arm64 and
                     x86_64 slices, lipo them together, verify, record the
                     SHA-256, and install into the staging directory.
  --check            Do not build. Verify an already-built binary: universality,
                     both slices execute, recorded SHA-256 still matches, the
                     build provenance matches this script's pin.

OPTIONS
  --binary PATH      Binary to verify in --check mode.
                     Default: <staging-dir>/7zz
  --src DIR          Upstream 7-Zip checkout.
                     Default: \$ARCSEVEN_7ZIP_SRC or vendor/7zip
  --staging-dir DIR  Where the Xcode copy phase reads from.
                     Default: \$ARCSEVEN_STAGING_DIR or vendor/bin
  -j, --jobs N       Parallel make jobs. Default: sysctl hw.ncpu
  --clean            Remove b/m_arm64 and b/m_x64 before building
  --sign IDENTITY    Codesign identity for the staged binary. Default: "-" (ad-hoc)
  --no-sign          Do not codesign at all
  --allow-dirty      Build even though the source tree diverges from the pin.
                     The result is marked NOT DISTRIBUTABLE and --check will
                     reject it unless --allow-dirty is passed there too.
  -v, --verbose      Show the full make output
  -h, --help         This text

XCODE INTEGRATION
  project.yml declares the Copy Files phase that consumes the staged binary:
      - path: vendor/bin/7zz
        buildPhase:
          copyFiles:
            destination: wrapper     # -> ArcSeven.app/Contents/
            subpath: Helpers         # -> ArcSeven.app/Contents/Helpers/7zz
  A pre-build Run Script phase can keep it fresh:
      "\$SRCROOT/vendor/build-7zz.sh" --check || "\$SRCROOT/vendor/build-7zz.sh"

EXIT CODES
  0  success        1  any verification or build failure
EOF
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)        MODE="check" ;;
    --binary)       shift; [ "$#" -gt 0 ] || die "--binary needs a path"; CHECK_BINARY="$1" ;;
    --src)          shift; [ "$#" -gt 0 ] || die "--src needs a path";    SRC_DIR="$1" ;;
    --staging-dir)  shift; [ "$#" -gt 0 ] || die "--staging-dir needs a path"; STAGING_DIR="$1" ;;
    -j|--jobs)      shift; [ "$#" -gt 0 ] || die "--jobs needs a number";  JOBS="$1" ;;
    --clean)        DO_CLEAN=1 ;;
    --sign)         shift; [ "$#" -gt 0 ] || die "--sign needs an identity"; SIGN_IDENTITY="$1"; DO_SIGN=1 ;;
    --no-sign)      DO_SIGN=0 ;;
    --allow-dirty)  ALLOW_DIRTY=1 ;;
    -v|--verbose)   VERBOSE=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

STAGED_BIN="$STAGING_DIR/7zz"
STAGED_SUM="$STAGING_DIR/7zz.sha256"
STAGED_INFO="$STAGING_DIR/BUILD-INFO.txt"
[ -n "$CHECK_BINARY" ] || CHECK_BINARY="$STAGED_BIN"

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

sha256_of() { /usr/bin/shasum -a 256 "$1" | awk '{print $1}'; }

# Normalised, sorted, space-separated arch list of a Mach-O file.
archs_of() { /usr/bin/lipo -archs "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'; }

expected_archs_sorted() { printf '%s' "$REQUIRED_ARCHS" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'; }

host_arch() { /usr/bin/uname -m; }

require_tools() {
  local missing=""
  local t
  for t in git make clang lipo shasum awk sed; do
    have "$t" || missing="$missing $t"
  done
  [ -z "$missing" ] || die \
    "Missing required tool(s):$missing" \
    "Install the Xcode command line tools:  xcode-select --install"
}

# --------------------------------------------------------------------------
# THE LICENSE GATE — the source tree must be an unmodified checkout of the pin
# --------------------------------------------------------------------------
verify_pristine() {
  step "Verifying vendor source is unmodified upstream $PINNED_TAG"

  [ -d "$SRC_DIR" ] || die \
    "Upstream 7-Zip source not found at:" \
    "    $SRC_DIR" \
    "" \
    "Run Scripts/bootstrap.sh, which configures and checks out the submodule," \
    "or clone it yourself:" \
    "    git submodule update --init --recursive vendor/7zip"

  [ -e "$SRC_DIR/$BUNDLE_SUBDIR/makefile.gcc" ] || die \
    "$SRC_DIR does not look like an ip7z/7zip checkout." \
    "Expected to find: $BUNDLE_SUBDIR/makefile.gcc"

  if ! git -C "$SRC_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    die \
      "$SRC_DIR is not a git work tree." \
      "" \
      "The pinned-tag guarantee is the entire basis of ArcSeven's license posture:" \
      "we ship 7zz UNMODIFIED as a separately licensed LGPL-2.1 +" \
      "unRAR-restricted helper alongside the Apache-2.0 app." \
      "A dropped-in tarball cannot be verified, so it is not accepted." \
      "" \
      "Fix:  rm -rf '$SRC_DIR' && Scripts/bootstrap.sh"
  fi

  local head_sha
  head_sha="$(git -C "$SRC_DIR" rev-parse HEAD)"

  # 1. HEAD must be exactly the pinned commit. Checking the SHA, not just the
  #    tag name, is deliberate: upstream tags are lightweight and can be moved.
  if [ "$head_sha" != "$PINNED_COMMIT" ]; then
    local described
    described="$(git -C "$SRC_DIR" describe --tags --always 2>/dev/null || printf '%s' "$head_sha")"
    die \
      "vendor/7zip is at the wrong commit." \
      "" \
      "  expected  $PINNED_COMMIT   ($PINNED_TAG)" \
      "  found     $head_sha   ($described)" \
      "" \
      "Fix:" \
      "    git -C '$SRC_DIR' fetch --tags origin" \
      "    git -C '$SRC_DIR' checkout --detach $PINNED_COMMIT" \
      "" \
      "If you intended to BUMP the pinned version, edit PINNED_TAG and" \
      "PINNED_COMMIT at the top of this script and follow the checklist in" \
      "vendor/README.md — a bump is not complete until the parser test suite" \
      "has been re-run (docs/ENGINE-PROTOCOL.md)."
  fi

  # 2. If the tag ref is present it must resolve to the same commit. A shallow
  #    submodule checkout may not carry tags at all; that is not fatal, because
  #    the SHA above is the real authority.
  if git -C "$SRC_DIR" rev-parse -q --verify "refs/tags/$PINNED_TAG^{commit}" >/dev/null 2>&1; then
    local tag_sha
    tag_sha="$(git -C "$SRC_DIR" rev-parse "refs/tags/$PINNED_TAG^{commit}")"
    if [ "$tag_sha" != "$PINNED_COMMIT" ]; then
      die \
        "Upstream tag '$PINNED_TAG' no longer points at the pinned commit." \
        "" \
        "  tag $PINNED_TAG -> $tag_sha" \
        "  pinned          -> $PINNED_COMMIT" \
        "" \
        "The tag was moved upstream. Do NOT silently accept this. Diff the two" \
        "commits, decide deliberately, then update PINNED_COMMIT here."
    fi
    ok "tag $PINNED_TAG -> $PINNED_COMMIT"
  else
    info "tag refs/tags/$PINNED_TAG absent (shallow clone); verified by commit SHA instead"
    ok "HEAD == $PINNED_COMMIT"
  fi

  # 3. No modifications to tracked files (staged or unstaged, incl. deletions).
  if ! git -C "$SRC_DIR" diff --quiet HEAD -- 2>/dev/null; then
    local changed
    changed="$(git -C "$SRC_DIR" diff --name-status HEAD -- | sed 's/^/    /')"
    if [ "$ALLOW_DIRTY" -eq 1 ]; then
      warn "TRACKED FILES ARE MODIFIED — continuing only because --allow-dirty was given"
      printf '%s\n' "$changed" >&2
    else
      die \
        "Tracked files in vendor/7zip have been MODIFIED:" \
        "" \
        "$changed" \
        "" \
        "ArcSeven's license compliance depends on shipping 7zz built from" \
        "UNMODIFIED upstream source. A modified 7zz would make ArcSeven a" \
        "distributor of a derived work of LGPL-2.1 + unRAR-restricted code," \
        "and the unRAR clause is a 'further restriction' that GPLv3 section 7" \
        "does not permit us to pass on. See vendor/README.md." \
        "" \
        "Fix:" \
        "    git -C '$SRC_DIR' checkout -- ." \
        "    git -C '$SRC_DIR' clean -fdx     # also removes build output" \
        "" \
        "If you are experimenting locally and understand the result must never" \
        "be distributed, re-run with --allow-dirty."
    fi
  else
    ok "no modifications to tracked files"
  fi

  # 4. Untracked files. Build output under the bundle dirs is expected and fine;
  #    anything else is a stray file that has no business in a vendored tree.
  local stray=""
  local line path
  while IFS= read -r -d '' line; do
    case "$line" in
      '?? '*) path="${line#?? }" ;;
      *)      continue ;;
    esac
    case "$path" in
      CPP/7zip/Bundles/*/b/|CPP/7zip/Bundles/*/b/*) continue ;;
      CPP/7zip/Bundles/*/_o/|CPP/7zip/Bundles/*/_o/*) continue ;;
      .DS_Store|*/.DS_Store) continue ;;
    esac
    stray="$stray    $path
"
  done < <(git -C "$SRC_DIR" status --porcelain -z --untracked-files=normal 2>/dev/null)

  if [ -n "$stray" ]; then
    if [ "$ALLOW_DIRTY" -eq 1 ]; then
      warn "untracked files present in vendor/7zip (--allow-dirty):"
      printf '%s' "$stray" >&2
    else
      die \
        "Untracked files found in vendor/7zip:" \
        "" \
        "$stray" \
        "Only build output under CPP/7zip/Bundles/*/{b,_o}/ is permitted." \
        "Anything else means the vendored tree is no longer a clean checkout." \
        "" \
        "Fix:  git -C '$SRC_DIR' clean -fdx"
    fi
  else
    ok "no stray untracked files"
  fi
}

# --------------------------------------------------------------------------
# Build one architecture slice. Sets the global SLICE_BIN on success.
# (A global rather than stdout capture, so that `die` really terminates the
# script instead of only a command-substitution subshell.)
# --------------------------------------------------------------------------
SLICE_BIN=""
build_slice() {
  local arch="$1" makefile="$2" out_rel="$3"
  local bundle="$SRC_DIR/$BUNDLE_SUBDIR"
  local out_abs="$bundle/$out_rel"
  local log="$STAGING_DIR/.build-$arch.log"

  step "Building $arch slice  (make -j $JOBS -f $makefile)"

  rm -f "$out_abs"

  # MACOSX_DEPLOYMENT_TARGET is read by clang itself, so the deployment target
  # is pinned without touching a single upstream file.
  local rc=0
  if [ "$VERBOSE" -eq 1 ]; then
    ( cd "$bundle" && MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        make -j "$JOBS" -f "$makefile" ) 2>&1 | tee "$log" >&2 || rc=$?
  else
    ( cd "$bundle" && MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        make -j "$JOBS" -f "$makefile" ) >"$log" 2>&1 || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    die \
      "make failed for the $arch slice (exit $rc)." \
      "" \
      "Full log: $log" \
      "" \
      "Last 40 lines:" \
      "$(tail -n 40 "$log" | sed 's/^/    /')"
  fi

  [ -f "$out_abs" ] || die \
    "make reported success but $out_rel was not produced." \
    "Log: $log"

  local got
  got="$(archs_of "$out_abs")"
  [ "$got" = "$arch" ] || die \
    "The $arch slice has the wrong architecture." \
    "  expected: $arch" \
    "  got:      $got"

  ok "$arch  $(sha256_of "$out_abs")  ($(wc -c <"$out_abs" | tr -d ' ') bytes)"
  SLICE_BIN="$out_abs"
}

# --------------------------------------------------------------------------
# Verification shared by --check and the tail of a build
# --------------------------------------------------------------------------
verify_binary() {
  local bin="$1"
  local strict_provenance="$2"   # 1 = require BUILD-INFO to match the pin
  local failures=0

  [ -f "$bin" ] || die \
    "No binary at: $bin" \
    "" \
    "Build it first:  vendor/build-7zz.sh"

  [ -x "$bin" ] || die "Not executable: $bin"

  # --- universality -------------------------------------------------------
  step "Verifying $bin"
  local info_line archs want
  info_line="$(/usr/bin/lipo -info "$bin" 2>&1 || true)"
  info "lipo -info: $info_line"

  archs="$(archs_of "$bin")"
  want="$(expected_archs_sorted)"
  if [ "$archs" != "$want" ]; then
    die \
      "7zz is not the required universal binary." \
      "  expected architectures: $want" \
      "  found:                  ${archs:-<none>}" \
      "" \
      "$info_line" \
      "" \
      "Rebuild:  vendor/build-7zz.sh --clean"
  fi
  ok "universal Mach-O: $archs"

  # --- recorded checksum --------------------------------------------------
  local sum
  sum="$(sha256_of "$bin")"
  if [ -f "$STAGED_SUM" ] && [ "$bin" = "$STAGED_BIN" ]; then
    if ( cd "$STAGING_DIR" && /usr/bin/shasum -a 256 -c 7zz.sha256 ) >/dev/null 2>&1; then
      ok "SHA-256 matches recorded value: $sum"
    else
      die \
        "SHA-256 mismatch — the staged 7zz is not the binary that was recorded." \
        "  recorded: $(awk '{print $1}' "$STAGED_SUM")" \
        "  actual:   $sum" \
        "" \
        "Something modified the staged helper after it was built. Rebuild:" \
        "    vendor/build-7zz.sh --clean"
    fi
  else
    info "SHA-256: $sum  (no recorded sidecar to compare against)"
  fi

  # --- provenance ---------------------------------------------------------
  if [ -f "$STAGED_INFO" ] && [ "$bin" = "$STAGED_BIN" ]; then
    local rec_commit rec_tag rec_mod
    rec_commit="$(awk -F': *' '/^Upstream commit:/{print $2}' "$STAGED_INFO" | tr -d ' ')"
    rec_tag="$(awk -F': *' '/^Upstream tag:/{print $2}' "$STAGED_INFO" | tr -d ' ')"
    rec_mod="$(awk -F': *' '/^Modifications:/{print $2}' "$STAGED_INFO")"

    if [ "$strict_provenance" -eq 1 ] && [ "$rec_commit" != "$PINNED_COMMIT" ]; then
      die \
        "The staged 7zz was built from a different upstream commit." \
        "  staged binary: $rec_tag / $rec_commit" \
        "  script pin:    $PINNED_TAG / $PINNED_COMMIT" \
        "" \
        "Rebuild:  vendor/build-7zz.sh"
    fi

    case "$rec_mod" in
      NONE*) ok "provenance: upstream $rec_tag, modifications NONE" ;;
      *)
        if [ "$ALLOW_DIRTY" -eq 1 ]; then
          warn "provenance: $rec_mod  (accepted because --allow-dirty)"
        else
          die \
            "The staged 7zz was built from a MODIFIED source tree:" \
            "    Modifications: $rec_mod" \
            "" \
            "This binary must never be shipped. Rebuild from a clean checkout:" \
            "    git -C '$SRC_DIR' clean -fdx && git -C '$SRC_DIR' checkout -- ." \
            "    vendor/build-7zz.sh"
        fi
        ;;
    esac
  elif [ "$strict_provenance" -eq 1 ]; then
    warn "no BUILD-INFO.txt beside the binary; provenance cannot be verified"
  fi

  # --- it actually runs, and it is the right 7-Zip ------------------------
  local banner
  # `7zz` prints a BLANK first line before the banner, so `head -n 1` returns "".
  # Take the first non-empty line that actually mentions 7-Zip instead.
  if ! banner="$("$bin" i 2>&1 | grep -m 1 '7-Zip')"; then
    die "7zz failed to execute: $bin"
  fi
  case "$banner" in
    *"7-Zip (z) $EXPECTED_VERSION"*)
      ok "runs on $(host_arch): $banner"
      ;;
    *)
      die \
        "7zz reports an unexpected version." \
        "  expected banner to contain: 7-Zip (z) $EXPECTED_VERSION" \
        "  got: $banner"
      ;;
  esac

  # The foreign slice: best effort. On Apple silicon this needs Rosetta 2.
  local foreign
  if [ "$(host_arch)" = "arm64" ]; then foreign="x86_64"; else foreign="arm64"; fi
  if /usr/bin/arch -"$foreign" "$bin" i >/dev/null 2>&1; then
    ok "runs on $foreign as well"
  else
    if [ "$foreign" = "x86_64" ]; then
      warn "could not execute the x86_64 slice (Rosetta 2 not installed?)."
      info "install it with:  softwareupdate --install-rosetta --agree-to-license"
      info "the slice is present and correctly formed; only the smoke test was skipped"
    else
      warn "could not execute the arm64 slice on this Intel host (expected)"
    fi
  fi

  # --- the shipped helper MUST retain the RAR handlers --------------------
  # We ship 7zz as a separate process precisely so it can carry full RAR
  # extraction. A build with DISABLE_RAR=1 / DISABLE_RAR_COMPRESS=1 (which is
  # what Homebrew's `sevenzip` formula produces) silently breaks RAR for users.
  if "$bin" i 2>/dev/null | grep -q 'Rar5'; then
    ok "RAR + Rar5 handlers present (full extraction available)"
  else
    die \
      "This 7zz has no Rar5 handler — it was built with DISABLE_RAR" \
      "or DISABLE_RAR_COMPRESS. RAR extraction would be silently broken." \
      "" \
      "Do not use Homebrew's 7zz. Build with this script, which passes no" \
      "RAR-disabling flags. (Those flags belong to the FUTURE in-process XPC" \
      "engine only — see vendor/README.md.)"
  fi

  # --- signature ----------------------------------------------------------
  if have codesign; then
    if codesign --verify --strict "$bin" >/dev/null 2>&1; then
      local sigline
      sigline="$(codesign -dv "$bin" 2>&1 | awk -F'=' '/^Signature|^Authority/{print $0}' | head -n 2 | tr '\n' ' ')"
      ok "code signature valid  ${sigline:-}"
    else
      warn "code signature is invalid or absent; Xcode will re-sign on copy"
    fi
  fi

  return $failures
}

# --------------------------------------------------------------------------
# check mode
# --------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  require_tools
  verify_binary "$CHECK_BINARY" 1
  printf '\n%s7zz OK%s  %s\n' "$C_GRN" "$C_OFF" "$CHECK_BINARY" >&2
  exit 0
fi

# --------------------------------------------------------------------------
# build mode
# --------------------------------------------------------------------------
require_tools

if [ -z "$JOBS" ]; then
  JOBS="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || printf '4')"
fi

case "$(make --version 2>/dev/null | head -n 1)" in
  *"GNU Make"*) : ;;
  *) warn "'make' does not identify as GNU Make; upstream's makefile.gcc requires it" ;;
esac

printf '\n' >&2
step "ArcSeven vendor build — upstream 7-Zip $PINNED_TAG"
info "source      $SRC_DIR"
info "staging     $STAGING_DIR"
info "jobs        $JOBS"
info "deployment  macOS $DEPLOYMENT_TARGET"
info "archs       $REQUIRED_ARCHS"
printf '\n' >&2

verify_pristine

mkdir -p "$STAGING_DIR"
# Make the staging directory self-ignoring: it holds build output, never source.
if [ ! -f "$STAGING_DIR/.gitignore" ]; then
  printf '# Build output — never committed. Produced by vendor/build-7zz.sh\n*\n' \
    >"$STAGING_DIR/.gitignore"
fi

if [ "$DO_CLEAN" -eq 1 ]; then
  step "Cleaning previous object directories"
  rm -rf "$SRC_DIR/$BUNDLE_SUBDIR/b/m_arm64" "$SRC_DIR/$BUNDLE_SUBDIR/b/m_x64"
  ok "removed b/m_arm64 and b/m_x64"
fi

build_slice arm64  "$ARM64_MAKEFILE" "$ARM64_OUT"; ARM64_BIN="$SLICE_BIN"
build_slice x86_64 "$X64_MAKEFILE"   "$X64_OUT";   X64_BIN="$SLICE_BIN"

ARM64_SUM="$(sha256_of "$ARM64_BIN")"
X64_SUM="$(sha256_of "$X64_BIN")"

# --------------------------------------------------------------------------
# lipo
# --------------------------------------------------------------------------
step "Creating the universal binary"
TMP_FAT="$STAGING_DIR/.7zz.fat.$$"
trap 'rm -f "$TMP_FAT"' EXIT

/usr/bin/lipo -create "$ARM64_BIN" "$X64_BIN" -output "$TMP_FAT" || die \
  "lipo -create failed." \
  "  arm64:  $ARM64_BIN" \
  "  x86_64: $X64_BIN"

chmod 755 "$TMP_FAT"
UNSIGNED_SUM="$(sha256_of "$TMP_FAT")"

LIPO_INFO="$(/usr/bin/lipo -info "$TMP_FAT")"
info "$LIPO_INFO"

GOT_ARCHS="$(archs_of "$TMP_FAT")"
WANT_ARCHS="$(expected_archs_sorted)"
[ "$GOT_ARCHS" = "$WANT_ARCHS" ] || die \
  "lipo produced the wrong architecture set." \
  "  expected: $WANT_ARCHS" \
  "  got:      $GOT_ARCHS"
ok "universal: $GOT_ARCHS"

# --------------------------------------------------------------------------
# sign
# --------------------------------------------------------------------------
if [ "$DO_SIGN" -eq 1 ] && have codesign; then
  step "Codesigning (identity: $SIGN_IDENTITY)"
  # lipo strips the per-slice linker signatures; re-sign so the binary is
  # executable on Apple silicon and so `codesign --verify` is meaningful.
  codesign --remove-signature "$TMP_FAT" >/dev/null 2>&1 || true
  if [ "$SIGN_IDENTITY" = "-" ]; then
    TS_FLAG="--timestamp=none"      # ad-hoc: no notary timestamp is possible
  else
    TS_FLAG="--timestamp"           # Developer ID: a secure timestamp is required
  fi
  if codesign --force --options runtime "$TS_FLAG" \
      --sign "$SIGN_IDENTITY" "$TMP_FAT" >/dev/null 2>&1; then
    ok "signed"
  else
    warn "codesign failed with identity '$SIGN_IDENTITY'; leaving the binary ad-hoc"
    warn "the app will still run locally, but notarisation will reject the bundle"
  fi
fi

FINAL_SUM="$(sha256_of "$TMP_FAT")"

# --------------------------------------------------------------------------
# install into staging
# --------------------------------------------------------------------------
step "Installing into the staging path consumed by Xcode"
mv -f "$TMP_FAT" "$STAGED_BIN"
trap - EXIT
chmod 755 "$STAGED_BIN"

printf '%s  7zz\n' "$FINAL_SUM" >"$STAGED_SUM"

if [ "$ALLOW_DIRTY" -eq 1 ]; then
  MOD_STATE="YES — SOURCE TREE DIVERGES FROM THE PIN. NOT DISTRIBUTABLE."
else
  MOD_STATE="NONE"
fi

cat >"$STAGED_INFO" <<EOF
7zz helper binary — build provenance
=====================================
Produced by: vendor/build-7zz.sh (ArcSeven)
Built:       $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Upstream project: 7-Zip by Igor Pavlov
Upstream source:  $UPSTREAM_URL
Upstream tag:     $PINNED_TAG
Upstream commit:  $PINNED_COMMIT
Modifications:    $MOD_STATE

Build recipe (run verbatim, from CPP/7zip/Bundles/Alone2):
  make -j $JOBS -f $ARM64_MAKEFILE
  make -j $JOBS -f $X64_MAKEFILE
  lipo -create b/m_arm64/7zz b/m_x64/7zz -output 7zz
No RAR-disabling flags are passed; the shipped helper retains full RAR extraction.

Toolchain:
  $(clang --version 2>/dev/null | head -n 1)
  macOS SDK $(xcrun --sdk macosx --show-sdk-version 2>/dev/null || printf 'unknown')
  MACOSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET

Architecture: $LIPO_INFO

SHA-256
  arm64 slice           $ARM64_SUM
  x86_64 slice          $X64_SUM
  universal, unsigned   $UNSIGNED_SUM
  universal, as staged  $FINAL_SUM

Bundle destination: ArcSeven.app/Contents/Helpers/7zz
7zz is executed as a SEPARATE PROCESS. It is never linked into ArcSeven.
See vendor/README.md for why that separation is load-bearing.
EOF

ok "$STAGED_BIN"
ok "$STAGED_SUM"
ok "$STAGED_INFO"

# --------------------------------------------------------------------------
# final verification of the thing we just staged
# --------------------------------------------------------------------------
printf '\n' >&2
verify_binary "$STAGED_BIN" 0

printf '\n' >&2
printf '%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_GRN" "$C_OFF" >&2
printf '%s║  7zz %s universal helper staged%s\n' "$C_GRN" "$PINNED_TAG" "$C_OFF" >&2
printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_GRN" "$C_OFF" >&2
printf '  binary   %s\n' "$STAGED_BIN" >&2
printf '  sha256   %s\n' "$FINAL_SUM" >&2
printf '  archs    %s\n' "$GOT_ARCHS" >&2
if [ "$ALLOW_DIRTY" -eq 1 ]; then
  printf '\n%s  WARNING: built with --allow-dirty. NOT DISTRIBUTABLE.%s\n' "$C_RED" "$C_OFF" >&2
fi
printf '\n' >&2
printf '  Record %s in THIRD_PARTY_LICENSES/7-Zip/VERSION.txt before tagging a release.\n' "$FINAL_SUM" >&2
printf '\n' >&2
