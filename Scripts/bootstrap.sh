#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Rajesh D'Monte
#
# bootstrap.sh — one-shot developer setup for ArcSeven (module: ArcSeven).
#
# Fresh clone to a buildable Xcode project in one command:
#
#     git clone https://github.com/havokentity/ArcSeven.git
#     cd ArcSeven
#     ./Scripts/bootstrap.sh
#
# What it does, in order:
#   1. Checks Xcode, Swift, the macOS SDK and git meet the project minimums.
#   2. Configures vendor/7zip as a git submodule if it is not configured yet,
#      initialises it, and pins it to the exact upstream commit ArcSeven ships.
#   3. Runs vendor/build-7zz.sh to produce the universal 7zz helper.
#   4. Installs XcodeGen if missing — ASKING FIRST, never silently.
#   5. Generates ArcSeven.xcodeproj from project.yml.
#   6. Prints next steps.
#
# It is idempotent: re-running it on an already-set-up checkout is a no-op
# apart from re-verifying everything.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Project minimums. Keep in sync with project.yml and docs/ARCHITECTURE.md.
# --------------------------------------------------------------------------
MIN_XCODE="26.0"          # macOS 26 SDK, Swift 6 strict concurrency
MIN_SWIFT="6.0"
MIN_SDK="26.0"
MIN_HOST_MACOS="15.0"     # what Xcode 26 itself needs to run
DEPLOYMENT_TARGET="14.0"  # what ArcSeven.app targets

# The upstream 7-Zip pin. build-7zz.sh holds the authoritative copy; these must
# agree with it and this script verifies that they do.
PINNED_TAG="26.02"
PINNED_COMMIT="f9d78aff31a5f2521ae7ddbdc97c4a8855808959"
UPSTREAM_URL="https://github.com/ip7z/7zip.git"

SUBMODULE_PATH="vendor/7zip"
SUBMODULE_NAME="7zip"

XCODEPROJ="ArcSeven.xcodeproj"
PROJECT_SPEC="project.yml"

# --------------------------------------------------------------------------
# Options
# --------------------------------------------------------------------------
ASSUME_YES=0
SKIP_7ZZ=0
SKIP_PROJECT=0
CLEAN_7ZZ=0

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_BLD=$'\033[1m';    C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BLD=""; C_DIM=""; C_OFF=""
fi

STEP_N=0
phase() {
  STEP_N=$((STEP_N + 1))
  printf '\n%s[%d/6] %s%s\n' "$C_BLU$C_BLD" "$STEP_N" "$*" "$C_OFF"
}
ok()   { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
info() { printf '  %s%s%s\n'   "$C_DIM" "$*" "$C_OFF"; }

die() {
  printf '\n%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_RED" "$C_OFF" >&2
  printf '%s║  bootstrap failed%s\n' "$C_RED" "$C_OFF" >&2
  printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_RED" "$C_OFF" >&2
  printf '\n' >&2
  while [ "$#" -gt 0 ]; do printf '%s\n' "$1" >&2; shift; done
  printf '\n' >&2
  exit 1
}

usage() {
  cat <<EOF
bootstrap.sh — one-shot developer setup for ArcSeven

USAGE
  ./Scripts/bootstrap.sh [options]

OPTIONS
  -y, --yes        Answer yes to install prompts (currently: XcodeGen via
                   Homebrew). Without it, an interactive prompt is shown; in a
                   non-interactive shell the script stops and prints the exact
                   command for you to run yourself.
  --skip-7zz       Do not build the vendored 7zz helper
  --clean-7zz      Rebuild 7zz from scratch (passes --clean to build-7zz.sh)
  --skip-project   Do not install XcodeGen or generate the .xcodeproj
  -h, --help       This text

NOTHING IS INSTALLED WITHOUT YOUR SAY-SO. The only package this script would
ever install is XcodeGen, and it always tells you the command first.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -y|--yes)       ASSUME_YES=1 ;;
    --skip-7zz)     SKIP_7ZZ=1 ;;
    --clean-7zz)    CLEAN_7ZZ=1 ;;
    --skip-project) SKIP_PROJECT=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# version_ge HAVE WANT -> true if HAVE >= WANT (dotted numeric compare)
