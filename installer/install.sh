#!/usr/bin/env bash
#
# Build the Millpond menu-bar app (../menu) and install it as a proper macOS
# .app bundle (LSUIElement agent: menu-bar only, no Dock icon).
#
# Usage:
#   ./install.sh                 # install to /Applications
#   ./install.sh ~/Applications  # install to a custom directory
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-/Applications}"

APP="$("$HERE/bundle.sh" "$DEST")"

echo "==> Installed: $APP"
echo "    Launch now:        open \"$APP\""
echo "    Start at login:    System Settings > General > Login Items > +"
echo "    Uninstall:         rm -rf \"$APP\""
