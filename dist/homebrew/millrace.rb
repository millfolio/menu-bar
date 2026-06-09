class Millrace < Formula
  desc "CLI for the local millrace inference server and headgate privacy harness"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.2"
  url "https://github.com/millrace/app/releases/download/v0.4.2/millrace-macos.tar.gz"
  sha256 "b5135f3224621f977b3a5ddd73f210584e989fa3c5f31cdd50807fb8712fbf58"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
