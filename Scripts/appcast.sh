#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# appcast.sh — sign the release DMGs with Sparkle's EdDSA key and emit appcast.xml.
#
#   Scripts/appcast.sh dist/
#
# Contract with .github/workflows/release.yml:
#
#   * SPARKLE_ED_PRIVATE_KEY unset  -> print why, write nothing, exit 0. That is a
#     convenience for LOCAL runs, where nobody has the CI secret and nobody is publishing
#     anything. It is no longer what happens in CI: release.yml now treats an unset key as
#     fatal for a stable tag, because a stable release with no appcast.xml becomes
#     `releases/latest` and 404s the SUFeedURL burned into every installed copy. Do not
#     "fix" release.yml to match this exit code; the asymmetry is the point.
#   * SPARKLE_ED_PRIVATE_KEY set but sign_update missing -> exit non-zero, loudly. A
#     silently unsigned appcast is worse than no appcast: Sparkle refuses unsigned
#     updates, so the failure would only show up on a user's machine, weeks later, as
#     "the updater never works".
#
# WHY THIS EXISTS RATHER THAN generate_appcast. Sparkle's generate_appcast wants a folder
# it can own, reads the private key from the login keychain by default, invents the
# enclosure URL from a --download-url-prefix, and rewrites any appcast it finds. We need
# the enclosure to point at a GitHub Releases asset whose URL contains the tag, we need
# the key to come from a CI secret on stdin and never touch disk, and we need the output
# to be reproducible from the DMG alone. That is fifty lines of shell, so it is fifty
# lines of shell.
#
# WHAT SPARKLE COMPARES. sparkle:version is CFBundleVersion — the monotonic build number,
# not the marketing version. It is read out of the app inside each DMG rather than guessed
# from the file name, because guessing it is how a release ships that no existing install
# is ever offered. See docs/RELEASING.md §9.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# --------------------------------------------------------------------------------------
# Knobs. Every one has a working default; CI sets none of them.
# --------------------------------------------------------------------------------------
APPCAST_REPO="${APPCAST_REPO:-havokentity/ArcSeven}"
APPCAST_TITLE="${APPCAST_TITLE:-ArcSeven}"
# Where the DMG will actually live once the release is published. release.yml uploads the
# assets to the tag it is building, and the tag is v<marketing version>.
APPCAST_DOWNLOAD_BASE="${APPCAST_DOWNLOAD_BASE:-https://github.com/${APPCAST_REPO}/releases/download}"
APPCAST_RELEASE_BASE="${APPCAST_RELEASE_BASE:-https://github.com/${APPCAST_REPO}/releases/tag}"
# Must match SUFeedURL in Info.plist, and must be the *latest* alias so a two-year-old
# install still finds the current feed.
APPCAST_FEED_URL="${APPCAST_FEED_URL:-https://github.com/${APPCAST_REPO}/releases/latest/download/appcast.xml}"
# Matches MACOSX_DEPLOYMENT_TARGET in project.yml. Keep the two in step.
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-14.0}"

die() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

