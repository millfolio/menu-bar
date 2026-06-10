class Millrace < Formula
  desc "CLI for the local millrace inference server and headgate privacy harness"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.8"
  url "https://github.com/millrace/app/releases/download/v0.4.8/millrace-macos.tar.gz"
  sha256 "51ecd08a2d70971597073cf1adb522cf0f5ceb3977df9307586ac08d6d17fc47"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
