cask "lectern" do
  # scripts/release/update-cask writes both from the DMG built by scripts/release/build-dmg.
  version "1.0.0"
  sha256 "b889d4b1001ae252e73c381def9a4f36cc8287a2f705192848dd062091b48767"

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
