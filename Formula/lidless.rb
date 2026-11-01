class Lidless < Formula
  desc "Keep the built-in MacBook display dark while an external monitor is connected"
  homepage "https://github.com/np25071984/lidless"
  url "https://github.com/np25071984/lidless/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "42ec6adb6ef7f4cc6c4514c4d2fa55fece2b058025ec274e8c8bd518a73ecb8f"
  license "MIT"

  depends_on :macos

  def install
    system "swiftc", "-O", "-o", "lidless", "main.swift"
    bin.install "lidless"
  end

  service do
    run [opt_bin/"lidless"]
    keep_alive true
    run_at_load true
    log_path var/"log/lidless.log"
    error_log_path var/"log/lidless.log"
    process_type :background
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/lidless --version").strip
  end
end
