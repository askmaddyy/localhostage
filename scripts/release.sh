#!/bin/bash
# Usage: scripts/release.sh 1.0.0
# Builds + notarizes the app, wraps it in a notarized DMG, publishes the GitHub release,
# and updates the cask in askmaddyy/homebrew-tap.
# One-time setup: xcrun notarytool store-credentials localhostage (App Store Connect API key)
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?version}
IDENTITY=${IDENTITY:-"Developer ID Application: Madhav Oberoi (N52WGG38QC)"}
NOTARIZE=1 VERSION="$V" scripts/build.sh

# drag-to-Applications DMG; fixed name so releases/latest/download/localhostage.dmg always works
DMG=build/localhostage.dmg
rm -rf build/dmg && mkdir build/dmg
cp -R build/localhostage.app build/dmg/ && ln -s /Applications build/dmg/Applications
hdiutil create -quiet -volname localhostage -srcfolder build/dmg -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile localhostage --wait
xcrun stapler staple "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/localhostage.rb
gh release create "v$V" "$DMG" --title "localhostage $V" --notes "Install: \`brew install --cask askmaddyy/tap/localhostage\`, or download localhostage.dmg below, open it, and drag the app to Applications. Signed and notarized by Apple."

TAP=$(mktemp -d)
gh repo clone askmaddyy/homebrew-tap "$TAP" -- -q
mkdir -p "$TAP/Casks" && cp Casks/localhostage.rb "$TAP/Casks/"
git -C "$TAP" add Casks/localhostage.rb
git -C "$TAP" -c user.name="Madhav Oberoi" -c user.email="222234866+askmaddyy@users.noreply.github.com" commit -qm "localhostage $V"
git -C "$TAP" push -q
echo "Released $V. brew install --cask askmaddyy/tap/localhostage"
