cask "notchly" do
  version "1.4.2"
  sha256 "91e93ee765c341f52c5d45e92dbc90e1ffc2f8c2f8a7b453fd40678bf375867b"

  # Universal build (Intel + Apple Silicon).
  url "https://github.com/gronker22/Notchly/releases/download/v#{version}/Notchly-Intel-Universal.zip",
      verified: "github.com/gronker22/Notchly/"
  name "Notchly"
  desc "Turns the MacBook notch into a Dynamic-Island-style hub"
  homepage "https://github.com/gronker22/Notchly"

  depends_on macos: ">= :sonoma"

  app "Notchly.app"

  # The build is unsigned / not notarized, so strip the quarantine flag Homebrew
  # applies — otherwise Gatekeeper blocks the first launch and the user has to
  # right-click → Open.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Notchly.app"]
  end

  uninstall quit: "com.notchly.Notchly"

  zap trash: [
    "~/Library/Preferences/com.notchly.Notchly.plist",
  ]
end
