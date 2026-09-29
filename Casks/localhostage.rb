cask "localhostage" do
  version "1.0.2"
  sha256 "4b5d1f22626ccaf2a53020d8c228748fddefcb1a523969f115814c06efb3b25a"

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
