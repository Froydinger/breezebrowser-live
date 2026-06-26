# Breeze Browser — agent rules (native 3.x)

**Breeze is a native macOS app** (Swift + AppKit + WKWebView), Apple Silicon only.
The Electron/Chromium build (2.x) is retired. All code lives in `native/`.

## "Push it live" / "Run it live" convention

When the user says **"push it live"**, **"run it live"**, **"ship it"**, or similar,
do the FULL release pipeline — not just `git push`. The complete steps:

1. **Bump version** in `native/build.sh` (`CFBundleVersion` + `CFBundleShortVersionString`).
2. **Add a What's New entry** to `ui/updates.html` (the `RELEASES` array, newest first;
   `major: true` for headline releases). This auto-opens after an update.
3. **Build** — `cd native && ./build.sh`
4. **Create the auto-update ZIP** — `ditto -c -k --keepParent dist/Breeze.app dist/Breeze-X.Y.Z-arm64.zip`
5. **Generate the DMG background** — `cd native/dmg && swiftc makebg.swift -o /tmp/makebg && /tmp/makebg`
6. **Create the DMG** — `create-dmg --volname "Breeze" --background dmg/background.tiff --window-pos 240 120 --window-size 620 420 --icon-size 128 --icon "Breeze.app" 165 215 --app-drop-link 455 215 --hide-extension "Breeze.app" --no-internet-enable dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze.app`
7. **Commit & push** — `git add -A && git commit -m "vX.Y.Z: ..." && git push origin native-swift-browser`
8. **Publish GitHub release as latest**:
   ```
   gh release create vX.Y.Z --repo Froydinger/breezebrowser-live \
     --target native-swift-browser --title "Breeze X.Y.Z — ..." \
     --latest --notes "..." \
     dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze-X.Y.Z-arm64.zip
   ```
9. **Update the lander** (`Froydinger/breezebrowser`, `index.html`) so all three
   download links and schema `downloadUrl` target the new DMG, and bump
   `softwareVersion`. Commit and push the lander update.

Skip any step only if the user explicitly says so.

## Build & run

- **Build:** `cd native && ./build.sh` (uses `swiftc` directly, NOT SwiftPM)
- **Run:** `open native/dist/Breeze.app`
- **Test What's New:** `BREEZE_WHATSNEW_FROM=<old> open dist/Breeze.app`

## Key source files

| File | Purpose |
|---|---|
| `BrowserController.swift` | Core: tabs, sidebar, top bar, split view, assistant wiring, AI tools |
| `Agent.swift` | Shared agentic loop (OPEN/SEARCH/READ/REMIND protocol) |
| `CloudLLM.swift` | Only AI backend: Breeze Cloud Worker configured at build time |
| `AssistantPanel.swift` | AI chat panel (pure AppKit) |
| `Models.swift` | Tab, Pin, sharedConfig, Favicons |
| `Store.swift` | Settings/pins/history/bookmarks/chats (JSON persistence) |
| `Chrome.swift` | Sidebar item views (TabRowView, PinView, etc.) |
| `InternalPages.swift` | Bundled HTML pages + JS bridge |
| `Updater.swift` | Native auto-updater |
| `Theme.swift` | Color palette + dark/light/system |
| `Widgets.swift` | Reusable AppKit widgets |

## AI architecture

- One backend only: Breeze Cloud via `CloudLLM.swift`. Provider routing lives
  server-side. Do NOT add a local model, BYOK setup, bundled runtime, model
  picker, or fallback backend.
- Every Breeze/BreezeTest build that will be tested, shipped, zipped, or released
  must embed `BREEZE_CLOUD_AI_BASE_URL` and `BREEZE_CLOUD_CLIENT_TOKEN` in
  `Info.plist`. The local token is read from
  `cloudflare/breeze-chat-worker/.breeze-client-token`.
- Build pattern:
  ```
  TOKEN=$(tr -d '\n\r' < cloudflare/breeze-chat-worker/.breeze-client-token)
  cd native
  BREEZE_CLOUD_AI_BASE_URL="https://breeze-chat.jakefroydinger.workers.dev" \
  BREEZE_CLOUD_CLIENT_TOKEN="$TOKEN" ./build.sh
  ```
- A build without those plist keys shows "Nav is not configured in this build"
  and must not ship.
- Text protocol: OPEN/SEARCH/READ/CLICK/TYPE/REMIND actions. Up to 8 chained steps.
- Context includes: current tab content, @-mentioned tabs, recent browsing history,
  bookmarks, all open tabs, and attached images (via Vision OCR).
- Self-healing: if context overflows, starts a fresh window with just the question
  + gathered info. Never hard-fails.

## Invariants

- No perpetual CSS/timer animations on the main thread.
- Pages load at 100% zoom (`magnification = 1.0` reset in `didCommit`).
- Apple Silicon (arm64) only — no Rosetta.
- Self-signed "Breeze Signing" cert — never lose it or auto-updates break.
- Every release is marked GitHub latest; native 3.x is the only product.
