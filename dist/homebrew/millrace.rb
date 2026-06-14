class Millrace < Formula
  desc "CLI for the local millrace inference server"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.12"
  url "https://github.com/millrace/app/releases/download/v0.4.12/millrace-macos.tar.gz"
  sha256 "6289649ca6c1f3346ce61feedf6360df0d1949f10e828865fb3388240055bf66"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
