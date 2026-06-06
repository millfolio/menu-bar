#!/usr/bin/env bash
#
# Build the Millpond menu-bar app (release) and assemble it into a macOS .app
# bundle inside the given output directory. Shared by install.sh (local install)
# and make_dmg.sh (CI / release packaging).
#
# Usage:   bundle.sh <output-dir>     # -> <output-dir>/Millpond.app
# Prints the assembled .app path on stdout (progress goes to stderr).
#
# Signing: if MILLPOND_SIGN_IDENTITY is set (a Developer ID Application identity
# or its SHA-1 hash) the app is signed with the hardened runtime + a secure
# timestamp (required for notarization). Otherwise it is ad-hoc signed -- fine
# locally, but a downloaded copy is Gatekeeper-blocked until notarized.
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

SIGN_ID="${MILLPOND_SIGN_IDENTITY:--}"
if [[ "$SIGN_ID" == "-" ]]; then
    echo "==> Ad-hoc signing (set MILLPOND_SIGN_IDENTITY for a notarizable build)" >&2
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    (codesign skipped)" >&2
else
    echo "==> Signing with Developer ID: ${SIGN_ID}" >&2
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP" >&2
fi

echo "$APP"
