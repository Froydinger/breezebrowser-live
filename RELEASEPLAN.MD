# Breeze direct Mac release preparation

Updated October 2, 2026. GitHub distribution remains the full Breeze browser,
including the existing video downloader and Breeze Cloud backend.

## Signing

- Existing self-signed Breeze Signing identity remains intact.
- Developer ID Application certificate for team 9228JV4RRX is available in the
  local Keychain and paired with its private key.
- Use native/build.sh with BREEZE_SIGNING_MODE=developer-id and
  BREEZE_SIGNING_IDENTITY set to the exact approved identity label.
- The build adds hardened runtime and a secure timestamp. No broad runtime
  exceptions are granted preemptively; add only an exception proven necessary.
- Keep the existing bundle ID and data paths. Keychain access may require user
  approval after the signing identity changes. Do not export stored sessions.
- The current updater verifies signature integrity, not equality with the old
  certificate. A signer change is not inherently rejected; validate migration.

## Notarization and distribution

1. User sets up notarization authentication directly in a secure interactive
   notarytool Keychain flow. Approved alias: apple-notary-9228JV4RRX.
   Never put passwords or API keys in source, commands, logs, or chat.
2. Build and validate an isolated BreezeTest with working Cloud configuration.
3. Bump the release version and add What's New; build the production app.
4. Submit an app ZIP with notarytool using the approved Keychain profile.
5. Require Accepted, staple and validate the app; then recreate the updater ZIP.
6. Package and sign the DMG, notarize it, staple it, and validate Gatekeeper.
7. Publish the versioned ZIP and DMG on GitHub; update the canonical lander.

## Passkeys and App Store

Browser passkeys remain disabled pending Apple's restricted entitlement.
Published eligibility requires an organization Account Holder; individual
membership does not unlock it. Product UI does not advertise passkeys.

The separate BREEZE MAC chat owns App Store sandbox preparation and the
Private Cloud Compute application. Preserve the direct GitHub build's features.
Store builds need their own updater and downloader decisions. Do not disguise
features or promise review approval.

References:
- https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential

## Current 6.3.4 verification

- Production and isolated test bundles pass strict signature verification with
  Developer ID team 9228JV4RRX, hardened runtime, and secure timestamps.
- Production ZIP extraction passes the updater signature check and preserves
  the production bundle identifier and version. Interactive update/relaunch
  migration remains unverified while another task owns the shared GUI.
- App notarization submitted October 2, 2026 at 7:00 PM America/Chicago:
  `e065d025-d7cd-4024-be45-378c1e8cf625`. Status: Accepted.
- Packaging process completed successfully; do not resubmit.
  Query with `xcrun notarytool info e065d025-d7cd-4024-be45-378c1e8cf625
  --keychain-profile apple-notary-9228JV4RRX --output-format json`.
- DMG notarization accepted: `df5a94d3-5623-4cd0-8f39-acdde7f5098f`.
- App and DMG staple validation and Gatekeeper assessment passed. Final updater
  ZIP was extracted and independently passed signature, staple and Gatekeeper
  checks; production bundle ID/version and Cloud configuration were verified.
- Exact artifacts are native/dist/Breeze-6.3.4-arm64.zip and .dmg.
- Coordinator confirmed GitHub publication approval. Website publication remains
  held pending separate approval. Publish only the verified 6.3.4 artifacts.

## GitHub publication complete

- v6.3.4 published as latest at
  https://github.com/Froydinger/breezebrowser-live/releases/tag/v6.3.4
- Release commit: 7fbc002f3947ccb56067e227a8b2243f72964420.
- Downloaded published assets matched local SHA256 values and independently
  passed signature, stapling and Gatekeeper checks:
  - ZIP: 559c871f9dc89d2475e337cd4c41b4abefefd0081976750640748bf8a1f35295
  - DMG: 88ffb7cbbb8409765cc3bc810e258ba8906eadbafce7cba859a2347db0bf5738
- Do not repeat GitHub publication or upload the assets again.
- Website deployment remains on hold under the Git-only approval. Its prepared
  changes remain local in /Users/jakefreudinger/APPS/Browser/source.
- Interactive updater/relaunch migration remains unverified and was disclosed.
