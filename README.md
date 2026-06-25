# Breeze Browser

Breeze is a fast native macOS browser built with Swift, AppKit, and WKWebView. Nav, its built-in assistant, talks to Breeze Cloud for GPT-5.4-mini chat plus gpt-image-2 image generation/editing without exposing an API key in the app.

Current release: **4.0.6** for Apple Silicon Macs.

## Run it

```bash
cd native
./build.sh
open dist/Breeze.app
```

To test without touching the live Breeze profile:

```bash
cd native
BREEZE_APP_NAME=BreezeTest \
BREEZE_BUNDLE_ID=com.jakefreudinger.breeze.native.test \
BREEZE_DIST=dist-test \
./build.sh
open -n dist-test/BreezeTest.app --args --profile BreezeTest
```

## Shortcuts

| Action | Shortcut |
|---|---|
| Toggle sidebar | `⌘S` / `Ctrl+S` |
| New tab | `⌘T` |
| Close tab | `⌘W` |
| Focus address bar | `⌘L` |
| Back / Forward | `⌘[` / `⌘]` |
| Reload / Hard reload | `⌘R` / `⇧⌘R` |
| Page zoom | `⌘+` / `⌘-` / `⌘0` |
| Next / Previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Jump to tab | `⌘1`–`⌘9` |
| Toggle dark mode | `⇧⌘D` |
| DevTools (for current page) | `⌥⌘I` |
| Toggle Nav | `⌘E` |

## Features

- **Nav** — GPT-5.4-mini chat, browser actions, reminders, image generation, and image edits through the Breeze Cloud Worker. Fair-use limits are 30 chat requests and 10 image generations/edits per day.
- **Cloud key safety** — users do not bring or expose an OpenAI API key in the browser. Breeze talks to the Cloudflare Worker instead.
- **Ad & tracker blocking** — EasyList content rules run in the network layer of every tab.
- **Permissions** — websites can request microphone, camera, and location access through native WebKit permission prompts, with saved choices managed in Settings.
- **Tab groups** — create, rename, disband, or delete groups. Command-clicking same-site links opens them in a grouped tab.
- **Auto-update** — packaged builds check GitHub Releases on launch and every 4 hours, download silently, and show a "Restart" toast. No-op in dev mode.
- **Themes** — teal is the default accent. Light, dark, system, black/white mono, and custom accents persist across launches.
- **Sidebar** — Arc-style vertical tabs with favicons, loading spinners, and middle-click to close. Hide it with `⌘S` for a zen full-bleed view.
- **Nice failures** — failed navigations render a Breeze recovery screen with retry/back suggestions instead of a raw WebKit dead end.

## Shipping updates

Auto-update is wired to GitHub Releases. See `AGENTS.md` for the native release pipeline.
