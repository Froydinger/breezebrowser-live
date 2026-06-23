# Breeze

Breeze is a fast native macOS browser built with Swift, AppKit, and WKWebView. Nav, its built-in assistant, talks to Breeze Cloud for GPT-5.4-mini chat plus gpt-image-2 image generation/editing without exposing an API key in the app.

## Run it

```bash
cd native
./build.sh
open dist/Breeze.app
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
| Next / Previous tab | `Ctrl+Tab` / `Ctrl+Shift+Tab` |
| Jump to tab | `⌘1`–`⌘9` |
| Toggle dark mode | `⇧⌘D` |
| Zoom | `⌘+` / `⌘-` / `⌘0` |
| DevTools (for current page) | `⌥⌘I` |
| Toggle Nav | `⌘E` |

## Features

- **Nav** — GPT-5.4-mini chat, browser actions, reminders, image generation, and image edits through the Breeze Cloud Worker.
- **Ad & tracker blocking** — EasyList content rules run in the network layer of every tab.
- **Auto-update** — packaged builds check GitHub Releases on launch and every 4 hours, download silently, and show a "Restart" toast. No-op in dev mode.
- **Themes** — light by default, dark via the sidebar toggle or `⇧⌘D`. Persisted across launches, and the new-tab page follows the system theme.
- **Sidebar** — Arc-style vertical tabs with favicons, loading spinners, and middle-click to close. Hide it with `⌘S` for a zen full-bleed view.

## Shipping updates

Auto-update is wired to GitHub Releases. See `AGENTS.md` for the native release pipeline.
