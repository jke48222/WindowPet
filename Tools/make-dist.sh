#!/bin/bash
# Packages build/WindowPet.app into a drag-to-Applications DMG for
# distribution. With a Developer ID identity present, make-app.sh has
# already signed with hardened runtime; notarize the DMG afterwards:
#   xcrun notarytool submit build/WindowPet.dmg --keychain-profile <profile> --wait
#   xcrun stapler staple build/WindowPet.dmg
# (Requires Apple Developer Program enrollment for Developer ID + notary.)
set -euo pipefail
cd "$(dirname "$0")/.."
bash Tools/make-app.sh
STAGE=build/dmg-stage
rm -rf "$STAGE" build/WindowPet.dmg
mkdir -p "$STAGE"
cp -R build/WindowPet.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "WindowPet" -srcfolder "$STAGE" -ov -format UDZO \
  build/WindowPet.dmg >/dev/null
rm -rf "$STAGE"
echo "Built build/WindowPet.dmg ($(du -h build/WindowPet.dmg | cut -f1))"
