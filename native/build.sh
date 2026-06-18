#!/bin/bash
# Build Breeze Native into a runnable .app (Command Line Tools + swiftc; no Xcode).
set -e
cd "$(dirname "$0")"
APP="dist/Breeze.app"
SDK="$(xcrun --show-sdk-path)"
rm -rf dist && mkdir -p "$APP/Contents/MacOS"
echo "Compiling…"
swiftc -O main.swift -o "$APP/Contents/MacOS/Breeze" \
  -target arm64-apple-macosx13.0 -sdk "$SDK" \
  -framework Cocoa -framework WebKit
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Breeze</string>
  <key>CFBundleDisplayName</key><string>Breeze</string>
  <key>CFBundleIdentifier</key><string>com.jakefreudinger.breeze.native</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>Breeze</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
