# frozen_string_literal: true

class Pdf < Formula
  desc "Sign and verify PDFs with OpenPGP and Sigstore"
  homepage "https://signed.page"
  url "https://github.com/signed-page/pdf/releases/download/v0.2.2/pdf-sign-0.2.2-source.tar.gz"
  # The checksum is an ERB placeholder; the updater validates it before rendering.
  # rubocop:disable FormulaAudit/Checksum
  sha256 "16f2734106add19d3971c06ed395351e54d723f0f050319c8cd523dc54898710"
  # rubocop:enable FormulaAudit/Checksum
  license "GPL-3.0-only"

  bottle do
    root_url "https://ghcr.io/v2/signed-page/tap"
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "8358f432130079bbabb007932d54d372171ecdba1b2bd779e970b2e27f746cb5"
    sha256 cellar: :any_skip_relocation, arm64_linux:  "3907fe71975482056b12e7e76c2915272983b0da38ffe0e3072eb1905caacb8a"
    sha256 cellar: :any_skip_relocation, x86_64_linux: "12abd39ffe09ada566a9dfcf7642226fed24ba1dd75af4c1d8cec50cb8d059d3"
  end

  depends_on "capnp" => :build
  depends_on "rust" => :build

  on_macos do
    depends_on arch: :arm64
    depends_on macos: :sonoma
  end

  def install
    system "cargo", "install", *std_cargo_args(path: "crates/cli"), "--offline"
  end

  test do
    assert_match "Usage: pdf-sign", shell_output("#{bin}/pdf-sign --help")
    assert_match "Failed to open signed PDF",
                 shell_output("#{bin}/pdf-sign verify #{testpath}/missing.pdf 2>&1", 1)
  end
end
