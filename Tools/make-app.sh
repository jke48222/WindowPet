#!/bin/bash
# Builds a distributable WindowPet.app: release binary + SPM resource bundle
# + generated icns + Info.plist (LSUIElement accessory app). Signs with a
# Developer ID Application identity when one exists (hardened runtime),
# otherwise ad-hoc. Notarization (needs an Apple Developer account):
#   xcrun notarytool submit build/WindowPet.zip --keychain-profile <profile> --wait
#   xcrun stapler staple build/WindowPet.app
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
APP=build/WindowPet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WindowPet "$APP/Contents/MacOS/"
cp -R .build/release/WindowPet_WindowPet.bundle "$APP/Contents/Resources/"

mkdir -p build/AppIcon.iconset
swift Tools/icongen.swift appicon build/appicon-1024.png >/dev/null
for s in 16 32 64 128 256 512; do
  sips -z $s $s build/appicon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d build/appicon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WindowPet</string>
  <key>CFBundleDisplayName</key><string>WindowPet</string>
  <key>CFBundleIdentifier</key><string>com.funproject.windowpet</string>
  <key>CFBundleExecutable</key><string>WindowPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Jalen Edusei. A windup robot who lives on your screen.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Rusty listens while you hold Option-Space, and continuously only when the wake word is switched on.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Turns your held-key speech into commands, on-device where supported.</string>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)
APPLEDEV=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)
DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"WindowPet Dev"' | head -1 | tr -d '"' || true)
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed: $IDENTITY (hardened runtime, ready for notarytool)"
elif [ -n "$APPLEDEV" ]; then
  # Apple-issued development identity: stable across rebuilds, so TCC
  # grants (Accessibility, Microphone, Speech) persist.
  codesign --force --sign "$APPLEDEV" "$APP"
  echo "Signed: $APPLEDEV (stable, permissions persist across rebuilds)"
elif [ -n "$DEVID" ]; then
  codesign --force --sign "WindowPet Dev" "$APP"
  echo "Signed with stable local identity: WindowPet Dev"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (permissions will reset on every rebuild)"
fi
codesign --verify --deep --strict "$APP" && echo "codesign verify: OK"
echo "Built $APP"
