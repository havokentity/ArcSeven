#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (C) 2026 Rajesh D'Monte
#
# Produce the corresponding-source tarball for the bundled 7-Zip binary.
#
# THIS ARTEFACT IS NOT OPTIONAL, and the release must not be published without it.
#
# ArcSeven ships an unmodified upstream 7-Zip `7zz` as a separate executable. 7-Zip is
# LGPL-2.1-or-later, and LGPL-2.1 s4 requires that whoever receives the binary can obtain
# the corresponding source:
#
#   "If distribution of object code is made by offering access to copy from a designated
#    place, then offering equivalent access to copy the source code from the same place
#    satisfies the requirement to distribute the source code"
#
# "The same place" is the point. Linking to 7-zip.org is NOT equivalent access — that is
# a third party's server which may change or disappear. Attaching this tarball to the
# same GitHub Release as the .dmg is what discharges the obligation, which is why
# release.yml treats a failure here as fatal rather than skippable.
#
# The tarball is produced with `git archive` from the pinned submodule, so it is by
# construction the exact tree the shipped binary was built from — not a re-download that
# might differ.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/dist}"
SRC_DIR="${ARCSEVEN_7ZIP_SRC:-$REPO_ROOT/vendor/7zip}"
VERSION_FILE="$REPO_ROOT/THIRD_PARTY_LICENSES/7-Zip/VERSION.txt"

step() { printf '\033[34m==>\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m  ok\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m%s: error:\033[0m %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

[ -d "$SRC_DIR/.git" ] || [ -f "$SRC_DIR/.git" ] \
    || die "vendor/7zip is not a git checkout — run: git submodule update --init --recursive vendor/7zip"

step "Identifying the vendored 7-Zip revision"
COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
TAG="$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || true)"
VERSION="${TAG:-$(printf '%s' "$COMMIT" | cut -c1-12)}"
ok "version $VERSION  (${COMMIT})"

# A modified tree would make the tarball NOT the corresponding source, which is the one
# thing this artefact exists to guarantee.
step "Verifying the tree is unmodified"
if [ -n "$(git -C "$SRC_DIR" status --porcelain --untracked-files=no)" ]; then
    git -C "$SRC_DIR" status --short --untracked-files=no >&2
    die "vendor/7zip has local modifications — the tarball would not be the corresponding source"
fi
ok "no modifications to tracked files"

# Cross-check against the provenance record, so a submodule bump that forgets to update
# VERSION.txt is caught here rather than by a user comparing checksums.
if [ -f "$VERSION_FILE" ]; then
    RECORDED="$(sed -n 's/^7-Zip version:[[:space:]]*//p' "$VERSION_FILE" | head -n1 || true)"
    if [ -n "$RECORDED" ] && [ -n "$TAG" ] && [ "$RECORDED" != "$TAG" ]; then
        die "THIRD_PARTY_LICENSES/7-Zip/VERSION.txt records $RECORDED but the submodule is at $TAG"
    fi
    [ -n "$RECORDED" ] && ok "matches VERSION.txt ($RECORDED)"
fi

mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/7zip-${VERSION}-src.tar.xz"

step "Archiving $SRC_DIR"
# --format=tar then xz separately: `git archive` has no xz backend. The prefix gives the
# tarball a sane top-level directory instead of exploding into the current one.
git -C "$SRC_DIR" archive --format=tar --prefix="7zip-${VERSION}/" HEAD \
    | xz -9 -T0 > "$TARBALL"
[ -s "$TARBALL" ] || die "produced an empty tarball"
ok "$(basename "$TARBALL")  ($(du -h "$TARBALL" | cut -f1))"

step "Recording the checksum"
( cd "$OUT_DIR" && shasum -a 256 "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
ok "$(cut -d' ' -f1 < "$TARBALL.sha256")"

# Prove the archive is readable before a user discovers it is not.
step "Verifying the archive"
ENTRIES="$(tar -tJf "$TARBALL" | head -n 20000 | wc -l | tr -d ' ')"
[ "$ENTRIES" -gt 100 ] || die "only $ENTRIES entries — that is not a 7-Zip source tree"
tar -tJf "$TARBALL" | grep -qE "^7zip-${VERSION}/CPP/7zip/" \
    || die "archive does not contain CPP/7zip — wrong tree?"
ok "$ENTRIES entries, CPP/7zip present"

printf '\n\033[32mCorresponding source ready.\033[0m %s\n' "$TARBALL" >&2
echo "Attach this to the SAME release as the .dmg — see the header of this script." >&2
