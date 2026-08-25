#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Rajesh D'Monte
#
# Regenerate the app icon from Scripts/icon/MakeIcon.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/.build/AppIcon.iconset}"
rm -rf "$OUT"
swiftc -O -o "$ROOT/.build/makeicon" "$ROOT/Scripts/icon/MakeIcon.swift"
"$ROOT/.build/makeicon" "$OUT"
iconutil -c icns "$OUT" -o "$ROOT/.build/AppIcon.icns"
echo "icns: $ROOT/.build/AppIcon.icns"

# --- per-format document icons -------------------------------------------------------
# These are what Finder puts on a .7z or .zip once ArcSeven is the handler. They live in
# the app's Resources, referenced by CFBundleTypeIconFile in project.yml.
DOCS_OUT="$ROOT/.build/DocumentIcons"
DOCS_DEST="$ROOT/Sources/App/Resources/DocumentIcons"
rm -rf "$DOCS_OUT"
swiftc -O -o "$ROOT/.build/makedocicons" "$ROOT/Scripts/icon/MakeDocumentIcons.swift"
"$ROOT/.build/makedocicons" "$DOCS_OUT"
mkdir -p "$DOCS_DEST"
for set in "$DOCS_OUT"/*.iconset; do
  iconutil -c icns "$set" -o "$DOCS_DEST/$(basename "$set" .iconset).icns"
done
echo "document icons: $DOCS_DEST"
