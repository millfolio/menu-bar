class Millrace < Formula
  desc "CLI for the local millrace inference server and headgate privacy harness"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.11"
  url "https://github.com/millrace/app/releases/download/v0.4.11/millrace-macos.tar.gz"
  sha256 "a83b6c48f0cd4a7cf1076d0c783a9e1a8c5bec2f00145e0a9d1ca509b0cf0dc0"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
