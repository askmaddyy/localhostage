cask "localhostage" do
  version "1.0.1"
  sha256 "32f7e7778996e6417747a102766db1e5e86dd7819bb6683e7c4dd5426bcb25ef"

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
