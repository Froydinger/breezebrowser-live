# Breeze — Entitled Release Plan

Getting Breeze from self-signed to a properly signed, notarized, passkey-capable
browser. Written 2026-09-15, current shipping version 5.6.4.

## The two problems are separate

- **Install friction** (the "Open Anyway" dance) → fixed by Developer ID + notarization.
  Deterministic. No approval needed. $99 buys it outright.
- **Passkeys** → needs a restricted entitlement Apple approves at their discretion.

Notarizing alone kills the install friction even if Apple never grants the entitlement.
Don't block one on the other.

---

## Jake's part

### 1. Apple Developer Program — $99/yr
Enroll as an individual. Gives a Team ID and Developer ID Application certificate.

### 2. Apply for the passkey entitlement
`com.apple.developer.web-browser.public-key-credential`

Separate from paying — enrolling does not grant it. Apple reviews and decides.
**Do this first: it is the long pole.** Everything else is about a day's work;
approval can take weeks. Chrome and Firefox both have it, so there is precedent
for a legitimate third-party browser.

Docs: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential

---

## Claude's part (once Team ID exists)

### 3. Switch signing
- Developer ID Application cert, not "Breeze Signing"
- Hardened runtime **on** (`--options runtime`) — required for notarization
- Entitlements plist
- Provisioning profile embedded (`embedded.provisionprofile`) carrying the entitlement

### 4. Fix what hardened runtime breaks
WebKit needs at minimum:
- `com.apple.security.cs.allow-jit`
- `com.apple.security.cs.allow-unsigned-executable-memory`
- `com.apple.security.cs.disable-library-validation`

Expect a testing round here — this is where things break.

### 5. Notarize + staple
```
xcrun notarytool submit dist/Breeze-X.Y.Z-arm64.zip \
  --apple-id <id> --team-id <team> --password <app-specific-pw> --wait
xcrun stapler staple dist/Breeze.app
```
Staple the DMG too. Install becomes drag-to-Applications, no warning.

### 6. Turn passkeys back on
Delete `breezeNoPasskeyJS` from `native/Sources/Breeze/Models.swift` and its two
`addUserScript` registrations (shared + private config). Revert the passkey copy in
`ui/onboarding.html`, `ui/passwords.html`, `ui/settings.html`.

Deliberately isolated in 5.6.4 so this is one deletion, not an archaeology dig.

---

## The one-time break

New signature = new code identity. **Auto-update from 5.6.4 to the first signed
build will fail its signature check** (`Updater.swift` verifies with
`codesign --verify --deep --strict`). That build must be installed manually, once.
Every release after it updates normally.

Plan for it: mention it in the release notes for that version, and keep the DMG
link prominent on the lander.

## Do not

- Do not add the entitlement to a self-signed or ad-hoc build. It does not grant the
  capability and **breaks app launch**.
- Do not lose the Developer ID cert once shipping on it — same rule as
  "Breeze Signing" today. Export the .p12 and back it up.

## Current state (5.6.6)

- Self-signed "Breeze Signing", hardened runtime off, no entitlements file
- Passkeys hidden from sites via `breezeNoPasskeyJS`, so sites offer passwords
- **Passkeys do not work anywhere, Apple's own sites included.** 5.6.5 briefly
  exempted apple.com/icloud.com on the assumption Apple's own relying parties
  worked unentitled. They do not. Measured in Breeze on appleid.apple.com:
  `isUserVerifyingPlatformAuthenticatorAvailable()` returns **false**, and Apple's
  "Sign in with Passkey" button does nothing when clicked. macOS withholds the
  platform authenticator from an unentitled browser on **every** origin. The
  exemption was removed in 5.6.6. Do not market Apple passkey support.
- Apple Passwords autofill **does** work and is unaffected — it is WebKit-native,
  with no custom code in Breeze. The passkey block deliberately refuses only pure
  passkey requests so password/federated credential calls pass through untouched.

## How to re-measure after the entitlement lands

Inject a temporary user script that sets `document.title` to the result of
`PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()`, load
`appleid.apple.com/sign-in`, and read the tab title. `UV=true` means the platform
authenticator is finally being offered; that is the signal to delete
`breezeNoPasskeyJS`. `UV=false` means the entitlement is not actually in effect,
no matter what the portal says.
