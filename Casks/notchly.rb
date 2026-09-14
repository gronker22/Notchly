cask "notchly" do
  version "1.4.3"
  sha256 "ba77f65ce02b90cd981098d5dfe792290d90ba0c77709534a56423abcd6afcac"

  # Universal build (Intel + Apple Silicon).
  url "https://github.com/gronker22/Notchly/releases/download/v#{version}/Notchly-Intel-Universal.zip"
  name "Notchly"
  desc "Turns the MacBook notch into a Dynamic-Island-style hub"
  homepage "https://github.com/gronker22/Notchly"

  depends_on macos: :sonoma

  app "Notchly.app"

  # NOTE: Notchly is unsigned / not notarized, so the first launch needs a
  # right-click → Open (or System Settings → Privacy & Security → Open Anyway).
  # This is the same one-time step as the direct download.

  uninstall quit: "com.notchly.Notchly"

  zap trash: [
    "~/Library/Preferences/com.notchly.Notchly.plist",
  ]
end
