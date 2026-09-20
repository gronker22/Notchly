cask "notchly" do
  version "1.4.8"
  sha256 "20cbc9607b2dc2f9eb3e74ea597d102334128bab812b63c2cff6f0eff9ebce5d"

  # Universal build (Intel + Apple Silicon).
  url "https://github.com/gronker22/Notchly/releases/download/v#{version}/Notchly-Intel-Universal.zip"
  name "Notchly"
  desc "Turns the MacBook notch into a Dynamic-Island-style hub"
  homepage "https://github.com/gronker22/Notchly"

  depends_on macos: :sonoma

  app "Notchly.app"

  # Notchly is unsigned / not notarized. Strip the quarantine flag Homebrew adds
  # so it launches normally instead of forcing a right-click -> Open the first
  # time. (This tap already requires a one-time `brew trust`, so this adds no
  # extra step for the user.)
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Notchly.app"]
  end

  uninstall quit: "com.notchly.Notchly"

  zap trash: [
    "~/Library/Preferences/com.notchly.Notchly.plist",
  ]
end
