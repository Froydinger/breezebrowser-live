#!/bin/bash
# Build the Breeze PoC into a runnable .app bundle. No Xcode needed — just the
# Command Line Tools + swiftc. Ad-hoc signed so it runs locally.
set -e
cd "$(dirname "$0")"

APP="dist/Breeze PoC.app"
SDK="$(xcrun --show-sdk-path)"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O main.swift \
  -o "$APP/Contents/MacOS/BreezePoC" \
  -target arm64-apple-macosx13.0 \
  -sdk "$SDK" \
  -framework Cocoa -framework WebKit

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Breeze PoC</string>
  <key>CFBundleDisplayName</key><string>Breeze PoC</string>
  <key>CFBundleIdentifier</key><string>com.jakefreudinger.breeze.poc</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>BreezePoC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "Ad-hoc signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
