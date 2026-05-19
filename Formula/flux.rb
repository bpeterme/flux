class Flux < Formula
  desc "Git + DVC auto-router — unified workflow for large and binary files via Cloudflare R2"
  homepage "https://github.com/bpeterme/flux"
  license "MIT"

  # Stable release fields — patched automatically by release.yml on each push to main.
  # url    "https://github.com/bpeterme/flux/archive/refs/tags/YYYY.MM.DD.N.tar.gz"
  # sha256 "..."
  # version "YYYY.MM.DD.N"

  depends_on "dvc"

  head "https://github.com/bpeterme/flux.git", branch: "dev"

  def install
    version_str = build.head? ? "HEAD-#{`git describe --tags --always`.chomp}" : version.to_s
    inreplace "flux", 'VERSION="dev"', "VERSION=\"#{version_str}\""
    # Hook lives in share/flux/ so `flux setup` can find it after installation.
    (share/"flux").install "pre-commit"
    (share/"flux").install "flux.env.example"
    bin.install "flux"
  end

  def caveats
    <<~EOS
      Before running flux setup for the first time, create your config:
        mkdir -p ~/.config/flux
        cp #{share}/flux/flux.env.example ~/.config/flux/flux.env
        # edit ~/.config/flux/flux.env with your R2 credentials

      Then run flux setup once inside each Git repo you want to manage:
        cd your-repo && flux setup
    EOS
  end

  test do
    assert_match "flux ", shell_output("#{bin}/flux version")
  end
end
