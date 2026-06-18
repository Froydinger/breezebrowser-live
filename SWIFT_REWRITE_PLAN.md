# Breeze — native macOS rewrite (Swift + WKWebView)

Status: **planning only.** No code yet. This is the blueprint to decide whether
to commit to a ground-up native Mac app. The current Electron app is unaffected.

## Why do this at all

A WKWebView app *is* Safari's engine, which gets us things Electron
**fundamentally cannot**:

- **DRM / streaming works** — WebKit ships FairPlay EME, so Netflix, Disney+,
  Spotify, etc. play (the wall we just hit in Electron disappears).
- **Passkeys work** — native WebAuthn + iCloud Keychain. No "locked out, no
  fallback" problem.
- **Light + native** — no bundled ~150 MB Chromium; shared system WebKit. Far
  less RAM, better battery, native feel and integration.
- **System content blocking** — WKContentRuleList is fast and built in.

## The honest cost

- **It's a from-scratch rewrite, not a migration.** Nothing in the Electron
  codebase (main.js, all the HTML/CSS UI, the node-llama-cpp wiring) carries
  over. Realistically weeks-to-months to reach parity.
- **Windows is dropped.** WKWebView is Apple-only. This becomes a Mac-only
  product (or two separate codebases — not recommended).
- **WebKit ≠ Chromium.** Some sites behave differently; extension/devtools
  story is more limited. Acceptable for a Safari-compatible browser.

## Stack

- **Language/UI:** Swift. AppKit for the browser chrome (precise control over
  tabs/sidebar/traffic-lights/split view), SwiftUI for settings panes.
- **Engine:** WKWebView, one per tab, sharing a `WKWebViewConfiguration` /
  process pool + a `WKWebsiteDataStore` for shared cookies/session. A separate
  non-persistent data store for incognito.
- **Local AI:** llama.cpp directly via its C API (Metal backend) through a
  SwiftPM C target / bridging header. Loads the same Qwen2.5 GGUF.
  ⚠️ Function-calling (tools) must be implemented by hand — there's no
  node-llama-cpp helper. This is the single biggest AI chunk of work.
- **Ad blocking:** convert EasyList → WKContentRuleList JSON (AdGuard has a
  converter) compiled at launch. Native, efficient.
- **Password vault:** macOS Keychain (Security framework) — strictly better
  than the current encrypted file. Autofill via injected `WKUserScript` +
  `WKScriptMessageHandler`.
- **Reminders:** UserNotifications framework (native, more reliable).
- **Auto-update:** Sparkle (the standard macOS framework) instead of
  electron-updater.

## Feature parity map (Electron → Swift, with difficulty)

| Feature | Native approach | Difficulty |
|---|---|---|
| Tabs / nav / sessions | WKWebView + AppKit tab model | Med |
| Sidebar, pins, groups, split view | AppKit/SwiftUI views | Med–High |
| New-tab page + Dia-style input | SwiftUI view (native, no HTML) | Med |
| AI assistant chat + fullscreen/dock | SwiftUI + llama.cpp streaming | High |
| AI tools (web_search/open_page/read/remind) | Custom grammar + DOM read via `evaluateJavaScript` | High |
| Ad block | WKContentRuleList | Med |
| Password vault + autofill | Keychain + WKUserScript | Med–High |
| History / downloads | Native store + WKDownload | Med |
| Reminders | UserNotifications | Low–Med |
| Notification overlay/toasts | Native NSView overlay | Low |
| Updates | Sparkle | Low |
| DRM streaming | Works via FairPlay (validate!) | — |
| Passkeys | Works via WebAuthn (validate!) | — |

## Risks to validate FIRST (the whole premise rides on these)

1. **Netflix/FairPlay actually plays in a plain WKWebView** (may need specific
   entitlements/config). This is the #1 reason to do the rewrite — prove it.
2. **Passkeys/WebAuthn work in WKWebView** for a third-party browser (may need
   Associated Domains / being a registered default browser).
3. **llama.cpp Swift integration + Metal perf** is acceptable and streaming +
   tool-calling can be reimplemented cleanly.

If #1 or #2 don't pan out, the main rationale weakens — so they get a tiny
throwaway proof-of-concept before any real building.

## Milestones

- **M0 — De-risk PoC (small):** WKWebView shell (window, one tab, address bar).
  Verify Netflix plays + a passkey login works + llama.cpp loads & streams.
- **M1 — Core browser:** multi-tab, nav, sessions, history, downloads, incognito.
- **M2 — Chrome UI:** sidebar, pins, tab groups, split view, settings, themes.
- **M3 — AI assistant:** llama.cpp chat, fullscreen/dock, tools (search/open/
  read/remind), model picker.
- **M4 — Privacy:** ad blocking, Keychain vault + autofill, per-site permissions.
- **M5 — Ship:** Sparkle auto-update, Developer ID signing + notarization, polish.

M0 is the gate. Don't commit to M1+ until M0 proves DRM + passkeys.

## Decisions needed before starting

1. **Confirm Mac-only** (drop Windows) — or keep Electron for Windows in
   parallel?
2. **Minimum macOS version** — passkeys/modern WebKit want macOS 13+, ideally
   **14+**. Older support costs features.
3. **UI:** recreate the current look closely, or redesign natively?
4. **Apple Developer ID now?** Needed for notarized distribution and likely for
   passkeys/associated-domains to behave. (~$99/yr.)
5. **Order:** do M0 PoC next, or keep shipping Electron (multi-window 3.0) first
   and slot the PoC alongside?