version_ge() {
  [ -n "${1:-}" ] || return 1
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

# Ask the user a yes/no question. --yes short-circuits it. In a non-interactive
# shell there is no prompt and the answer is NO — we never guess on the user's
# behalf when the action installs software.
confirm() {
  local prompt="$1" reply
  if [ "$ASSUME_YES" -eq 1 ]; then
    info "--yes given; proceeding without asking"
    return 0
  fi
  if [ ! -t 0 ]; then
    return 1
  fi
  printf '\n  %s%s%s [y/N] ' "$C_BLD" "$prompt" "$C_OFF"
  read -r reply || reply=""
  case "$reply" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# --------------------------------------------------------------------------
# Locate the repository
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

BUILD_7ZZ="$REPO_ROOT/vendor/build-7zz.sh"

printf '%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_BLD" "$C_OFF"
printf '%s║  ArcSeven — developer bootstrap                                         ║%s\n' "$C_BLD" "$C_OFF"
printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_BLD" "$C_OFF"
printf '  repository   %s\n' "$REPO_ROOT"
printf '  app          ArcSeven    module ArcSeven    bundle com.havokentity.ArcSeven\n'
printf '  vendored     7-Zip %s (%s)\n' "$PINNED_TAG" "$PINNED_COMMIT"

# ==========================================================================
phase "Checking the toolchain"
# ==========================================================================

[ "$(uname -s)" = "Darwin" ] || die "ArcSeven is a macOS application; this script only runs on macOS."

HOST_MACOS="$(sw_vers -productVersion 2>/dev/null || printf '')"
if version_ge "$HOST_MACOS" "$MIN_HOST_MACOS"; then
  ok "macOS $HOST_MACOS"
else
  warn "macOS $HOST_MACOS — Xcode $MIN_XCODE expects macOS $MIN_HOST_MACOS or later"
fi

have git || die \
  "git not found." \
  "Install the Xcode command line tools:  xcode-select --install"
ok "git $(git --version | awk '{print $3}')"

git rev-parse --git-dir >/dev/null 2>&1 || die \
  "$REPO_ROOT is not a git repository." \
  "Clone the project rather than copying the files:" \
  "    git clone https://github.com/havokentity/ArcSeven.git"

DEVELOPER_DIR_PATH="$(xcode-select -p 2>/dev/null || printf '')"
case "$DEVELOPER_DIR_PATH" in
  *CommandLineTools*|"")
    die \
      "The active developer directory is not a full Xcode installation:" \
      "    ${DEVELOPER_DIR_PATH:-<none>}" \
      "" \
      "ArcSeven needs Xcode $MIN_XCODE or later (macOS $MIN_SDK SDK, Swift $MIN_SWIFT)." \
      "Install Xcode, then point the tools at it:" \
      "    sudo xcode-select --switch /Applications/Xcode.app"
    ;;
esac

XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2; exit}')"
version_ge "$XCODE_VERSION" "$MIN_XCODE" || die \
  "Xcode ${XCODE_VERSION:-<unknown>} is too old." \
  "  required: Xcode $MIN_XCODE or later" \
  "  active:   $DEVELOPER_DIR_PATH" \
  "" \
  "ArcSeven is built against the macOS $MIN_SDK SDK with Swift $MIN_SWIFT strict" \
  "concurrency. If you have a newer Xcode installed alongside, select it:" \
  "    sudo xcode-select --switch /Applications/Xcode.app"
ok "Xcode $XCODE_VERSION  ($DEVELOPER_DIR_PATH)"

SWIFT_VERSION="$(xcrun swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
version_ge "$SWIFT_VERSION" "$MIN_SWIFT" || die \
  "Swift ${SWIFT_VERSION:-<unknown>} is too old." \
  "  required: Swift $MIN_SWIFT or later (the project builds in Swift 6 language mode" \
  "            with strict concurrency; Swift 5 toolchains cannot compile it)"
ok "Swift $SWIFT_VERSION"

SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || printf '')"
if version_ge "$SDK_VERSION" "$MIN_SDK"; then
  ok "macOS SDK $SDK_VERSION  (deployment target $DEPLOYMENT_TARGET)"
else
  warn "macOS SDK ${SDK_VERSION:-<unknown>} is older than $MIN_SDK; some APIs used by ArcSeven will not resolve"
fi

# ==========================================================================
phase "Vendoring upstream 7-Zip $PINNED_TAG"
# ==========================================================================

[ -x "$BUILD_7ZZ" ] || die \
  "vendor/build-7zz.sh is missing or not executable:" \
  "    $BUILD_7ZZ" \
  "" \
  "Fix:  chmod +x vendor/build-7zz.sh"

