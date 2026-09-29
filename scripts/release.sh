#!/bin/bash
# Usage: scripts/release.sh 1.0.0
# Builds, notarizes, publishes a GitHub release, and updates the cask in askmaddyy/homebrew-tap.
# One-time setup: xcrun notarytool store-credentials localhostage --apple-id <id> --team-id N52WGG38QC
set -euo pipefail
cd "$(dirname "$0")/.."
V=${1:?version}
NOTARIZE=1 VERSION="$V" scripts/build.sh
ZIP=build/localhostage-$V.zip
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$V\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" Casks/localhostage.rb
gh release create "v$V" "$ZIP" --title "localhostage $V" --generate-notes

TAP=$(mktemp -d)
gh repo clone askmaddyy/homebrew-tap "$TAP" -- -q
mkdir -p "$TAP/Casks" && cp Casks/localhostage.rb "$TAP/Casks/"
git -C "$TAP" add Casks/localhostage.rb
git -C "$TAP" commit -qm "localhostage $V"
git -C "$TAP" push -q
echo "Released $V. brew install --cask askmaddyy/tap/localhostage"
