#!/bin/bash
# Packages build/WindowPet.app into a drag-to-Applications DMG, signs the DMG
# when a Developer ID identity exists, and optionally notarizes and staples it.
#
#   bash Tools/make-dist.sh              build and sign the DMG
#   bash Tools/make-dist.sh --notarize   also submit to Apple and staple
#
# Notarization needs two things this repo cannot create for you:
#   1. A Developer ID Application certificate (Apple Developer Program).
#   2. Stored notary credentials, once:
#      xcrun notarytool store-credentials "windowpet" \
#        --apple-id <your-apple-id> --team-id PK389W6V96
#      (PK389W6V96 is the OU field of the signing certificate. The suffix in
#      the certificate's common name is NOT the team id and will be rejected.)
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

bash Tools/make-app.sh
STAGE=build/dmg-stage
DMG=build/WindowPet.dmg
APP=build/WindowPet.app
rm -rf "$STAGE" "$DMG"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)

# Staple the app BEFORE it goes into the DMG, not just the DMG around it.
# A ticket on the disk image alone covers downloading and opening it, but the
# moment somebody drags the app out to Applications it has no ticket of its
# own, and macOS falls back to asking Apple over the network the first time it
# runs. That works, until the person is on a plane. Two submissions, and the
# app is self-sufficient afterwards.
if [ "$NOTARIZE" = "1" ] && [ -n "$IDENTITY" ]; then
  echo "Notarizing the app itself so it works offline once copied out"
  ditto -c -k --keepParent "$APP" build/WindowPet-app.zip
  xcrun notarytool submit build/WindowPet-app.zip --keychain-profile "windowpet" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f build/WindowPet-app.zip
fi

mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "WindowPet" -srcfolder "$STAGE" -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$STAGE"

if [ -n "$IDENTITY" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  echo "Signed DMG: $IDENTITY"
else
  echo "DMG unsigned: no Developer ID Application identity in the keychain."
  echo "Create one at developer.apple.com, then rerun. Until then this DMG"
  echo "trips Gatekeeper on anyone else's Mac."
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"

if [ "$NOTARIZE" = "1" ]; then
  if [ -z "$IDENTITY" ]; then
    echo "Cannot notarize: Apple rejects anything not signed with Developer ID."
    exit 1
  fi
  echo "Submitting to Apple. This usually takes a few minutes."
  xcrun notarytool submit "$DMG" --keychain-profile "windowpet" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "Notarized and stapled. Verifying the way Gatekeeper will:"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi
