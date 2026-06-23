# Breeze

Breeze is a native macOS browser for Apple Silicon Macs. It is built on Swift and includes Nav, a built-in Cloud AI assistant, native ad and tracker blocking, split screen browsing, encrypted local data, and zero tracking.

The current shipped app is macOS only. Windows support was removed in v2.10.1.

## What ships today

- **Nav, built in** - powered by Breeze Cloud, we dont collect data or chats.
- **Native ad and tracker blocking** - Ghostery's adblocker engine with EasyList and tracking filters runs in the network layer of every tab.
- **Zero telemetry** - Breeze does not collect browsing history, usage profiles, or analytics.
- **Encrypted local data** - history and saved passwords stay on device and are protected through the system keychain.
- **Sidebar-first browsing** - Arc-style vertical tabs, pinned sites, tab groups, and a calmer browser layout.
- **Split screen** - two pages side by side with a draggable divider.
- **Sleeping tabs** - idle tabs can sleep to reduce memory usage.
- **Reminders and notifications** - reminders are stored locally, re-armed on launch, and shown through Breeze's overlay notification system.
- **Auto-updates** - packaged builds check GitHub Releases and update through `electron-updater`.

## Requirements

- Apple Silicon Mac
- macOS 11 or newer
- Node 20+ for local development

## Run locally

```bash
npm install
npm start
```

For CDP debugging:

```bash
npx electron . --remote-debugging-port=9222
```

## Build locally

```bash
npm run dist
```

The app builds with `electron-builder`. Current macOS targets are arm64 `.dmg` and `.zip`.

## Release checklist

1. Bump `version` in `package.json`.
2. Add a new user-facing entry to `ui/updates.html` in the `RELEASES` array.
3. Commit and push.
4. Publish the macOS build:

```bash
export GH_TOKEN=$(gh auth token)
npx electron-builder --mac --publish always
```

5. If the release is created as a draft, publish it so auto-update can see it:

```bash
gh release edit vX.Y.Z --repo Froydinger/breezebrowser-live --draft=false --latest
```

Installed copies update on launch, on the updater timer, or from **Breeze → Check for Updates…**.

## Verify a release

```bash
gh release view vX.Y.Z --repo Froydinger/breezebrowser-live --json isDraft,assets \
  --jq '{draft:.isDraft, files:[.assets[].name]}'
```

A working release should show `draft:false` and include `latest-mac.yml`, the macOS update zip, and the `.dmg`.

## First launch note

Current builds are self-signed with the local **Breeze Signing** certificate, not notarized with an Apple Developer ID. Users may need to right-click the app and choose **Open** the first time.

Do not replace or regenerate the signing certificate casually. Existing auto-updates depend on future releases being signed with the same certificate.

## Important implementation notes

- `main.js` owns the main process, tabs, sessions, permissions, AI, updater, and app menu.
- `preload.js` is the browser chrome bridge.
- `page-preload.js` is injected into web pages.
- `internal-preload.js` supports internal `file://` pages.
- `overlay-preload.js` supports the notification overlay.
- `ui/` contains the browser chrome, settings, password UI, updates page, and overlay UI.
- AI web search is agentic. The model calls tools and the browser opens a real search tab.
- Page reading happens only when the model asks for it.
- Image generation has been removed.
- Web Push does not work in Electron because Chromium ships without Google's GCM/FCM keys. Local notifications and Breeze reminders do work.

## Shortcuts

| Action | Shortcut |
|---|---|
| Toggle sidebar | `⌘S` / `Ctrl+S` |
| New tab | `⌘T` |
| Close tab | `⌘W` |
| Focus address bar | `⌘L` |
| Back / Forward | `⌘[` / `⌘]` |
| Reload / Hard reload | `⌘R` / `⇧⌘R` |
| Next / Previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Jump to tab | `⌘1` to `⌘9` |
| Toggle dark mode | `⇧⌘D` |
| Zoom | `⌘+` / `⌘-` / `⌘0` |
| DevTools for current page | `⌥⌘I` |
