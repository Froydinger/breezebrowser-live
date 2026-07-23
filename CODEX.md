# Breeze Browser — agent rules (native 5.x)

**Breeze is a native macOS app** (Swift + AppKit + WKWebView), Apple Silicon only.
The Electron/Chromium build (2.x) is retired. All code lives in `native/`.

## Agent verification protocol — mandatory

- Before inspecting, editing, building, testing, committing, pushing, or releasing,
  every agent must read `AGENTS.md`, `CODEX.md`, and `CLAUDE.md` completely.
- Before each material step, re-check the relevant instructions in those files and
  verify that the planned action complies. If the files disagree, stop and tell the
  user before making that change or deployment.
- Preserve all uncommitted user work. Never expose the Breeze Cloud token or any
  credential in commands, logs, patches, or messages.
- Every user-facing message in this project — progress updates, questions, warnings,
  and final responses — must begin with `✅`. A missing checkmark means the agent's
  process should be treated as unverified and brought back to these instructions.
- Never infer release permission from ordinary implementation work. Only run the full
  release pipeline when the user explicitly asks to push/run/ship it live or equivalent.

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
10. **Update the tracked fallback site** — set `site/index.html`'s `MAC_URL` to
    the exact versioned DMG asset (`Breeze-X.Y.Z-arm64.dmg`) before committing.

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
| `InternalPages.swift` | Bundled HTML pages (including onboarding) + JS bridge |
| `Tasks.swift` | `/research`, `/summarize`, `/factcheck`, `/youtube` task registry |
| `Updater.swift` | Native auto-updater |
| `Theme.swift` | Color palette + dark/light/system |
| `Widgets.swift` | Reusable AppKit widgets |

## AI architecture

- One backend only: Breeze Cloud via `CloudLLM.swift`. Provider routing lives
  server-side. Do NOT add a local model, BYOK setup, bundled runtime, model
  picker, or fallback backend.
- Next update cleanup: remove image generation/editing from the native app and
  Breeze Cloud client surface. It is no longer considered worth the code/UI
  weight; keep Nav focused on page understanding, browsing, search, creator
  tools, and reminders.
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
- Text protocol: OPEN/SEARCH/READ/CLICK/TYPE/REMIND actions. Up to 8 chained steps;
  READ exposes numbered interactive elements that CLICK/TYPE should prefer.
- Keep SEARCH queries plain: no injected year, `site:`, `OR`, or other operators;
  preserve "near me" because the browser supplies location.
- Tasks are available from Nav chat, fullscreen Nav, the new-tab ask bar, and the
  address bar. `/research` reads about 3–4 sources and opens a sourced Research
  summary; `/youtube` and creator analysis can open Creator breakdown summaries.
- Fresh installs use `ui/onboarding.html`, gated by `hasOnboarded`;
  `BREEZE_ONBOARD=1` forces onboarding for testing.
- Context includes: current tab content, @-mentioned tabs, recent browsing history,
  bookmarks, all open tabs, and attached images (via Vision OCR).
- Self-healing: if context overflows, starts a fresh window with just the question
  + gathered info. Never hard-fails.

## Invariants

- No perpetual CSS/timer animations on the main thread.
- Pages load at 100% zoom (`magnification = 1.0` reset in `didCommit`).
- Apple Silicon (arm64) only — no Rosetta.
- Self-signed "Breeze Signing" cert — never lose it or auto-updates break.
- The updater accepts semantic `vX.Y.Z` releases with major ≥ 3 and a ZIP asset;
  the current product line is 5.x.
- Every release is marked GitHub latest; native 5.x is the only product.