usage() {
    cat <<USAGE
usage: $SCRIPT_NAME <dist-dir>

Signs every *.dmg in <dist-dir> with Sparkle's EdDSA private key and writes
<dist-dir>/appcast.xml.

environment:
  SPARKLE_ED_PRIVATE_KEY   base64 EdDSA private key from Sparkle's generate_keys.
                           UNSET -> this script does nothing and succeeds.
  SIGN_UPDATE              explicit path to Sparkle's sign_update tool.
  APPCAST_BUILD_VERSION    CFBundleVersion, cross-checked against the DMG. Used only as a
                           fallback where hdiutil cannot attach an image.
  APPCAST_SHORT_VERSION    CFBundleShortVersionString, same rules.
  APPCAST_REPO             default $APPCAST_REPO
  APPCAST_DOWNLOAD_BASE    default <github>/releases/download
  APPCAST_FEED_URL         default <github>/releases/latest/download/appcast.xml
  MINIMUM_SYSTEM_VERSION   default $MINIMUM_SYSTEM_VERSION
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; die "no <dist-dir> given" ;;
esac

DIST_DIR="$1"
[ -d "$DIST_DIR" ] || die "not a directory: $DIST_DIR"
DIST_DIR="$(cd -- "$DIST_DIR" && pwd)"

# --------------------------------------------------------------------------------------
# The skip path. Deliberately before every other check, so a contributor without the key
# can run this by hand on a directory of unsigned DMGs and get a clean exit.
# --------------------------------------------------------------------------------------
if [ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s: SPARKLE_ED_PRIVATE_KEY is not set - no appcast will be generated.\n' "$SCRIPT_NAME"
    printf '%s: this is not a failure. See docs/SPARKLE-INTEGRATION.md.\n' "$SCRIPT_NAME"
    exit 0
fi

# --------------------------------------------------------------------------------------
# Locate sign_update
# --------------------------------------------------------------------------------------
# Sparkle ships it three ways and a release runner may have any of them: extracted from
# the release tarball's bin/, installed by Homebrew, or downloaded by SwiftPM as a binary
# artifact next to the resolved package. The SwiftPM path is the one CI actually hits,
# and it moves between Xcode versions, so it is searched rather than hard-coded.
find_sign_update() {
    if [ -n "${SIGN_UPDATE:-}" ]; then
        [ -x "$SIGN_UPDATE" ] || die "SIGN_UPDATE is set but not executable: $SIGN_UPDATE"
        printf '%s' "$SIGN_UPDATE"
        return 0
    fi

    local found
    if found="$(command -v sign_update 2>/dev/null)"; then
        printf '%s' "$found"
        return 0
    fi

    local root
    for root in \
        "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/.build" \
        "${DERIVED_DATA_PATH:-$HOME/Library/Developer/Xcode/DerivedData}" \
        "${RUNNER_TEMP:-/nonexistent}/DerivedData"
    do
        [ -d "$root" ] || continue
        found="$(/usr/bin/find "$root" -type f -name sign_update -perm -u+x -print 2>/dev/null | head -n 1)"
        if [ -n "$found" ]; then
            printf '%s' "$found"
            return 0
        fi
    done

    return 1
}

step "Locating Sparkle's sign_update"
if ! SIGN_UPDATE_BIN="$(find_sign_update)"; then
    cat >&2 <<'MISSING'
SPARKLE_ED_PRIVATE_KEY is set, but Sparkle's `sign_update` tool was not found.

Refusing to publish an unsigned appcast: Sparkle rejects an update whose enclosure
carries no sparkle:edSignature, so this would produce a feed that silently never
updates anyone.

Fix it with one of:

  * export SIGN_UPDATE=/path/to/Sparkle/bin/sign_update
  * brew install --cask sparkle
  * download the Sparkle release tarball and use its bin/sign_update
MISSING
    exit 1
fi
info "$SIGN_UPDATE_BIN"

# --------------------------------------------------------------------------------------
# Collect the DMGs
# --------------------------------------------------------------------------------------
DMGS=()
while IFS= read -r line; do
    DMGS+=("$line")
done < <(/usr/bin/find "$DIST_DIR" -maxdepth 1 -type f -name '*.dmg' | LC_ALL=C sort)

[ "${#DMGS[@]}" -gt 0 ] || die "no .dmg files in $DIST_DIR"

# --------------------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------------------
xml_escape() {
    printf '%s' "$1" | LC_ALL=C sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# CFBundleVersion and CFBundleShortVersionString, read out of the app inside the DMG by
# mounting it read-only and nobrowse. The image is detached even when PlistBuddy fails.
#
# Prints "<build>\t<short>", or nothing at all if the image could not be mounted. Not
# fatal on its own: the caller decides, because there is a legitimate second source.
read_versions_from_dmg() {
    local dmg="$1" mount app build short
    mount="$(mktemp -d "${TMPDIR:-/tmp}/arcseven-appcast.XXXXXX")"

    if ! hdiutil attach "$dmg" -readonly -nobrowse -noautoopen -mountpoint "$mount" >/dev/null 2>&1; then
        rmdir "$mount" 2>/dev/null || true
        return 1
    fi

    app="$(/usr/bin/find "$mount" -maxdepth 1 -type d -name '*.app' -print 2>/dev/null | head -n 1)"
    if [ -n "$app" ]; then
        build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || true)"
        short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$app/Contents/Info.plist" 2>/dev/null || true)"
    fi

    hdiutil detach "$mount" -quiet 2>/dev/null || hdiutil detach "$mount" -force -quiet 2>/dev/null || true
    rmdir "$mount" 2>/dev/null || true

    [ -n "$app" ] || die "no .app at the top level of $dmg"
    [ -n "$build" ] || die "CFBundleVersion is empty in $dmg (Sparkle compares this, not the marketing version)"
    [ -n "$short" ] || die "CFBundleShortVersionString is empty in $dmg"

    printf '%s\t%s' "$build" "$short"
}

# The versions for one DMG, with the shipped bundle as the authority.
#
# APPCAST_BUILD_VERSION / APPCAST_SHORT_VERSION exist because a release runner does know
# these already - release.yml passes the very same numbers to xcodebuild as
# CURRENT_PROJECT_VERSION and MARKETING_VERSION - and because hdiutil cannot attach an
# image everywhere (a container without DiskArbitration, for one). They are a fallback and
# a cross-check, never a replacement: when the DMG can be read and the two disagree, that
# is a mis-tagged build and the release stops here rather than at a user's machine.
resolve_versions() {
    local dmg="$1" from_dmg env_build="${APPCAST_BUILD_VERSION:-}" env_short="${APPCAST_SHORT_VERSION:-}"

    if from_dmg="$(read_versions_from_dmg "$dmg")"; then
        local build="${from_dmg%%$'\t'*}" short="${from_dmg##*$'\t'}"
        if [ -n "$env_build" ] && [ "$env_build" != "$build" ]; then
            die "$(basename "$dmg"): APPCAST_BUILD_VERSION=$env_build but the bundle says $build"
        fi
        if [ -n "$env_short" ] && [ "$env_short" != "$short" ]; then
            die "$(basename "$dmg"): APPCAST_SHORT_VERSION=$env_short but the bundle says $short"
        fi
        printf '%s\t%s' "$build" "$short"
        return 0
    fi

    if [ -n "$env_build" ] && [ -n "$env_short" ]; then
        # One pair of numbers cannot describe two different builds. release.yml produces
        # exactly one DMG per run, so this only fires when someone points the script at a
        # folder of archived releases with the fallback set, which would stamp every one
        # of them with the same version.
        [ "${#DMGS[@]}" -eq 1 ] || die "APPCAST_BUILD_VERSION/APPCAST_SHORT_VERSION cannot be used with \
${#DMGS[@]} DMGs - run one at a time, or make hdiutil attach work"
        printf '%s: warning: could not mount %s; trusting APPCAST_BUILD_VERSION/APPCAST_SHORT_VERSION\n' \
            "$SCRIPT_NAME" "$(basename "$dmg")" >&2
        printf '%s\t%s' "$env_build" "$env_short"
        return 0
    fi

    die "could not mount $(basename "$dmg"), and APPCAST_BUILD_VERSION/APPCAST_SHORT_VERSION are unset - \
refusing to guess CFBundleVersion"
}

# --------------------------------------------------------------------------------------
# Build the feed
# --------------------------------------------------------------------------------------
APPCAST="$DIST_DIR/appcast.xml"
ITEMS="$(mktemp "${TMPDIR:-/tmp}/arcseven-appcast-items.XXXXXX")"
trap 'rm -f "$ITEMS"' EXIT

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# --------------------------------------------------------------------------------------
# Release notes
# --------------------------------------------------------------------------------------
# Embedded in the appcast, NOT linked.
#
# `sparkle:releaseNotesLink` takes precedence over `<description>` (SUUpdateAlert.m only
# reads the description when releaseNotesURL is nil), and it makes Sparkle fetch that URL
# into a web view. Pointed at a GitHub release page that renders the entire page — nav bar,
# Sign in button, repo header — inside the update dialog. 0.1.4 shipped that way.
#
# `sparkle:format="markdown"` gets a dedicated text view with no availability gate, so the
# CHANGELOG section goes in verbatim: no HTML conversion to get wrong, no network fetch, and
# it still reads correctly if a future Sparkle renders it as plain text.
APPCAST_REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

changelog_section() {
    local version="$1" file="$APPCAST_REPO_ROOT/CHANGELOG.md"
    if [ ! -f "$file" ]; then
        # Loud, not silent: an appcast whose notes are empty looks fine and tells the user
        # nothing about what they are installing.
        info "WARNING: $file not found - release notes will be empty"
        return 0
    fi
    # Blank lines are preserved, and runs of them collapsed to one. Markdown needs the
    # blank line between a paragraph and the list or heading that follows; stripping them
    # all runs the whole section together into a single block.
    /usr/bin/awk -v want="## [$version]" '
        index($0, want) == 1 { grabbing = 1; next }
        grabbing && /^## \[/  { exit }
        grabbing              { print }
    ' "$file" | /usr/bin/awk '
        NF                 { blank = 0; started = 1; print; next }
        started && !blank  { blank = 1; print }
    ' | /usr/bin/sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

for dmg in "${DMGS[@]}"; do
    base="$(basename "$dmg")"
    step "Signing $base"

    versions="$(resolve_versions "$dmg")"
    build="${versions%%$'\t'*}"
    short="${versions##*$'\t'}"
    info "CFBundleVersion=$build  CFBundleShortVersionString=$short"

    # The key goes in on stdin. Never as an argument: argv is world-readable through ps.
    if ! sig_line="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE_BIN" --ed-key-file - "$dmg")"; then
        die "sign_update failed for $base"
    fi

    signature="$(printf '%s' "$sig_line" | LC_ALL=C sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
    length="$(printf '%s' "$sig_line" | LC_ALL=C sed -n 's/.*length="\([^"]*\)".*/\1/p')"
    [ -n "$signature" ] || die "sign_update produced no sparkle:edSignature for $base (output: $sig_line)"
    [ -n "$length" ] || die "sign_update produced no length for $base (output: $sig_line)"

    # Cross-check against the file itself. A length that disagrees with the bytes on disk
    # means the DMG changed after signing - a stapler pass, say - and Sparkle would reject
    # the download after making the user wait for it.
    actual="$(/usr/bin/stat -f%z "$dmg")"
    [ "$length" = "$actual" ] || die "length mismatch for $base: sign_update says $length, file is $actual"
    info "edSignature ok, length $length"

    tag="v$short"
    url="${APPCAST_DOWNLOAD_BASE}/${tag}/${base}"
    notes="${APPCAST_RELEASE_BASE}/${tag}"

    # A semver prerelease identifier means the tag was published as a GitHub prerelease.
    # Those get a `beta` channel tag, which UpdaterController's `allowedChannels(for:)`
    # only admits when `UpdaterPreferences.includesPrereleases` is true. Stable users must
    # never be offered one, and this is what guarantees it.
    #
    # HONEST CAVEAT: no shipped build can currently receive a beta item at all, so this
    # tag is protection against a future that has not arrived rather than a live feature.
    # Three separate things have to change before it does anything:
    #
    #   1. Nothing ever sets `UpdaterPreferences.includesPrereleases`. There is no
    #      Settings toggle bound to it, so `allowedChannels(for:)` always returns [].
    #   2. SUFeedURL is <repo>/releases/latest/download/appcast.xml, and GitHub's `latest`
    #      alias EXCLUDES prereleases - so the appcast written for a prerelease tag is
    #      never the one an installed copy fetches, opted in or not.
    #   3. release.yml uploads the appcast to the tag being built, so a prerelease's
    #      appcast lists only that prerelease. A real beta channel needs one feed that
    #      carries both stable and beta items.
    #
    # Emitting the tag anyway is still right: it costs one line, it is correct XML today,
    # and the failure mode of NOT emitting it - a prerelease silently offered to stable
    # users the day someone fixes (1) and (2) - is the one that matters.
    channel=""
    case "$short" in
        *-*) channel="            <sparkle:channel>beta</sparkle:channel>"$'\n' ;;
    esac

    {
        printf '        <item>\n'
        printf '            <title>%s %s</title>\n' "$(xml_escape "$APPCAST_TITLE")" "$(xml_escape "$short")"
        printf '            <pubDate>%s</pubDate>\n' "$PUB_DATE"
        printf '            <sparkle:version>%s</sparkle:version>\n' "$(xml_escape "$build")"
        printf '            <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$(xml_escape "$short")"
        printf '            <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' \
            "$(xml_escape "$MINIMUM_SYSTEM_VERSION")"
        printf '%s' "$channel"

        # CDATA, so the markdown needs no escaping. A literal "]]>" inside would close the
        # section early; split it across two sections, which is the standard trick and
        # produces identical text.
        section="$(changelog_section "$short")"
        if [ -n "$section" ]; then
            printf '            <description sparkle:format="markdown"><![CDATA[\n'
            printf '%s\n' "${section//]]>/]]]]><![CDATA[>}"
            printf '            ]]></description>\n'
        else
            info "no CHANGELOG section for $short - the update dialog will show no notes"
        fi
        printf '            <link>%s</link>\n' "$(xml_escape "$notes")"
        printf '            <enclosure url="%s"\n' "$(xml_escape "$url")"
        printf '                       sparkle:edSignature="%s"\n' "$(xml_escape "$signature")"
        printf '                       length="%s"\n' "$(xml_escape "$length")"
        printf '                       type="application/octet-stream" />\n'
        printf '        </item>\n'
    } >> "$ITEMS"
done

step "Writing $APPCAST"
{
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<!-- Generated by Scripts/appcast.sh. Do not hand-edit; regenerate. -->\n'
    printf '<rss version="2.0"\n'
    printf '     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"\n'
    printf '     xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    printf '    <channel>\n'
    printf '        <title>%s</title>\n' "$(xml_escape "$APPCAST_TITLE")"
    printf '        <link>%s</link>\n' "$(xml_escape "$APPCAST_FEED_URL")"
    printf '        <description>Updates for %s.</description>\n' "$(xml_escape "$APPCAST_TITLE")"
    printf '        <language>en</language>\n'
    cat "$ITEMS"
    printf '    </channel>\n'
    printf '</rss>\n'
} > "$APPCAST"

# xmllint is in the base macOS install and in every GitHub macOS runner. A malformed feed
# is invisible until an update is due, so it is caught here instead.
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APPCAST" || die "generated appcast is not well-formed XML"
    info "well-formed XML"
fi

info "$(grep -c '<item>' "$APPCAST") item(s)"
printf '\n%s: wrote %s\n' "$SCRIPT_NAME" "$APPCAST"
