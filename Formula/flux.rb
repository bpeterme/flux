class Flux < Formula
  desc "Git + DVC auto-router — unified workflow for large and binary files via Cloudflare R2"
  homepage "https://github.com/bpeterme/flux"
  license "MIT"

  # Stable release fields — patched automatically by release.yml on each push to main.
  # url    "https://github.com/bpeterme/flux/archive/refs/tags/YYYY.MM.DD.N.tar.gz"
  # sha256 "..."
  # version "YYYY.MM.DD.N"

  depends_on "dvc"

  head "https://github.com/bpeterme/flux.git", branch: "main"

  def install
    # Hooks live in share/flux/ so setup.sh can find them after installation.
    (share/"flux").install "pre-commit"
    (share/"flux").install "flux.env.example"
    bin.install "setup.sh" => "flux-setup"
  end

  def caveats
    <<~EOS
      Before running flux-setup for the first time, create your config:
        mkdir -p ~/.config/flux
        cp #{share}/flux/flux.env.example ~/.config/flux/flux.env
        # edit ~/.config/flux/flux.env with your R2 credentials

      Then run flux-setup once inside each Git repo you want to manage:
        cd your-repo && flux-setup
    EOS
  end

  test do
    system "bash", "-n", bin/"flux-setup"
  end
end
