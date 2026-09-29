cask "localhostage" do
  version "1.1.1"
  sha256 "2abb909e97a6bde669b2f4df975f4f72c006ffe9657d722ac4e8e67c7e7e9a70"

  url "https://github.com/askmaddyy/localhostage/releases/download/v#{version}/localhostage.dmg"
  name "localhostage"
  desc "Menu bar app that shows which dev servers are holding your ports, and frees them"
  homepage "https://github.com/askmaddyy/localhostage"

  depends_on macos: :sonoma

  app "localhostage.app"

  uninstall quit: "com.madhavoberoi.localhostage"

  zap trash: [
    "~/Library/Application Support/localhostage",
    "~/Library/Logs/localhostage",
    "~/Library/Preferences/com.madhavoberoi.localhostage.plist",
  ]
end
