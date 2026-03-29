class Screenmuse < Formula
  desc "AI Agent Recorder — capture what AI sees and does"
  homepage "https://github.com/hnshah/screenmuse"
  url "https://github.com/hnshah/screenmuse/releases/download/v#{version}/screenmuse-#{version}.zip"
  # After each release, update SHA256:
  #   shasum -a 256 screenmuse-<version>.zip
  sha256 "PLACEHOLDER_SHA256_UPDATE_AFTER_RELEASE"
  license "MIT"

  # Bottles disabled — binary is a universal (arm64 + x86_64) macOS build.
  # bottle do
  #   root_url "https://github.com/hnshah/homebrew-screenmuse/releases/download/v#{version}"
  #   sha256 cellar: :any_skip_relocation, arm64_sonoma: "PLACEHOLDER"
  #   sha256 cellar: :any_skip_relocation, sonoma:       "PLACEHOLDER"
  # end

  depends_on :macos
  depends_on macos: :sonoma  # macOS 14+ required for ScreenCaptureKit

  def install
    bin.install "screenmuse"
    bin.install "ScreenMuseMCP"
    # ScreenMuseApp is a headless GUI binary — install to libexec
    # so it's available but not on PATH by default.
    libexec.install "ScreenMuseApp"
  end

  def caveats
    <<~EOS
      The screenmuse CLI and ScreenMuseMCP server are installed to #{HOMEBREW_PREFIX}/bin.

      The ScreenMuseApp (menu bar app + HTTP server) is installed to:
        #{opt_libexec}/ScreenMuseApp

      To start ScreenMuseApp:
        #{opt_libexec}/ScreenMuseApp

      You will need to grant Screen Recording permission in:
        System Settings → Privacy & Security → Screen Recording
    EOS
  end

  test do
    assert_match "screenmuse", shell_output("#{bin}/screenmuse --help 2>&1", 0)
  end
end
