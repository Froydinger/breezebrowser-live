# Breeze Browser — build & release guide

**Breeze is now a native macOS app** (Swift + AppKit + WKWebView), Apple Silicon
only. As of **3.0**, the Electron/Chromium build is retired — the native app in
`native/` is the product. The native rewrite exists because Apple's WebKit gives
things Electron can't: FairPlay DRM video (Netflix), real system passkeys/
WebAuthn, lower RAM, and better battery.

The old Electron app (2.x) is **fully dead**: its source was deleted from the tree
(it survives in git history only) and there are no 2.x users left to support, so
native releases are now just normal GitHub "latest". Everything here is native.

## Native app layout (`native/`)

- **Build:** `swiftc` directly (NOT SwiftPM — `swift build` is broken in the
  standalone Command Line Tools: dyld can't load BuildServerProtocol.framework).
  No Xcode. `native/build.sh` compiles all of `Sources/Breeze/*.swift`, bundles
  `../ui/` + icon, writes Info.plist, and signs with "Breeze Signing". No AI
  runtime is bundled — Breeze AI is BYOK (the user's OpenAI key over HTTPS).
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
  - `Agent.swift` — backend-agnostic agentic loop (see AI below).
  - `OpenAILLM.swift` — the only AI backend: OpenAI **gpt-5.4-mini** via the
    user's own API key (BYOK), stored in the macOS Keychain. No local model.
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
- `ui/` (repo root) — bundled HTML for the native app's internal pages.

## AI architecture (native) — read before touching the assistant

- **One backend, BYOK only:** OpenAI **`gpt-5.4-mini`** (`OpenAILLM`) over the
  Chat Completions API, authenticated with the user's OWN API key. The key lives
  in the macOS Keychain (`Keychain.swift`, account `openaiKey`). Do NOT add a
  local model (Llama/llama-server/GGUF), Apple Foundation Models, a model picker,
  or a second model — Breeze AI is gated to gpt-5.4-mini only.
- **Keychain hygiene (hard rule):** never read the keychain just to show status.
  A non-secret `aiKeyConnected` flag in settings mirrors "is a key saved", so
  `llm.ready`, `bridgeStateJS`, and the assistant/settings UI show readiness
  WITHOUT a keychain read. The keychain is read only (a) on an actual AI send and
  (b) when the user explicitly opens the OpenAI key panel in Settings (the one
  `hasSecret` call). This keeps the macOS password prompt from firing on open.
- **No key → warn, don't fail:** using an AI feature with no key shows a friendly
  "add your OpenAI key in Settings" message (with a platform.openai.com link via
  the `openExternal` bridge), not a dead request.
- **Request shape:** `complete()` sends `model` + `messages` + `max_completion_tokens`
  + `reasoning_effort:"low"`; on a 400 it retries once with model+messages only, so
  a future API tweak can't brick the assistant.
- **Agentic loop lives in `Agent.swift`** (backend-agnostic; takes `ask`/`askFresh`
  closures). The model drives the browser via a tiny text protocol:
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
- **Self-healing context (never hard-fail):** tool output is capped and, if a
  request exceeds the model's context, `Agent.run` calls `askFresh` with only
  the question and the most relevant gathered information.
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

The native updater finds releases by scanning for the newest **`v3.x`** tag with a
`.zip` asset (see `Updater.swift`) — it does NOT read GitHub's "latest" flag, so the
release can (and now should) be marked latest normally.

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
4. Publish the release, tagged `vX.Y.Z`, **as GitHub latest**:
   ```
   gh release create vX.Y.Z --repo Froydinger/breezebrowser-live \
     --target native-swift-browser --title "Breeze X.Y.Z — …" --latest \
     --notes "…" dist/Breeze-X.Y.Z-arm64.dmg dist/Breeze-X.Y.Z-arm64.zip
   ```
   Electron 2.x is dead, so there's nothing to protect by pinning an old "latest" —
   native is the only product. See [[breeze-native-3.0-release.md]] in memory.
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
gh api repos/Froydinger/breezebrowser-live/releases/latest --jq '.tag_name'  # should be vX.Y.Z
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

## Quick commands
- Native: `cd native && ./build.sh && open dist/Breeze.app`
- Regenerate DMG bg: `cd native/dmg && swiftc makebg.swift -o /tmp/makebg && /tmp/makebg`
- GitHub auth: `gh auth login`
