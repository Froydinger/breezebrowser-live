#!/bin/bash
# Prepare verified direct-distribution artifacts. Authentication stays in Keychain.
# Usage: ./notarize-release.sh dist/Breeze.app apple-notary-9228JV4RRX
set -euo pipefail
cd "$(dirname "$0")"
APP="${1:?Provide the production Breeze.app path}"
PROFILE="${2:?Provide the approved notarytool Keychain profile alias}"
[[ -d "$APP" ]] || { echo "App bundle is missing." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version." >&2; exit 1; }
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == com.jakefreudinger.breeze.native ]] || { echo "Only the production bundle can be packaged here." >&2; exit 1; }
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    info = plistlib.load(f)
if not all(info.get(k) for k in ('BreezeCloudAIBaseURL', 'BreezeCloudClientToken')):
    raise SystemExit('Required Aero configuration is missing.')
PY
codesign --verify --deep --strict "$APP"
SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* && "$SIGNATURE" == *"TeamIdentifier=9228JV4RRX"* && "$SIGNATURE" == *"runtime"* && "$SIGNATURE" == *"Timestamp="* ]] || {
  echo "Require Developer ID, team 9228JV4RRX, hardened runtime and secure timestamp." >&2; exit 1;
}
OUT_DIR="$(dirname "$APP")"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/breeze-notary.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
submit() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json > "$WORK/receipt.json"
  python3 - "$WORK/receipt.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    receipt = json.load(f)
print('Apple notarization:', receipt.get('status', 'Unknown'))
if receipt.get('status') != 'Accepted':
    print('Submission ID:', receipt.get('id', 'Unavailable'))
    raise SystemExit('Notarization was not accepted; do not publish these artifacts.')
PY
}
# Submit first; build the final updater ZIP only after the app ticket is stapled.
ditto -c -k --keepParent "$APP" "$WORK/Breeze-notarization.zip"
submit "$WORK/Breeze-notarization.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ZIP="$OUT_DIR/Breeze-$VERSION-arm64.zip"
DMG="$OUT_DIR/Breeze-$VERSION-arm64.dmg"
[[ ! -e "$ZIP" && ! -e "$DMG" ]] || { echo "Versioned artifacts already exist; inspect them before replacing." >&2; exit 1; }
ditto -c -k --keepParent "$APP" "$ZIP"
swiftc dmg/makebg.swift -o "$WORK/makebg"
(cd dmg && "$WORK/makebg")
create-dmg --volname Breeze --background dmg/background.tiff --window-pos 240 120 --window-size 620 420 --icon-size 128 --icon Breeze.app 165 215 --app-drop-link 455 215 --hide-extension Breeze.app --no-internet-enable "$DMG" "$APP"
IDENTITY="${BREEZE_SIGNING_IDENTITY:?Provide the approved Developer ID Application identity}"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
submit "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Verified release artifacts: $ZIP and $DMG"
