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
