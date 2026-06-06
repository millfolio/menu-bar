#!/usr/bin/env bash
#
# Build the Millpond menu-bar app (../menu) and install it as a proper macOS
# .app bundle. The bundle is marked LSUIElement, so it runs as a menu-bar agent
# with no Dock icon and no main window.
#
# Usage:
#   ./install.sh                 # install to /Applications
#   ./install.sh ~/Applications  # install to a custom directory
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Millpond"
DEST="${1:-/Applications}"
APP="$DEST/$APP_NAME.app"

echo "==> Building $APP_NAME (release)…"
( cd "$ROOT/menu" && swift build -c release )
BIN="$ROOT/menu/.build/release/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "error: build did not produce $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# Drop an icon at installer/Millpond.icns to ship one:
[[ -f "$HERE/$APP_NAME.icns" ]] && cp "$HERE/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"

# Ad-hoc codesign so Gatekeeper lets it run locally (no Developer ID required).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "    (codesign skipped — app will still run unsigned)"

echo "==> Installed: $APP"
echo "    Launch now:        open \"$APP\""
echo "    Start at login:    System Settings → General → Login Items → +"
echo "    Uninstall:         rm -rf \"$APP\""
