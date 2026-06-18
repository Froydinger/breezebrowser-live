# Breeze PoC (native Swift + WKWebView)

M0 proof-of-concept — NOT the shipping Electron app. Validates whether a native
WebKit browser gets us DRM + passkeys before committing to a full rewrite.

## Build & run
```
./build.sh            # compiles + bundles dist/Breeze PoC.app (ad-hoc signed)
open "dist/Breeze PoC.app"
```
Needs only Xcode Command Line Tools (swiftc) — no full Xcode.

## What to test
- **DRM:** open netflix.com / music.youtube.com — does protected video play?
  (This is the big one; Electron can't, WebKit's FairPlay should.)
- **Passkeys:** try a passkey login. ⚠️ May be limited — full WebAuthn for a
  third-party browser usually needs the `com.apple.developer.web-browser`
  entitlement (requires an Apple Developer profile, not ad-hoc signing).
- **General browsing:** address bar, back/forward/reload, video, logins.

## Known PoC limits
- One window, one tab (intentionally minimal).
- Ad-hoc signed → Gatekeeper may warn (right-click → Open).
- No ad block / AI / vault yet — those come in later milestones.
