#!/usr/bin/env bash
#
# Build Millfolio.app and package it into a signed macOS Installer .pkg that
# installs to /Applications. Unlike a drag .dmg, a .pkg runs a `preinstall`
# script (scripts/preinstall) that quits a running Millfolio first, so updating
# over a running app "just works" instead of failing with "app is in use".
#
# Usage:   ./make_pkg.sh [output.pkg]      # default: Millfolio.pkg in CWD
#
# Version: $MILLFOLIO_VERSION (default 0.1.0) — CI passes the release tag.
# Signing: $MILLFOLIO_INSTALLER_IDENTITY (a "Developer ID Installer" identity or
#          its SHA-1). When unset, the .pkg is left unsigned (productsign skipped)
#          — fine for local testing, but a distributable build must be signed +
#          notarized. The app bundle itself is signed by bundle.sh via
#          $MILLFOLIO_SIGN_IDENTITY (a "Developer ID Application" identity).
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Millfolio"
OUT_PKG="${1:-${APP_NAME}.pkg}"
BUNDLE_ID="me.millfolio.app"
VERSION="${MILLFOLIO_VERSION:-0.1.0}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Payload root mirrors the install location: <root>/Applications/Millfolio.app.
ROOT="$STAGE/root"
mkdir -p "$ROOT/Applications"
"$HERE/bundle.sh" "$ROOT/Applications" >/dev/null

# Component package: payload + the preinstall/postinstall scripts. --scripts
# bundles everything in scripts/ as installer scripts (preinstall must be +x).
COMPONENT="$STAGE/component.pkg"
echo "==> pkgbuild (${BUNDLE_ID} ${VERSION}) ..." >&2
pkgbuild \
    --root "$ROOT" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --scripts "$HERE/scripts" \
    --install-location / \
    "$COMPONENT" >&2

# Product archive (what users double-click).
PRODUCT="$STAGE/product.pkg"
echo "==> productbuild ..." >&2
productbuild --package "$COMPONENT" "$PRODUCT" >&2

rm -f "$OUT_PKG"
SIGN_ID="${MILLFOLIO_INSTALLER_IDENTITY:-}"
if [[ -n "$SIGN_ID" ]]; then
    echo "==> productsign with Developer ID Installer: ${SIGN_ID}" >&2
    productsign --sign "$SIGN_ID" "$PRODUCT" "$OUT_PKG" >&2
else
    echo "==> Unsigned .pkg (set MILLFOLIO_INSTALLER_IDENTITY to sign)" >&2
    cp "$PRODUCT" "$OUT_PKG"
fi

echo "==> Done: ${OUT_PKG}" >&2
echo "$OUT_PKG"
