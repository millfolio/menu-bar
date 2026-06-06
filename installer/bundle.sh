#!/usr/bin/env bash
#
# Build the Millpond menu-bar app (release) and assemble it into a macOS .app
# bundle inside the given output directory. Shared by install.sh (local install)
# and make_dmg.sh (CI / release packaging).
#
# Usage:   bundle.sh <output-dir>     # -> <output-dir>/Millpond.app
# Prints the assembled .app path on stdout (progress goes to stderr).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Millpond"
OUT="${1:?usage: bundle.sh <output-dir>}"
mkdir -p "$OUT"

echo "==> Building ${APP_NAME} (release)..." >&2
( cd "$ROOT/menu" && swift build -c release ) >&2
BIN="$ROOT/menu/.build/release/${APP_NAME}"
[[ -x "$BIN" ]] || { echo "error: build did not produce $BIN" >&2; exit 1; }

APP="$OUT/${APP_NAME}.app"
echo "==> Assembling ${APP} ..." >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# Ship an icon by dropping installer/Millpond.icns:
[[ -f "$HERE/${APP_NAME}.icns" ]] && cp "$HERE/${APP_NAME}.icns" "$APP/Contents/Resources/${APP_NAME}.icns"

# Ad-hoc signature so it runs locally. NOTE: this is NOT Developer ID + notarized,
# so a copy downloaded from the internet is quarantined and Gatekeeper will block
# it until the user removes the quarantine / right-click -> Open (see README).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    (codesign skipped)" >&2

echo "$APP"
