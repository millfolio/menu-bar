#!/usr/bin/env bash
#
# Release the Millrace app + millrace CLI at the current HEAD, end to end:
#
#   push main  ->  tag vX.Y.Z  ->  wait for the "build pkg" CI (attaches
#   Millrace.pkg + millrace-macos.tar.gz)  ->  bump the Homebrew formula to the
#   new asset  ->  push the formula to the tap  ->  brew upgrade locally.
#
#   tools/release.sh <X.Y.Z>
#
# Commit your change first (e.g. with tools/commit.sh). Review this script once,
# then approve `tools/release.sh` to skip the per-step prompts.
set -euo pipefail

VER="${1:?usage: tools/release.sh X.Y.Z}"
TAG="v$VER"
REPO="millrace/app"
TAP_GIT="git@github.com:millrace/homebrew-tap.git"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> push main + tag $TAG"
git -C "$ROOT" push origin main
git -C "$ROOT" tag -a "$TAG" -m "$TAG"
git -C "$ROOT" push origin "$TAG"

echo "==> waiting for 'build pkg' CI…"
sleep 6
RID="$(gh run list -R "$REPO" --workflow 'build pkg' -L1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RID" -R "$REPO" --exit-status

echo "==> bump Homebrew formula to $TAG"
"$ROOT/dist/homebrew/update-formula.sh" "$TAG"
git -C "$ROOT" add dist/homebrew/millrace.rb
git -C "$ROOT" -c commit.gpgsign=false commit -m "homebrew: bump formula to $TAG" || echo "   (formula unchanged)"
git -C "$ROOT" push origin main

echo "==> push formula to the tap"
TAP="$(mktemp -d)"
git clone -q "$TAP_GIT" "$TAP"
mkdir -p "$TAP/Formula"
cp "$ROOT/dist/homebrew/millrace.rb" "$TAP/Formula/millrace.rb"
git -C "$TAP" add Formula/millrace.rb
git -C "$TAP" -c commit.gpgsign=false commit -m "millrace $VER" || echo "   (tap unchanged)"
git -C "$TAP" push origin main
rm -rf "$TAP"

echo "==> brew upgrade"
brew update >/dev/null 2>&1 || true
brew upgrade millrace/tap/millrace || true
brew list --versions millrace

echo "==> released $TAG"
