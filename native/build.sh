#!/bin/bash
# Build Breeze Native into a runnable .app. Uses swiftc directly (the SwiftPM
# `swift build` binary is broken in the standalone Command Line Tools — dyld
# can't load BuildServerProtocol.framework). Compiles every file in
# Sources/Breeze. Breeze AI is BYOK (OpenAI gpt-5.4-mini via the user's own key);
# there is no bundled AI runtime.
set -e
cd "$(dirname "$0")"

# Variant support: build an isolated test app without touching the live install.
#   BREEZE_APP_NAME=BreezeTest BREEZE_BUNDLE_ID=com.jakefreudinger.breeze.native.test \
#   BREEZE_DIST=dist-test ./build.sh
# Defaults reproduce the shipping Breeze build exactly. Launch the test variant
# with its own data dir:  open -n dist-test/BreezeTest.app --args --profile BreezeTest
APP_NAME="${BREEZE_APP_NAME:-Breeze}"
BUNDLE_ID="${BREEZE_BUNDLE_ID:-com.jakefreudinger.breeze.native}"
OUT_DIR="${BREEZE_DIST:-dist}"
APP="$OUT_DIR/${APP_NAME}.app"
SDK="${BREEZE_SDK:-$(xcrun --show-sdk-path)}"
MODULE_CACHE="${BREEZE_MODULE_CACHE:-${TMPDIR:-/tmp}/breeze-swift-module-cache}"
mkdir -p "$MODULE_CACHE"

rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling… ($APP_NAME / $BUNDLE_ID)"
swiftc -O -whole-module-optimization Sources/Breeze/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  -target arm64-apple-macosx14.0 -sdk "$SDK" -module-cache-path "$MODULE_CACHE" \
  -framework Cocoa -framework WebKit -framework UserNotifications

# Bundle the app icon so breezeLogo() finds it via Bundle.main.image(forResource:"icon").
cp ../icon.png "$APP/Contents/Resources/icon.png" 2>/dev/null || true
# Bundle the internal HTML pages (settings, updates, history, bookmarks, …).
mkdir -p "$APP/Contents/Resources/ui"
cp -R ../ui/. "$APP/Contents/Resources/ui/" 2>/dev/null || true
# Bundle the EasyList adblock rules
cp easylist.json "$APP/Contents/Resources/easylist.json" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>3.7.0</string>
  <key>CFBundleShortVersionString</key><string>3.7.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Web site URL</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>http</string>
        <string>https</string>
      </array>
    </dict>
  </array>
</dict></plist>
PLIST

# Sign with the stable self-signed "Breeze Signing" cert so auto-updates verify.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Breeze Signing"; then
  SIGNING_ID="Breeze Signing"
  SIGNING_LABEL="Breeze Signing"
else
  SIGNING_ID="-"
  SIGNING_LABEL="ad-hoc (Breeze Signing cert not found)"
fi
codesign --force --sign "$SIGNING_ID" "$APP" >/dev/null
if [[ "$SIGNING_ID" == "Breeze Signing" ]]; then
  echo "Signed with: Breeze Signing"
else
  echo "Signed: $SIGNING_LABEL"
fi
echo "Built: $APP"