# The pin lives in build-7zz.sh. If these two files ever disagree, the build
# would verify one thing and the submodule would hold another; stop instead.
BUILD_PIN_COMMIT="$(sed -n 's/^PINNED_COMMIT="\([0-9a-f]*\)".*/\1/p' "$BUILD_7ZZ" | head -n 1)"
BUILD_PIN_TAG="$(sed -n 's/^PINNED_TAG="\([^"]*\)".*/\1/p' "$BUILD_7ZZ" | head -n 1)"
if [ "$BUILD_PIN_COMMIT" != "$PINNED_COMMIT" ] || [ "$BUILD_PIN_TAG" != "$PINNED_TAG" ]; then
  die \
    "The upstream pin disagrees between the two scripts:" \
    "  Scripts/bootstrap.sh : $PINNED_TAG / $PINNED_COMMIT" \
    "  vendor/build-7zz.sh  : $BUILD_PIN_TAG / $BUILD_PIN_COMMIT" \
    "" \
    "vendor/build-7zz.sh is authoritative. Make them agree before continuing," \
    "and follow the bump checklist in vendor/README.md."
fi

submodule_is_configured() {
  [ -f "$REPO_ROOT/.gitmodules" ] || return 1
  git config -f "$REPO_ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | grep -qx "$SUBMODULE_PATH"
}

submodule_is_populated() {
  [ -e "$REPO_ROOT/$SUBMODULE_PATH/.git" ] && \
  git -C "$REPO_ROOT/$SUBMODULE_PATH" rev-parse --git-dir >/dev/null 2>&1
}

SUBMODULE_ADDED=0

if submodule_is_configured; then
  ok ".gitmodules already declares $SUBMODULE_PATH"
else
  warn "$SUBMODULE_PATH is not configured as a submodule yet — configuring it now"
  info "upstream: $UPSTREAM_URL"

  if [ -e "$REPO_ROOT/$SUBMODULE_PATH" ]; then
    # An empty directory is fine (git submodule add tolerates it); anything
    # else is a hand-vendored tree we must not silently clobber.
    if [ -n "$(ls -A "$REPO_ROOT/$SUBMODULE_PATH" 2>/dev/null || true)" ]; then
      die \
        "$SUBMODULE_PATH already exists and is not empty, but it is not a" \
        "configured submodule. That is exactly the situation the vendoring" \
        "policy forbids: an unverifiable copy of upstream source." \
        "" \
        "Inspect it, then remove it and re-run:" \
        "    rm -rf '$REPO_ROOT/$SUBMODULE_PATH'" \
        "    ./Scripts/bootstrap.sh"
    fi
    rmdir "$REPO_ROOT/$SUBMODULE_PATH"
  fi

  git submodule add --name "$SUBMODULE_NAME" "$UPSTREAM_URL" "$SUBMODULE_PATH" \
    || die \
      "git submodule add failed." \
      "Check network access to github.com, then re-run ./Scripts/bootstrap.sh"
  SUBMODULE_ADDED=1
  ok "submodule added"
fi

if ! submodule_is_populated; then
  info "initialising the submodule working tree…"
  git submodule update --init --recursive "$SUBMODULE_PATH" \
    || die \
      "git submodule update --init failed for $SUBMODULE_PATH." \
      "Try:  git submodule sync --recursive && git submodule update --init --recursive"
fi
submodule_is_populated || die "$SUBMODULE_PATH is still not a usable git work tree."

# Pin to the exact commit. The commit SHA is the authority, not the tag name:
# upstream tags are lightweight and could in principle be moved.
CURRENT_SHA="$(git -C "$SUBMODULE_PATH" rev-parse HEAD 2>/dev/null || printf '')"
if [ "$CURRENT_SHA" = "$PINNED_COMMIT" ]; then
  ok "vendor/7zip at $PINNED_TAG ($PINNED_COMMIT)"
else
  info "checking out $PINNED_TAG ($PINNED_COMMIT)…"
  if ! git -C "$SUBMODULE_PATH" cat-file -e "$PINNED_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SUBMODULE_PATH" fetch --tags --force origin >/dev/null 2>&1 || true
  fi
  if ! git -C "$SUBMODULE_PATH" cat-file -e "$PINNED_COMMIT^{commit}" 2>/dev/null; then
    git -C "$SUBMODULE_PATH" fetch origin "refs/tags/$PINNED_TAG:refs/tags/$PINNED_TAG" >/dev/null 2>&1 || true
  fi
  if ! git -C "$SUBMODULE_PATH" cat-file -e "$PINNED_COMMIT^{commit}" 2>/dev/null; then
    # Last resort: the checkout is shallow and does not contain the commit.
    git -C "$SUBMODULE_PATH" fetch --unshallow origin >/dev/null 2>&1 || true
  fi
  git -C "$SUBMODULE_PATH" cat-file -e "$PINNED_COMMIT^{commit}" 2>/dev/null || die \
    "Could not fetch upstream commit $PINNED_COMMIT ($PINNED_TAG) from" \
    "$UPSTREAM_URL." \
    "" \
    "Check network access, then:" \
    "    git -C $SUBMODULE_PATH fetch --tags origin" \
    "    git -C $SUBMODULE_PATH checkout --detach $PINNED_COMMIT"

  git -C "$SUBMODULE_PATH" checkout --detach "$PINNED_COMMIT" >/dev/null 2>&1 || die \
    "git checkout $PINNED_COMMIT failed inside $SUBMODULE_PATH." \
    "The working tree may have local modifications. Inspect it, then:" \
    "    git -C $SUBMODULE_PATH checkout -- . && git -C $SUBMODULE_PATH clean -fdx"
  ok "vendor/7zip checked out at $PINNED_TAG ($PINNED_COMMIT)"
fi

if [ "$SUBMODULE_ADDED" -eq 1 ]; then
  git add "$SUBMODULE_PATH" .gitmodules
  warn "the new submodule is staged but NOT committed. Commit it:"
  info "git commit -m 'vendor: pin 7-Zip $PINNED_TAG as an unmodified submodule'"
elif ! git diff --quiet -- "$SUBMODULE_PATH" 2>/dev/null; then
  warn "the gitlink recorded for $SUBMODULE_PATH differs from $PINNED_TAG."
  info "if the pin is correct, record it:  git add $SUBMODULE_PATH && git commit"
fi

# ==========================================================================
phase "Building the 7zz helper"
# ==========================================================================

CHECK_OUT=""
if [ "$SKIP_7ZZ" -eq 1 ]; then
  warn "skipped (--skip-7zz). The app will not launch without Contents/Helpers/7zz."
elif [ "$CLEAN_7ZZ" -eq 0 ] && CHECK_OUT="$("$BUILD_7ZZ" --check 2>&1)"; then
  ok "an up-to-date universal 7zz is already staged"
  printf '%s\n' "$CHECK_OUT" | sed -n 's/^  ok /       /p' | while IFS= read -r l; do info "$l"; done
else
  info "building both slices from vendor/7zip — this takes a few minutes"
  if [ "$CLEAN_7ZZ" -eq 1 ]; then
    "$BUILD_7ZZ" --clean || die "vendor/build-7zz.sh failed. See its output above."
  else
    "$BUILD_7ZZ" || die "vendor/build-7zz.sh failed. See its output above."
  fi
  ok "7zz staged at vendor/bin/7zz  (project.yml copies it to Contents/Helpers)"
fi

# ==========================================================================
phase "Checking for XcodeGen"
# ==========================================================================

XCODEGEN_READY=0
if [ "$SKIP_PROJECT" -eq 1 ]; then
  warn "skipped (--skip-project)"
elif have xcodegen; then
  ok "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $NF}')  ($(command -v xcodegen))"
  XCODEGEN_READY=1
else
  warn "xcodegen is not installed."
  info "ArcSeven keeps $XCODEPROJ out of git and generates it from $PROJECT_SPEC,"
  info "so XcodeGen is required to produce a project you can open."
  printf '\n  %sThis script would like to run:%s\n' "$C_BLD" "$C_OFF"
  printf '      %sbrew install xcodegen%s\n' "$C_BLD" "$C_OFF"

  if ! have brew; then
    die \
      "Homebrew is not installed, so XcodeGen cannot be installed automatically." \
      "" \
      "Install XcodeGen by whichever route you prefer, then re-run this script:" \
      "    brew install xcodegen                      # after installing Homebrew" \
      "    mint install yonaskolb/xcodegen            # via Mint" \
      "    https://github.com/yonaskolb/XcodeGen/releases   # prebuilt .zip" \
      "" \
      "Or skip project generation entirely:  ./Scripts/bootstrap.sh --skip-project"
  fi

  if confirm "Install XcodeGen with Homebrew now?"; then
    brew install xcodegen || die "brew install xcodegen failed."
    have xcodegen || die "brew reported success but xcodegen is still not on PATH."
    ok "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $NF}') installed"
    XCODEGEN_READY=1
  else
    die \
      "XcodeGen was NOT installed — nothing has been changed on your system." \
      "" \
      "Run the install yourself and then re-run this script:" \
      "    brew install xcodegen" \
      "    ./Scripts/bootstrap.sh" \
      "" \
      "Or re-run this script with --yes to approve the install up front:" \
      "    ./Scripts/bootstrap.sh --yes" \
      "" \
      "Or skip project generation:" \
      "    ./Scripts/bootstrap.sh --skip-project"
  fi
fi

# ==========================================================================
phase "Generating $XCODEPROJ"
# ==========================================================================

PROJECT_GENERATED=0
if [ "$SKIP_PROJECT" -eq 1 ]; then
  warn "skipped (--skip-project)"
elif [ ! -f "$REPO_ROOT/$PROJECT_SPEC" ]; then
  warn "$PROJECT_SPEC not found at the repository root — nothing to generate."
  info "the XcodeGen spec defines the ArcSeven target, the app extensions, and"
  info "the Copy Files phase that puts vendor/bin/7zz into"
  info "ArcSeven.app/Contents/Helpers. Without it there is no Xcode project."
elif [ "$XCODEGEN_READY" -eq 1 ]; then
  xcodegen generate --spec "$REPO_ROOT/$PROJECT_SPEC" --project "$REPO_ROOT" \
    || die "xcodegen generate failed. Check $PROJECT_SPEC."
  [ -d "$REPO_ROOT/$XCODEPROJ" ] || warn "xcodegen succeeded but $XCODEPROJ was not created; check the 'name:' key in $PROJECT_SPEC"
  ok "$XCODEPROJ generated from $PROJECT_SPEC"
  PROJECT_GENERATED=1
fi

# ==========================================================================
phase "Done"
# ==========================================================================

printf '\n%s╔══════════════════════════════════════════════════════════════════════╗%s\n' "$C_GRN" "$C_OFF"
printf '%s║  bootstrap complete%s\n' "$C_GRN" "$C_OFF"
printf '%s╚══════════════════════════════════════════════════════════════════════╝%s\n' "$C_GRN" "$C_OFF"

printf '\n%sNext steps%s\n' "$C_BLD" "$C_OFF"
if [ "$PROJECT_GENERATED" -eq 1 ]; then
  printf '  1. Open the project\n'
  printf '       open %s\n' "$XCODEPROJ"
  printf '  2. Select the %sArcSeven%s scheme and press ⌘R.\n' "$C_BLD" "$C_OFF"
  printf '  3. Run the tests with ⌘U, or from the terminal:\n'
  printf '       xcodebuild test -project %s -scheme ArcSeven -destination "platform=macOS"\n' "$XCODEPROJ"
else
  printf '  1. Finish project generation once %s exists:\n' "$PROJECT_SPEC"
  printf '       xcodegen generate\n'
  printf '  2. Then:  open %s\n' "$XCODEPROJ"
fi
printf '\n%sGood to know%s\n' "$C_BLD" "$C_OFF"
printf '  • %s is generated, never committed. Re-run %sxcodegen generate%s after\n' "$XCODEPROJ" "$C_BLD" "$C_OFF"
printf '    editing %s, or just re-run this script.\n' "$PROJECT_SPEC"
printf '  • vendor/7zip is an UNMODIFIED submodule pinned to upstream %s.\n' "$PINNED_TAG"
printf '    Never patch it. vendor/build-7zz.sh refuses to build a modified tree,\n'
printf '    and that refusal is a licence requirement, not a style preference.\n'
printf '    Read vendor/README.md before touching anything under vendor/.\n'
printf '  • 7zz is copied into ArcSeven.app/Contents/Helpers and driven as a\n'
printf '    subprocess. It is never linked into the app.\n'
printf '  • Rebuild the helper any time with:  ./vendor/build-7zz.sh\n'
printf '    Verify an existing one with:       ./vendor/build-7zz.sh --check\n'
printf '  • Release builds sign with "Developer ID Application: Rajesh DMonte (HAMH7N3PJR)".\n'
printf '    ArcSeven is not distributed through the Mac App Store — see docs/ARCHITECTURE.md.\n'
printf '\n'
