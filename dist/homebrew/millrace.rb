class Millrace < Formula
  desc "CLI for the local millrace inference server and headgate privacy harness"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.9"
  url "https://github.com/millrace/app/releases/download/v0.4.9/millrace-macos.tar.gz"
  sha256 "bf09981f1f9392c9dabaa96c66a16e3e686d2e86b9dcfe7b514912c8445d94b4"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
