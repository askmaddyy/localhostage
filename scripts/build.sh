#!/bin/bash
# Usage: VERSION=1.0.0 scripts/build.sh            -> signed build/localhostage.app + zip
#        NOTARIZE=1 VERSION=1.0.0 scripts/build.sh -> also notarize + staple (needs: xcrun notarytool store-credentials localhostage)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-1.0.0}
IDENTITY=${IDENTITY:-"Developer ID Application: Madhav Oberoi (N52WGG38QC)"}
APP=build/localhostage.app

swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/localhostage

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/localhostage"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

ZIP=build/localhostage-$VERSION.zip
ditto -c -k --keepParent "$APP" "$ZIP"
if [ "${NOTARIZE:-0}" = 1 ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile localhostage --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "$ZIP"
shasum -a 256 "$ZIP"
