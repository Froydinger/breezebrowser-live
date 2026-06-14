# Breeze Browser — build & release guide

Electron (Chromium 136 / Electron 36) browser with a local Qwen2.5 3B AI
(function-calling: agentic in-browser web search, reminders, page reading),
native ad blocking, password vault, and zero tracking. macOS (Apple Silicon) +
Windows.

- `main.js` — main process (tabs, sessions, permissions, AI, updater, menu)
- `preload.js` — chrome-UI bridge · `page-preload.js` — injected into web pages
  · `internal-preload.js` — for internal `file://` pages
  · `overlay-preload.js` — for the notification overlay view
- `ui/` — chrome UI (index.html/app.js/style.css), settings, passwords,
  `overlay.html` (notification overlay), etc.
- Build: electron-builder. Local repo is also a GitHub remote (`origin`).

## AI + UI architecture (v2.3.2+) — read before touching the assistant

- **Model:** Qwen2.5 3B Instruct GGUF via node-llama-cpp (Metal). `MODEL_URI` in
  main.js. Downloaded once to userData/models.
- **The model drives everything via function-calling** (`defineChatSessionFunction`),
  NOT regex or UI toggles. Tools defined in the `ai-ask` handler:
  `web_search` (agentic — opens default engine in a real tab, waits for the
  results page to settle, reads it, never follows a link), `read_current_page`
  (only when the question is about the page), and `set_reminder`. There are NO
  toggle buttons in the input — the model decides from plain language. Image
  generation was removed (local SD too slow on CPU; OpenAI path dropped too).
- System prompt (`buildSystemPrompt`) injects today's real date + rules: never
  append years to searches, ask a follow-up when location/info is missing, never
  fabricate, call tools immediately (don't announce "let me search" then stall).
  `temperature: 0.5` for tool reliability. 90s watchdog aborts a wedged gen.
  Do NOT add `<tool_call>` to customStopTriggers — it's Qwen's real tool syntax;
  visible leaks are stripped renderer-side in `setMsgText`.
- **Notification overlay** (`overlay.html` + `overlay-preload.js`): a transparent
  `WebContentsView` pinned above the page views — the ONLY chrome allowed to
  paint over the web view. Native views always paint above DOM, so all toasts
  (downloads, update-ready, reminders) live here, not in index.html. Sized to
  exactly its content (so it never eats page clicks when idle), anchored
  bottom-left; `positionOverlay`/`raiseOverlay` in main. Plays a synthesized
  chime on every toast; our native Notifications are `silent:true` to avoid a
  double-ding.
- **Reminders:** persisted in `appSettings.reminders`, re-armed on launch,
  missed ones fire on next launch. Fire as a persistent overlay toast + silent
  native notification. Pending ones list in the sidebar (`#reminders-strip`) and
  in Settings → Reminders; the sidebar ✕ confirms via native dialog.
- **Split view:** per-pane URL bars in a reserved top strip (`SPLIT_BAR_H`),
  both url-bar modes; `tab-nav`/`tab-navigate` IPC drive a specific tab. Do NOT
  reintroduce `enableDeviceEmulation` for "responsive" panes — it letterboxed
  pages; panes are just genuinely narrow.
- **Breeze corner mark:** fixed top-right in top-bar mode (opens AI); in
  fullscreen + sidebar-url mode it hover-reveals via a main-process corner
  cursor-poll (`startCornerPoll`).
- **Cache heal:** `healStorageIfUnclean` clears the main HTTP `Cache` (plus GPU/
  code caches) on an unclean shutdown — fixes sites (YouTube) rendering with
  missing logos/icons after a hard quit.

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
- AI web search is AGENTIC (v2.3.0+): the model calls a `web_search` function
  (node-llama-cpp function-calling) and the main process opens the user's default
  search engine in a real tab, waits for load, scrapes it, and follows the top
  result. No Tavily, no API key, no `.env` fallback — don't reintroduce one.
  Reminders + page-reading are also model tools now (set_reminder /
  read_current_page), NOT regex. Page content is only injected when the model
  asks for it, so unrelated questions aren't treated as page/search queries.
- Image generation has been removed entirely (no local SD, no OpenAI key).
- Web Push (server-sent push, `PushManager.subscribe`) does NOT work — Electron
  ships without Google's GCM/FCM keys. Local notifications and Breeze reminders
  DO work (generated on-device). This is an Electron limitation, not a bug.

## Quick commands
- Run dev: `npx electron .`  (add `--remote-debugging-port=9222` for CDP)
- Build local (no publish): `npx electron-builder --mac --win --publish never`
- GitHub auth (one-time): `gh auth login`
