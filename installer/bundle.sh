#!/usr/bin/env bash
#
# Build the Millfolio menu-bar app (release) and assemble it into a macOS .app
# bundle inside the given output directory. Shared by install.sh (local install)
# and make_pkg.sh (CI / release packaging).
#
# Usage:   bundle.sh <output-dir>     # -> <output-dir>/Millfolio.app
# Prints the assembled .app path on stdout (progress goes to stderr).
#
# Signing: if MILLFOLIO_SIGN_IDENTITY is set (a Developer ID Application identity
# or its SHA-1 hash) the app is signed with the hardened runtime + a secure
# timestamp (required for notarization). Otherwise it is ad-hoc signed -- fine
# locally, but a downloaded copy is Gatekeeper-blocked until notarized.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="Millfolio"
OUT="${1:?usage: bundle.sh <output-dir>}"
mkdir -p "$OUT"

echo "==> Building ${APP_NAME} (release)..." >&2
( cd "$ROOT/menu" && swift build -c release ) >&2
BIN="$ROOT/menu/.build/release/${APP_NAME}"
[[ -x "$BIN" ]] || { echo "error: build did not produce $BIN" >&2; exit 1; }

APP="$OUT/${APP_NAME}.app"
echo "==> Assembling ${APP} ..." >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# App icon (tracked; regenerate with `swift make_icon.swift`). Info.plist's
# CFBundleIconFile points at it.
[[ -f "$HERE/${APP_NAME}.icns" ]] && cp "$HERE/${APP_NAME}.icns" "$APP/Contents/Resources/${APP_NAME}.icns"

# Stamp the release version into the app's Info.plist so Sparkle can compare the
# running app against the appcast. $MILLFOLIO_VERSION comes from the release tag
# (make_pkg.sh forwards it); when unset the plist's committed default is kept.
if [[ -n "${MILLFOLIO_VERSION:-}" ]]; then
    echo "==> Stamping version ${MILLFOLIO_VERSION} into Info.plist" >&2
    PB=/usr/libexec/PlistBuddy
    "$PB" -c "Set :CFBundleShortVersionString ${MILLFOLIO_VERSION}" "$APP/Contents/Info.plist"
    "$PB" -c "Set :CFBundleVersion ${MILLFOLIO_VERSION}" "$APP/Contents/Info.plist"
fi

# --- Sparkle: embed the framework so auto-update works from an installed app. ---
# Sparkle ships (via SPM) as a binary Sparkle.framework containing the updater
# dylib PLUS helper code (Autoupdate, Updater.app, Downloader.xpc, Installer.xpc).
# SwiftPM links it as @rpath/Sparkle.framework but does NOT embed it in our
# hand-assembled .app, so we copy it into Contents/Frameworks and add the matching
# rpath. (SwiftPM already stages a copy next to the built binary.)
FW_SRC="$(dirname "$BIN")/Sparkle.framework"
if [[ -d "$FW_SRC" ]]; then
    echo "==> Embedding Sparkle.framework" >&2
    # -R preserves the Versions/Current symlink layout a framework needs.
    cp -R "$FW_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
    # The binary's baked-in rpaths don't include the standard app Frameworks dir.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
else
    echo "warning: Sparkle.framework not found next to $BIN — auto-update will not work" >&2
fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
SIGN_ID="${MILLFOLIO_SIGN_IDENTITY:--}"

# Sign everything inside-out. Nested Sparkle code (XPC services, the Autoupdate
# helper, Updater.app) must be signed BEFORE the framework, which is signed before
# the app — and the app last (its signature seals the embedded framework). Adding
# the rpath above invalidated the app binary's signature, so a re-sign is required
# regardless. For Developer ID we use the hardened runtime + a secure timestamp
# (required for notarization); locally we ad-hoc sign so the app runs.
if [[ "$SIGN_ID" == "-" ]]; then
    echo "==> Ad-hoc signing (set MILLFOLIO_SIGN_IDENTITY for a notarizable build)" >&2
    RUNTIME=(); SIGN=(-)
else
    echo "==> Signing with Developer ID: ${SIGN_ID}" >&2
    RUNTIME=(--options runtime --timestamp); SIGN=("$SIGN_ID")
fi

# ${RUNTIME[@]+...} guards the empty-array case under `set -u` on bash 3.2 (macOS).
# Retry a few times: `--timestamp` hits Apple's timestamp server, which flakes with
# "The timestamp service is not available" — a transient outage, not a signing error.
sign() {
    local i
    for i in 1 2 3 4 5; do
        if codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --sign "${SIGN[@]}" "$1" >&2; then
            return 0
        fi
        echo "==> codesign of '$1' failed (attempt $i) — retrying in ${i}0s (timestamp service may be flaky)" >&2
        sleep "${i}0"
    done
    echo "==> codesign of '$1' failed after 5 attempts" >&2
    return 1
}

if [[ -d "$FW" ]]; then
    for item in \
        "$FW/Versions/B/XPCServices/Downloader.xpc" \
        "$FW/Versions/B/XPCServices/Installer.xpc" \
        "$FW/Versions/B/Autoupdate" \
        "$FW/Versions/B/Updater.app"; do
        [[ -e "$item" ]] && sign "$item"
    done
    sign "$FW"
fi
sign "$APP"

echo "$APP"
