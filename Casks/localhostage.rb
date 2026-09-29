cask "localhostage" do
  version "1.1.0"
  sha256 "4dc6f803caed5788a1d830355e558694fa560fb45e81866c8b168aac93531d8e"

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
