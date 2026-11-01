cask "lectern" do
  # scripts/release/update-cask writes both from the DMG built by scripts/release/build-dmg.
  version "1.0.1"
  sha256 "4725bc06f8d0de58e5c4966ebe4549b5d0c5e8044dd8691214f5f73d62e26fbd"

  url "https://github.com/ronimoe/pdf-reader/releases/download/v#{version}/Lectern-#{version}.dmg"
  name "Lectern"
  desc "Sandboxed, offline PDF reader"
  homepage "https://github.com/ronimoe/pdf-reader"

  # No auto_updates: the in-app updater is opt-in and off by default, so Homebrew upgrades Lectern.
  depends_on arch: :arm64
  # brew 7 reads a bare symbol as a minimum (">= :tahoe" is rejected by brew style).
  depends_on macos: :tahoe

  app "Lectern.app"

  # Lectern is signed ad-hoc, without a Developer ID, so Gatekeeper blocks the
  # quarantined copy Homebrew installs. Remove the quarantine once installed.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Lectern.app"]
  end

  zap trash: [
    "~/Library/Application Scripts/io.github.ronimoe.Lectern",
    "~/Library/Containers/io.github.ronimoe.Lectern",
  ]
end
