# Breeze Browser — build & release guide

**Breeze is now a native macOS app** (Swift + AppKit + WKWebView), Apple Silicon
only. As of **3.0**, the Electron/Chromium build is retired — the native app in
`native/` is the product. The native rewrite exists because Apple's WebKit gives
things Electron can't: FairPlay DRM video (Netflix), real system passkeys/
WebAuthn, lower RAM, and better battery.

The old Electron app (2.x) still exists in git history and current installs;
its build/release notes are in the **Legacy Electron** section at the bottom.
Everything above that is the native app.

## Native app layout (`native/`)

- **Build:** `swiftc` directly (NOT SwiftPM — `swift build` is broken in the
  standalone Command Line Tools: dyld can't load BuildServerProtocol.framework).
  No Xcode. `native/build.sh` compiles all of `Sources/Breeze/*.swift`, bundles
  `../ui/` + icon, writes Info.plist (with an ATS exception for the local Qwen
  server), and signs with "Breeze Signing".
- **Run:** `cd native && ./build.sh && open dist/Breeze.app`
- `Sources/Breeze/`:
  - `main.swift` — NSApp bootstrap, menus, AppDelegate. Starts `Updater`, calls
    `showWhatsNewIfUpdated()`.
  - `BrowserController.swift` — the core: tabs/sessions/nav, sidebar (pins,
    tab rows, groups, now-playing, footer), top bar, split view, URL-bar modes
    (top vs sidebar), assistant wiring, AI tool callbacks, internal-page bridge.
  - `Chrome.swift` — sidebar item views (TabRowView, PinView, GroupHeaderView,
    NowPlayingView, SplitPane).
  - `AssistantPanel.swift` — the AI chat panel (pure AppKit clone of Electron's
    `#assistant`). Markdown rendering, context pills, @-mention, attach.
  - `Agent.swift` — **shared agentic loop** for both AI backends (see AI below).
  - `FoundationAI.swift` — Apple Foundation Models backend (primary).
  - `LocalLLM.swift` — local Qwen backend via llama-server (fallback).
  - `Updater.swift` — native auto-updater (see Releasing below).
  - `Models.swift` — Tab, Pin, sharedConfig (WKWebView config + Safari UA + the
    `breezeMedia`/bridge user scripts), Favicons.
  - `Store.swift` — settings/pins/history/bookmarks/chats persisted as JSON in
    `~/Library/Application Support/Breeze/`.
  - `InternalPages.swift` — bundled `ui/*.html` (settings, updates, history,
    bookmarks, downloads, passwords) + the `breezeInternal` JS bridge.
  - `NewTabView.swift`, `Theme.swift`, `Widgets.swift`, `VisionOCR.swift`,
    `Downloads.swift`.
- `native/dmg/makebg.swift` — generates the DMG background (see DMG below).
- `ui/` (repo root) — shared HTML for the internal pages, used by BOTH apps.

## AI architecture (native) — read before touching the assistant

- **Backends:** Apple **Foundation Models** (`FoundationAI`, primary — on-device,
  macOS 26 / Apple Intelligence, no download) with local **Qwen2.5 7B** via
  `llama-server` (`LocalLLM`, automatic fallback when Apple Intelligence isn't
  available). `useFM` is set in `BrowserController.init` from
  `FoundationAI.available()`. The 3B model is gone (too weak).
- **Agentic loop lives in `Agent.swift`** and is shared by both backends. The
  model drives the browser via a tiny TEXT protocol (the `@Generable`/tool-calling
  macros ship only with Xcode, so we don't use FM's native tool-calling):
  - `OPEN: <url>` → `aiOpenURL` navigates the user's current tab, waits for load,
    returns title+text.
  - `SEARCH: <query>` → `aiSearchWeb` opens the default engine in a real tab,
    waits, scrapes (do NOT add a year to queries).
  - `READ` → `aiReadCurrentPage`.
  - `REMIND: <minutes> | <text>` → `aiSetReminder` (UserNotifications).
  `Agent.run(ask:askFresh:)` loops up to `maxSteps`, feeding tool output back,
  until the model returns a plain answer. Tool chips (🌐/🔎/📄/⏰) surface in the UI.
- **The system prompt is strongly anti-refusal** (`Agent.systemPrompt`): the model
  is told it DOES have web access and must never say "I can't browse / type it
  yourself," never invent facts, and not describe its own model/training. Injects
  today's date and the user's custom `aiInstructions`.
- **Self-healing context (never hard-fail):** Apple's on-device model has a small
  (~4k) context window and an agentic loop feeds it large page text. So: FM gets
  a **fresh session per message**, tool output is **capped** (~1500 chars), and
  if any `ask` throws (context overflow or otherwise) `Agent.run` calls
  `askFresh` — a brand-new context window seeded with just the question + the most
  relevant gathered info — and answers from that. Verified: open+read+search
  across turns no longer throws "transcript exceeded the model's context size."
- **Context to the model:** current tab is always included; users `@`-mention
  other tabs (`gatherContexts`/`aiExtras`); images attach via Apple Vision OCR
  (`VisionOCR`).
- **Chat history:** persisted in `Store.chats`. Surfaced on the **History page**
  (`breeze://history` → "Breeze AI chats" tab), NOT an in-panel overlay (that was
  removed). Clicking a chat sends `openChat` over the bridge →
  `assistant.openChat(id)` opens the sidebar to it.
- **New-tab Ask bar** doubles as a disconnected chat starter (`newTabSubmit`);
  the assistant doesn't open empty on a blank new tab.

## Releasing a new native version (do it in this order)

The native app has its OWN auto-update channel, **separate from the Electron 2.x
"latest"**, so existing Electron users are never pushed a native build.

1. Bump the version in **`native/build.sh`** (`CFBundleShortVersionString` +
   `CFBundleVersion`, e.g. 3.0.1 → 3.0.2).
2. **ALWAYS add a changelog entry** to `ui/updates.html` (the `RELEASES` array,
   newest first; `major: true` for headline releases). This is `breeze://updates`
   / Help → What's New, and it **auto-opens after an update**
   (`showWhatsNewIfUpdated` gates on `lastSeenVersion`;
   `BREEZE_WHATSNEW_FROM=<old> open dist/Breeze.app` forces it for testing).
3. Build the app, the DMG, and the **auto-update ZIP**:
   ```
   cd native && ./build.sh
   rm -f dist/Breeze-X.Y.Z-arm64.dmg
   create-dmg --volname "Breeze" --background dmg/background.tiff \
     --window-pos 240 120 --window-size 620 420 --icon-size 128 \
     --icon "Breeze.app" 165 215 --app-drop-link 455 215 \
     --hide-extension "Breeze.app" --no-internet-enable \
     dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze.app
   ditto -c -k --keepParent dist/Breeze.app dist/Breeze-X.Y.Z-arm64.zip
   ```
   The **ZIP is what the auto-updater downloads** (the DMG is for manual install).
   Both must be in the release.
4. Publish the release, tagged `vX.Y.Z`, **NOT marked latest**:
   ```
   gh release create vX.Y.Z --repo Froydinger/breezebrowser-live \
     --target native-swift-browser --title "Breeze X.Y.Z — …" --latest=false \
     --notes "…" dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze-X.Y.Z-arm64.zip
   ```
   `--latest=false` keeps the Electron 2.10.0 release as GitHub "latest" so the
   old electron-updater (which reads `releases/latest` for `latest-mac.yml`) keeps
   working for 2.x users. See [[breeze-native-3.0-release.md]] in memory.
5. Update the **lander** (`Froydinger/breezebrowser` repo, `index.html`): point
   the 3 download links + schema `downloadUrl` at
   `releases/download/vX.Y.Z/Breeze-X.Y.Z-arm64.dmg` and bump `softwareVersion`.
   `gh repo clone Froydinger/breezebrowser /tmp/lander`, edit, commit, push.

### How auto-update works (`Updater.swift`)
On launch, every 4h, and via **Breeze → Check for Updates…**, it hits the GitHub
releases API, picks the newest **`v3.x`** tag that is non-draft/non-prerelease and
has a `.zip` asset, and if it's newer than the running `CFBundleShortVersionString`
it prompts, downloads the zip, `ditto -x`-unpacks it, strips quarantine, verifies
the code signature (`codesign --verify --deep --strict`), atomically swaps the app
bundle in place, and relaunches. **Verified end-to-end** (a 3.0.0 build pulled
3.0.1). First install is still manual — a freshly-installed version must already
contain this updater (3.0.1+) before it can self-update.

### Verify a release
```
gh release view vX.Y.Z --repo Froydinger/breezebrowser-live \
  --json isDraft,assets --jq '{draft:.isDraft, files:[.assets[].name]}'
gh api repos/Froydinger/breezebrowser-live/releases/latest --jq '.tag_name'  # must stay v2.10.0
```
The release must include BOTH `Breeze-X.Y.Z-arm64.dmg` and `-arm64.zip`.

### DMG background (`native/dmg/makebg.swift`)
Emits a true **@2x retina TIFF** (`rep.size` 620×420, pixels 1240×840). A plain
PNG carries no point size → Finder paints it 1:1 → the art renders 2× too big and
clips. Regenerate: `cd native/dmg && swiftc makebg.swift -o /tmp/makebg && /tmp/makebg`.
The `.tiff`/`.png`/binary are gitignored; only `makebg.swift` is tracked.

## Code signing — CRITICAL

- Self-signed cert **"Breeze Signing"** in the login keychain (used by both
  `build.sh` and the codesign of the DMG/zip). NOT Apple Developer ID, NOT
  notarized. Auto-updates work because every build is signed with this SAME cert
  — if it's lost/regenerated, the updater's signature check fails. **Back it up:
  Keychain Access → export "Breeze Signing" as .p12.** `hardenedRuntime` stays
  off (no entitlements needed for the hand-built app). See [[breeze-code-signing]].
- **First install shows a Gatekeeper warning** ("Apple could not verify Breeze").
  On macOS 26 the right-click→Open path is gone — users open **System Settings →
  Privacy & Security → "Open Anyway"** once. Removing this needs an Apple
  Developer ID ($99/yr) + notarization. The lander + What's New both document it.
- Apple Silicon (arm64) only — deliberate, no Rosetta.

## Gotchas / invariants (native)

- **No perpetual CSS/timer animations**, no `setInterval` busy loops on the main
  thread — they spiked idle GPU/CPU in the Electron app; keep the rule. See
  [[breeze-no-perpetual-animations]].
- Pages always load at **100% zoom** — `magnification = 1.0` is reset in
  `didCommit` so a stray pinch/smart-zoom can't leave a site rendering oversized.
- Address fields truncate long URLs with an ellipsis (`usesSingleLineMode` +
  `.byTruncatingTail`), not a giant scrolling string.
- Internal `file://` pages talk to native via the `breezeInternal` bridge
  (`InternalPages.swift` JS + the `breezeMsg` handler in BrowserController). When
  adding a page capability, add the JS method AND the native `case`.
- Web Push (`PushManager.subscribe`) still won't work; local notifications +
  reminders do.

---

## Legacy Electron app (2.x — superseded by native 3.0)

The Electron build (Chromium 136 / Electron 36) is no longer the product but
still runs on existing installs. Key facts if you ever touch it:
- `main.js` (main process), `preload.js`/`page-preload.js`/`internal-preload.js`/
  `overlay-preload.js`, `ui/` (chrome UI). Build via electron-builder.
- AI was Qwen2.5 3B via node-llama-cpp with function-calling
  (`web_search`/`read_current_page`/`set_reminder`); notification overlay was a
  transparent `WebContentsView`.
- Release was `npx electron-builder --mac --publish always` → un-draft with
  `gh release edit vX.Y.Z --draft=false --latest`. Its updates use the `-mac.zip`
  + `latest-mac.yml`, read from `releases/latest`. **Leave v2.10.0 as GitHub
  "latest"** so these installs keep updating within 2.x; the native channel is
  v3.x and deliberately not-latest.
- Windows was removed in v2.10.1; macОS-only since.

## Quick commands
- Native: `cd native && ./build.sh && open dist/Breeze.app`
- Regenerate DMG bg: `cd native/dmg && swiftc makebg.swift -o /tmp/makebg && /tmp/makebg`
- GitHub auth: `gh auth login`
