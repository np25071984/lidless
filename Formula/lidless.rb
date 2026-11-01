class Lidless < Formula
  desc "Keep the built-in MacBook display dark while an external monitor is connected"
  homepage "https://github.com/np25071984/lidless"
  url "https://github.com/np25071984/lidless/releases/download/v0.2.0/lidless-macos.tar.gz"
  sha256 "76c7ccb41f5ef788d3a460e25b430fa8a49eca0edb8504a7f5f5a1d6a8e08e4a"
  license "MIT"

  depends_on :macos

  # The prebuilt release: a universal binary, so no Command Line Tools needed.
  # lidless needs no privacy permission, so the service can run it from
  # opt_bin, whose target changes with every version.
  def install
    bin.install "lidless"
  end

  service do
    run [opt_bin/"lidless", "run"]
    keep_alive successful_exit: false
    process_type :background
    log_path var/"log/lidless.log"
    error_log_path var/"log/lidless.log"
  end

  def caveats
    <<~EOS
      Start lidless now and at every login:
        brew services start lidless

      After `brew upgrade lidless`, restart it on the new version:
        brew services restart lidless

      If you installed lidless with install.sh before, remove that copy first:
        ~/.local/bin/lidless uninstall
    EOS
  end

  test do
    assert_equal "lidless #{version}", shell_output("#{bin}/lidless version").strip
  end
end
