class Millfolio < Formula
  desc "CLI for the local engine inference server"
  homepage "https://github.com/millfolio/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millfolio-macos.tar.gz release asset and fills in its checksum).
  version "0.4.12"
  url "https://github.com/millfolio/app/releases/download/v0.4.12/millfolio-macos.tar.gz"
  sha256 "6289649ca6c1f3346ce61feedf6360df0d1949f10e828865fb3388240055bf66"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millfolio` binary.
    bin.install "millfolio"
  end

  test do
    assert_match "millfolio", shell_output("#{bin}/millfolio --help")
  end
end
