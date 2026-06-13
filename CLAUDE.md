# Breeze Browser — build & release guide

Electron (Chromium 136 / Electron 36) browser with a local Llama 3.2 AI, native
ad blocking, password vault, and zero tracking. macOS (Apple Silicon) + Windows.

- `main.js` — main process (tabs, sessions, permissions, AI, updater, menu)
- `preload.js` — chrome-UI bridge · `page-preload.js` — injected into web pages
  · `internal-preload.js` — for internal `file://` pages
- `ui/` — chrome UI (index.html/app.js/style.css), settings, passwords, etc.
- Build: electron-builder. Local repo is also a GitHub remote (`origin`).

## Releasing a new version (do it in this order)

1. Make changes. Bump `version` in `package.json` (semver, e.g. 2.2.4 → 2.2.5).
2. `git add -A && git commit -m "vX.Y.Z: …"` then `git push`.
3. Build + publish to GitHub:
   ```
   export GH_TOKEN=$(gh auth token)
   npx electron-builder --mac --win --publish always
   ```
4. **Un-draft the release** — electron-builder uploads it as a DRAFT, and the
   auto-updater CANNOT see a draft. Publish it:
   ```
   gh release edit vX.Y.Z --repo Froydinger/breezebrowser-live --draft=false --latest
   ```
   (Replace vX.Y.Z with the new version.) If "you ship but nobody updates,"
   this forgotten step is the #1 cause — check it first.

   > Optional one-time improvement to skip the un-draft step forever: set
   > `build.publish.releaseType` to `"release"` in package.json. Then
   > `--publish always` publishes directly instead of as a draft. Takes effect
   > on the next build. (Not done yet — safe to add anytime.)

Installed copies then update on launch, on a 4-hour timer, or via the menu
**Breeze → Check for Updates…** (macOS) / **Help → Check for Updates…** (Windows).

### Verify a release went out correctly
```
gh release view vX.Y.Z --repo Froydinger/breezebrowser-live --json isDraft,assets \
  --jq '{draft:.isDraft, files:[.assets[].name]}'
```
Must show `draft:false` and include `latest-mac.yml`, `latest.yml`, the
`-mac.zip` (macOS updates use the zip, NOT the dmg), the `.dmg`, and the `.exe`.

### Test an update end-to-end on this Mac
Build a local installer one version BEHIND the published release, install it,
then Check for Updates — it should pull the newer published version:
```
sed -i '' 's/"version": "2.2.5"/"version": "2.2.4"/' package.json   # temp older
npx electron-builder --mac --publish never -c.directories.output=/tmp/btest
sed -i '' 's/"version": "2.2.4"/"version": "2.2.5"/' package.json   # restore
```
Install `/tmp/btest/*.dmg` (right-click → Open first time), then Check for Updates.

## Code signing — CRITICAL, read before changing build config

- **macOS:** self-signed cert **"Breeze Signing"** in the login keychain
  (`build.mac.identity`). NOT Apple Developer ID, NOT notarized.
  - Auto-updates work BECAUSE every release is signed with this SAME cert. If
    the cert is ever lost or regenerated, existing users' auto-updates BREAK.
    **Back it up: Keychain Access → export "Breeze Signing" as .p12.**
  - `hardenedRuntime: false` and `build/entitlements.selfsigned.plist` (JIT only)
    are REQUIRED for self-signed: hardened runtime's library validation rejects
    the Electron Framework (no Team ID) → "can't be opened" crash at launch.
    Don't re-enable hardened runtime or restore the full entitlements unless you
    move to a real Apple Developer ID. See [[breeze-code-signing]] in memory.
  - Users see one Gatekeeper "unidentified developer" prompt on first install
    (right-click → Open). Removing it needs an Apple Developer ID ($99/yr) +
    notarization; then re-enable hardenedRuntime + entitlements.mac.plist.
  - macOS builds are **arm64 only** (Apple Silicon) — deliberate, no Rosetta.
- **Windows:** unsigned. Dual-arch (x64 + arm64) NSIS installer. SmartScreen
  warns on first install ("More info → Run anyway"). Auto-update needs NO
  signing. Removing the warning needs a Windows code-signing cert (Azure
  Trusted Signing ~$10/mo is the cheapest legit path; self-signed does NOT help
  for distribution).

## Gotchas / invariants

- **First install is always manual.** Auto-update only kicks in for copies
  already running a Breeze that points at `breezebrowser-live` and has the
  updater code (v2.2.4+). Older builds pointing at the old `breeze-browser`
  repo won't migrate — they need one manual install.
- GitHub releases are public → the binaries are publicly downloadable. That's
  normal for an auto-updating app.
- Navigation across the `file://` ↔ web boundary must rebuild the view
  (`loadInActiveTab`) so the right preload loads. When TESTING preload-dependent
  features via CDP, navigate through the app (`breeze.navigate`), not
  `Page.navigate` — the latter bypasses the rebuild. See [[breeze-preload-boundary]].
- No perpetual CSS animations / no `setInterval` busy loops on the main thread —
  they spiked idle GPU/CPU. Gate animations on active-state classes. See
  [[breeze-no-perpetual-animations]].
- API keys (OpenAI, Tavily) are bring-your-own-key, stored locally, NEVER
  bundled. Don't reintroduce a `.env` key fallback.
- Web Push (server-sent push, `PushManager.subscribe`) does NOT work — Electron
  ships without Google's GCM/FCM keys. Local notifications and Breeze reminders
  DO work (generated on-device). This is an Electron limitation, not a bug.

## Quick commands
- Run dev: `npx electron .`  (add `--remote-debugging-port=9222` for CDP)
- Build local (no publish): `npx electron-builder --mac --win --publish never`
- GitHub auth (one-time): `gh auth login`
