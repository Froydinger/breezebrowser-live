# Breeze

Breeze is a fast, Chromium-based browser with local AI, native ad blocking, and zero tracking. Your data stays yours. Forever.

## Run it

```bash
npm install
npm start
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

## Features

- **Ad & tracker blocking** — Ghostery's adblocker engine (EasyList + tracking lists) runs in the network layer of every tab. Blocked count shows in the sidebar pill. Filter lists are cached and refreshed automatically.
- **Auto-update** — packaged builds check GitHub Releases on launch and every 4 hours, download silently, and show a "Restart" toast. No-op in dev mode.
- **Themes** — light by default, dark via the sidebar toggle or `⇧⌘D`. Persisted across launches, and the new-tab page follows the system theme.
- **Sidebar** — Arc-style vertical tabs with favicons, loading spinners, and middle-click to close. Hide it with `⌘S` for a zen full-bleed view.

## Shipping updates

Auto-update is wired to GitHub Releases via `electron-builder` (see the `publish` block in `package.json` — point `owner`/`repo` at your repo). To cut a release:

```bash
npm version patch
GH_TOKEN=<token> npm run release
```

Installed copies pick it up on next launch.
