# Breeze for Windows

This isolated Windows edition ports the current native Breeze 6.3.7 design and browser features to Electron 44 / Chromium. It does not restore the retired Electron 2.x product. The Mac and Android sources, version numbers, updater assets, and release channels are unchanged.

## Architecture

- `main.cjs`: Windows host, Chromium WebContentsViews, tabs/pins/groups/splits, downloads, page permissions, native dialogs, browser tools, reminders and bridge authorization.
- `renderer/`: local-only browser chrome, internal pages, onboarding, and Aero. The design follows the current native black/white surfaces and teal accent.
- `preload.cjs`: a restricted bridge for the trusted local shell only. Web pages have no preload, Node integration, or app IPC.
- `lib/core.cjs`: bounded navigation/settings, atomic profile storage, layout validation.
- `lib/cloud.cjs`: the existing Breeze Cloud AI proxy and Supabase account/sync contract. Account data and passwords use `lib/vault.cjs` with Windows DPAPI through Electron safeStorage. There is no plaintext fallback.
- `lib/adblock.cjs`: indexed adaptation of the native bundled WebKit content-blocking list, preserving rule order, site exceptions, party/resource matching, and cosmetic rules.

## Run and test

Requires Node 22 or newer. Install with `npm ci`, run `npm test` and `npm run check`. `npm start` runs the development host. `npm run build:test:win` creates an explicitly unconfigured Breeze Test installer with a separate app/profile identity and no registered account callback. It contains no Cloud credential and is not a production release. Existing private Breeze build configuration is required for production release packaging; see [RELEASE.md](RELEASE.md). Never commit generated configuration or logs containing credentials.

`npm run build:win:no-cloud` builds the explicitly authorized initial Windows release. Aero AI and Breeze Cloud accounts/sync are disabled and labeled Coming soon. This mode never reads or bundles Cloud credentials; it does not register an account callback. The configured build command remains available for a later explicitly configured release.

The app's `--smoke-test` mode uses a new temporary profile, a loopback HTML fixture, and synthetic data. It exercises Chromium isolation, navigation, page reading, pins, bookmarks, groups, split view, sleeping tabs, internal pages and renderer output. It exits with a status code and writes `smoke-result.json` / `smoke-screenshot.png` in the current directory. It does not authenticate a real account or submit a live AI request. The Windows workflow also runs this test against the packaged executable.

## Windows behavior and explicit differences

- Saved passwords are local DPAPI-encrypted entries. Filling is explicit, origin-matched, and does not submit the website sign-in form. Passwords/cookies never sync.
- Account adapters are implemented for the future configured release; accounts and sync are disabled in the initial Windows release. They support email and Google sign-in, optional native-compatible bookmarks/tabs/history/chats/reminders sync, export, sign-out, and explicitly confirmed account deletion. Sync data uses TLS and Supabase user authorization; the native sync format is not end-to-end encrypted.
- Aero AI is Coming soon in the initial Windows release and cannot send requests. The implemented adapter for a future configured release uses only the existing Breeze Cloud service. Tasks include research, fact-check, page summary, creator analysis, screenshot/image context, and reminders. Site-changing AI clicks/typing ask for permission. Password/credit-card fields must be entered by the user.
- Creator/video summaries use visible page content and any transcript actually available in the page. They do not claim to have watched a video or accessed unavailable analytics.
- Apple Vision OCR, macOS dictation, Apple FairPlay DRM, and Apple system integrations are not part of the Windows edition. Chromium's normal media support is used.
- Reminders fire while Breeze is running. They are not safety-critical alarms.
- Initial Windows releases are unsigned. Windows SmartScreen may warn or block installation. Updates use the dedicated versioned Windows release channel and are installed manually. Never describe this installer as signed/notarized or publish it as the latest Mac release.

## Release validation

A unit or Linux development smoke pass does not establish Windows installation, DPAPI, live AI, account sign-in, or sync validity. Required final acceptance is the built Windows artifact, its published SHA-256, the official site's exact download link, and installation/launch from that site's downloaded bytes in the existing Windows test VM. Keep live-account verification and untested platform differences explicit.
