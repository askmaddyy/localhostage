cask "localhostage" do
  version "1.0.0"
  sha256 "REPLACED_BY_RELEASE_SCRIPT"

  url "https://github.com/askmaddyy/localhostage/releases/download/v#{version}/localhostage-#{version}.zip"
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
