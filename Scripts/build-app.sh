#!/bin/bash
# Builds AfterhoursNex for Mac: a universal app (Apple silicon and Intel) in Liquid Glass, and a disk image to share it.
# Needs Xcode 26 or later. With a Developer ID, set SIGN_IDENTITY="Developer ID Application: …" to sign it for others.
set -euo pipefail
cd "$(dirname "$0")/.."
DISPLAY_VERSION="${VERSION:-$(cat VERSION)}"                                  # "1.2.S", as people see it
NUMBER="$(echo "$DISPLAY_VERSION" | grep -oE '^[0-9]+(\.[0-9]+)*')"            # "1.2", as macOS needs it
echo "AfterhoursNex for Mac $DISPLAY_VERSION"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/AfterhoursNex.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AfterhoursNex" "$APP/Contents/MacOS/AfterhoursNex"
cp Resources/AppIcon.icns Resources/catalog.json "$APP/Contents/Resources/"
cp -R Resources/phone "$APP/Contents/Resources/phone"
cp -R Localization/*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AfterhoursNex</string>
  <key>CFBundleDisplayName</key><string>AfterhoursNex</string>
  <key>CFBundleIdentifier</key><string>app.afterhours.nex.mac</string>
  <key>CFBundleExecutable</key><string>AfterhoursNex</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$NUMBER</string>
  <key>CFBundleVersion</key><string>$NUMBER</string>
  <key>AHNDisplayVersion</key><string>$DISPLAY_VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string><string>ja</string></array>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>AfterhoursNex makes captions for episodes that have none, on this Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>AfterhoursNex lets phones on your Wi-Fi use it, when you turn on phone access.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --deep --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
hdiutil create -volname "AfterhoursNex" -srcfolder "$APP" -ov -format UDZO "build/AfterhoursNex-Mac-$DISPLAY_VERSION.dmg" >/dev/null
echo "Built build/AfterhoursNex.app and build/AfterhoursNex-Mac-$DISPLAY_VERSION.dmg"
