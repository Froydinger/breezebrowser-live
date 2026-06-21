# Breeze 3.2 — next-round plan

Handoff doc so anyone (Jake, Claude Code, or Antigravity) can pick this up from git
alone. Written 2026-06-21.

## Current state (read first)

- **Live release (auto-updater): v3.1.1** — commit `e24e9b2` on `native-swift-browser`
  (also `origin/native-swift-browser`; GitHub release `v3.1.1`). It works. **Do not
  re-ship anything until the items below are done and tested.**
- **In-progress, NOT shipped: branch `wip/3.2-next`** (commit `a1bfbd2`, local only —
  not pushed). It holds a partial "3.1.2" that was never released. Cherry-pick the
  good parts; redo the rest. What's on it:
  - ✅ **Fullscreen traffic-light gap** — `navLeadingC` collapses the 82pt nav inset to
    12pt in fullscreen (`BrowserController` willEnter/willExitFullScreen + the
    `nav.leadingAnchor` constraint at ~line 497). **This part is good — keep it.**
  - ⚠️ **OAuth popup fix** — `createWebViewWith` now returns a real child web view from
    the passed config (so `window.open` popups aren't reported "blocked"). Helps, but
    **Lovable/Firebase auth still loops** — unsolved (see P4).
  - ⚠️ **OpenAI BYOK scaffold** — `OpenAIAI.swift` + Settings → AI (engine selector,
    key field, model dropdown) + `BrowserController` backend wiring
    (`useOpenAI`/`ensureOpenAI`/`openaiModel`, `sendToAI` dispatch, `prepareAIStatus`).
    **Problems:** model IDs are stale; key is stored in settings JSON (should be
    Keychain — see P1).
  - ❌ **AI routing regression** — `looksLikeSearchTerm` (added in 3.1.1) over-routes to
    Google, and the agent over-acts. See P0. This is the worst regression.
- Reminder: Antigravity uses its own clone at `~/.gemini/antigravity/scratch/
  breezebrowser-live`; this checkout (`/APPS/Browser`) is the canonical one and is
  synced. See memory `breeze-antigravity-scratch-repo`.

## Do these in order

### P0 — Fix AI behavior: chat-first, act only when asked  ← most important

**Symptoms (observed):**
- "hey whats up" → the AI scrapes/comments on the current tab and takes actions
  instead of just replying.
- "go to facebook actually" → it *describes the current page* instead of navigating.
- Typing in the **new-tab Ask bar** → it **only Googles** (conversational input gets
  turned into a web search).

**Root causes:**
1. `BrowserController.submitQuery` runs `looksLikeSearchTerm(q)` (added 3.1.1) and, when
   true, does `navigate(searchURL(for: q))` — so plain/ambiguous Ask-bar input bypasses
   the AI and just Googles. Too aggressive for the chat entry point.
2. `gatherContexts()` always injects the current tab's text, so the model comments on
   the page unprompted (and a fresh/disconnected chat shouldn't lean on it).
3. `Agent.systemPrompt` + the 3.1.1 "goal restatement" bias toward taking actions; chit
   chat triggers tools. Explicit navigation ("go to X") isn't reliably mapped to `OPEN`.

**Plan:**
- **Routing:** make the Ask bar + assistant **default to chatting** (send to the AI).
  Only short-circuit to a plain Google search when the user *explicitly* asks (⌘↵ already
  forces search; keep that). Drastically narrow or drop `looksLikeSearchTerm` for the
  chat path — keep only the URL detection (`isURL`) that sends real addresses to
  `navigate`. Let the AI decide whether to SEARCH.
- **System prompt (`Agent.swift`):** make it explicitly chat-first. e.g. "You are a
  conversational assistant FIRST. For greetings, opinions, general/coding/math
  questions, reply in plain text and use NO tools. Use `OPEN` only when the user clearly
  asks to go to/open/visit a site (e.g. 'go to facebook' → `OPEN: facebook.com`). Use
  `SEARCH` only for real-time/factual info you can't answer. Only READ or comment on the
  current page when the user refers to 'this page'/'this tab'. Never act on or describe
  the current page unprompted."
- **Context:** for a fresh chat started from the new-tab Ask bar (disconnected), don't
  feed current-tab text; for the docked assistant, keep current-tab context *available*
  but instruct the model not to comment on it unless asked.
- **Explicit nav:** ensure "go to / open / visit X" reliably parses to `OPEN: X`
  (improve `Agent.parse` and/or prompt examples).
- **Acceptance tests:** "hey whats up" → friendly reply, **0 tool chips**, no page
  comment. "go to facebook" → opens facebook.com. "what's 2+2" → "4", no tools. "latest
  news on X" → exactly one SEARCH. New-tab Ask "hey" → chats, does NOT Google.

### P1 — OpenAI BYOK: current models + Keychain storage

- **Models** (verified on developers.openai.com, June 2026). Dropdown in Settings → AI:
  - **`gpt-5.4-mini` — DEFAULT / recommended** ($0.75 / $4.50 per 1M). The user wants
    this as the default.
  - `gpt-5.4-nano` — cheapest ($0.20 / $1.25).
  - `gpt-5.4` — most capable of the family ($2.50 / $15).
  - **+ a custom-model text field** (future-proof: lets the user paste any exact id,
    e.g. a newer `gpt-5.5`, without a code change).
  - Update `ui/settings.html` `<option>`s + the `set2`/listeners, and
    `BrowserController.openaiModel` default → `"gpt-5.4-mini"`.
- **Keychain (yes, this is the right way):** store the API key in the macOS Keychain,
  not `settings.json`.
  - Add a small `Keychain` helper (Security framework, `SecItem*`,
    `kSecClassGenericPassword`, service `com.jakefreudinger.breeze.native`, account
    `openaiKey`). get / set / delete.
  - New bridge method (e.g. `setSecret(key,value)` / `hasSecret(key)`) in
    `InternalPages.swift` + a `breezeMsg` case in `BrowserController`. The settings page
    can't read Keychain directly, so the password field shows a masked "•••• saved"
    state when `hasSecret` is true and only overwrites on new input; add a "Remove key"
    affordance that calls delete.
  - `OpenAIAI`/`ensureOpenAI` read the key from Keychain instead of `Store.string`.
  - **Migration:** if a key exists in `settings.json` (from the wip/3.2-next build),
    move it into Keychain on launch and delete it from settings.
  - This stays BYOK (their key, their bill, calls api.openai.com directly — no Breeze
    server). The Keychain just makes at-rest storage proper.

### P2 — Sidebar footer: vertical button rail

- In `BrowserController.buildFooter()` (~line 361) change the horizontal `row`
  NSStackView to **vertical**, top→bottom: **Downloads** (`arrow.down.to.line`),
  **Saved** (`bookmark`), **History** (`clock`), **Theme** (`sun.max`), then
  **Settings** (`gearshape`) pinned to the **very bottom corner**.
- Relocate the **ad-block pill** out of that row (e.g. above the rail) so it isn't
  clipped — the goal is to free horizontal width so the **now-playing chip ("Liked…")
  isn't truncated** at the default sidebar width. The vertical rail is also the intended
  "unique UI element."
- Rework the `bottomStack` (`[nowPlaying, footer]`, ~line 324) so the now-playing chip
  spans full width and the vertical rail sits below it with Settings last.
- **Acceptance:** at default sidebar width the now-playing chip text isn't cut off;
  footer buttons are a vertical column; Settings is the bottom-most.

### P3 — Light mode: assistant chat is unreadable

- In light mode the AI reply text renders near-invisible (faint gray on near-white) and
  bubbles look broken (see screenshot from 6/21).
- Fix `AssistantPanel.swift` colors to respect the theme: readable foreground for AI
  text in light mode, proper contrast for both user and AI bubbles. Check where it sets
  text/background colors and make them theme-aware (it likely hardcodes dark-mode
  values).
- **Acceptance:** in light mode, AI replies are clearly legible; both bubble styles have
  good contrast. Re-check dark mode didn't regress.

### P4 — Lovable / Firebase OAuth popup still loops

- After P-fix in wip/3.2-next, `window.open` popups open, but
  `auth.lovable.dev/__/auth/handler` (Firebase `signInWithPopup`) loops / goes blank.
  Works in Safari and other apps, so it's WKWebView-specific.
- **Likely causes to investigate:** third-party cookie / storage partitioning + ITP in
  WKWebView; the popup must share the **same `WKWebsiteDataStore`/process pool** as the
  opener (confirm the config WebKit hands us does); `window.opener.postMessage` not
  being delivered back; or our presenting the popup as a *tab* (vs a real child window)
  breaking the opener→close handshake.
- **Possible fixes to try:** ensure shared default data store across opener+popup; try
  presenting the popup as a real child `NSWindow`/panel instead of a tab so
  opener/postMessage/`window.close()` behave like a browser popup; investigate Firebase
  `signInWithPopup` requirements under WKWebView (may need redirect-flow fallback). This
  is a **research task** — reproduce against Lovable specifically.
- **Acceptance:** Lovable "Continue with Google" completes and returns logged-in.

## Already shipped (don't redo)

- **3.1.0** — Vimium-style DOM tagging, multi-step agent, auto-dock, agent snapshots.
- **3.1.1** (live) — invisible element tagging (no on-page badges), agent goal
  follow-through, auto-dock on navigate, snapshot path moved off the hardcoded
  Antigravity dev path to Application Support, the (now-too-aggressive) Ask-bar routing.

## When ready to ship 3.2

Follow `CLAUDE.md` → "Releasing a new native version": bump `native/build.sh`
(CFBundleVersion + CFBundleShortVersionString), add a `ui/updates.html` RELEASES entry,
`./build.sh`, build the DMG + the **auto-update .zip**, `gh release create vX.Y.Z
--target native-swift-browser --latest=false` with BOTH assets, then update the lander.
Keep v3.x **not** "latest". Test the build locally before releasing.
