class Millrace < Formula
  desc "CLI for the local millrace inference server and headgate privacy harness"
  homepage "https://github.com/millrace/app"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the millrace-macos.tar.gz release asset and fills in its checksum).
  version "0.4.5"
  url "https://github.com/millrace/app/releases/download/v0.4.5/millrace-macos.tar.gz"
  sha256 "5455c9f4677967420f206e54ebe776000b49900093dc76b6a7d4016c8d79c5f7"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `millrace` binary.
    bin.install "millrace"
  end

  test do
    assert_match "millrace", shell_output("#{bin}/millrace --help")
  end
end
