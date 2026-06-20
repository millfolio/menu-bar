#!/usr/bin/env bash
#
# Regenerate dist/homebrew/millfolio.rb for a published release tag — downloads the
# release's millfolio-macos.tar.gz, computes its sha256, and rewrites the formula's
# version/url/sha256. Run after the release workflow has attached the asset:
#
#   dist/homebrew/update-formula.sh v0.4.0
#
# Then copy the formula into the tap repo (Formula/millfolio.rb) — or let CI do it,
# see dist/homebrew/README.md.
#
set -euo pipefail

TAG="${1:?usage: update-formula.sh vX.Y.Z}"
REPO="${MILLFOLIO_REPO:-millfolio/app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/millfolio.rb"

URL="https://github.com/$REPO/releases/download/$TAG/millfolio-macos.tar.gz"
VER="${TAG#v}"

echo "==> fetching $URL" >&2
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"
SHA="$(shasum -a 256 "$TMP" | awk '{print $1}')"
echo "==> sha256 $SHA" >&2

cat > "$OUT" <<EOF
class Millfolio < Formula
  desc "CLI for the local engine inference server"
  homepage "https://github.com/$REPO"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millfolio-macos.tar.gz release asset and fills in its checksum).
  version "$VER"
  url "$URL"
  sha256 "$SHA"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) \`millfolio\` binary.
    bin.install "millfolio"
  end

  test do
    assert_match "millfolio", shell_output("#{bin}/millfolio --help")
  end
end
EOF

echo "==> wrote $OUT (version $VER)" >&2
