cask "localhostage" do
  version "1.0.0"
  sha256 "6a8d75f0e5f88428d8c59afdd0fd0beb62d9906eac9732ea60b013e34b8857d6"

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
