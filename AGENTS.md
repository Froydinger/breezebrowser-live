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
8. **Publish GitHub release** (NOT marked latest):
   ```
   gh release create vX.Y.Z --repo Froydinger/breezebrowser-live \
     --target native-swift-browser --title "Breeze X.Y.Z — ..." \
     --latest=false --notes "..." \
     dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze-X.Y.Z-arm64.zip
   ```
   `--latest=false` keeps the Electron 2.10.0 release as GitHub "latest" so
   existing 2.x installs keep auto-updating. The native updater finds v3.x releases.

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
| `FoundationAI.swift` | Apple Intelligence backend (primary) |
| `LocalLLM.swift` | Local Qwen 7B via llama-server (fallback) |
| `AssistantPanel.swift` | AI chat panel (pure AppKit) |
| `Models.swift` | Tab, Pin, sharedConfig, Favicons |
| `Store.swift` | Settings/pins/history/bookmarks/chats (JSON persistence) |
| `Chrome.swift` | Sidebar item views (TabRowView, PinView, etc.) |
| `InternalPages.swift` | Bundled HTML pages + JS bridge |
| `Updater.swift` | Native auto-updater |
| `Theme.swift` | Color palette + dark/light/system |
| `Widgets.swift` | Reusable AppKit widgets |

## AI architecture

- Two backends: Apple Foundation Models (primary, macOS 26+) and local Qwen 7B
  via llama-server (fallback). Both use the same agentic loop in `Agent.swift`.
- Text protocol: OPEN/SEARCH/READ/REMIND actions. Up to 8 chained steps.
- Context includes: current tab content, @-mentioned tabs, recent browsing history,
  bookmarks, all open tabs, and attached images (via Vision OCR).
- Self-healing: if context overflows, starts a fresh window with just the question
  + gathered info. Never hard-fails.

## Invariants

- No perpetual CSS/timer animations on the main thread.
- Pages load at 100% zoom (`magnification = 1.0` reset in `didCommit`).
- Apple Silicon (arm64) only — no Rosetta.
- Self-signed "Breeze Signing" cert — never lose it or auto-updates break.
- `--latest=false` on all v3.x GitHub releases.
