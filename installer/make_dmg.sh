#!/usr/bin/env bash
#
# Build Millrace.app and package it into a drag-to-Applications .dmg. Runs
# headless (used by CI), so no Finder/AppleScript window styling -- just the app
# plus an /Applications alias to drag onto.
#
# Usage:   ./make_dmg.sh [output.dmg]     # default: Millrace.dmg in CWD
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Millrace"
OUT_DMG="${1:-${APP_NAME}.dmg}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

"$HERE/bundle.sh" "$STAGE" >/dev/null
ln -s /Applications "$STAGE/Applications"

echo "==> Creating ${OUT_DMG} ..." >&2
rm -f "$OUT_DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT_DMG" >&2

echo "==> Done: ${OUT_DMG}" >&2
echo "$OUT_DMG"
