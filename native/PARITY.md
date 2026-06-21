# Breeze native — parity audit vs Electron

Legend: ✅ done · 🟡 partial · ❌ missing

## Chrome / behavior
- ✅ Multi-tab WKWebView, Safari UA
- ✅ Sidebar: pins grid, tab rows, groups, now-playing, footer
- ✅ Pins housed in icon (Arc/Dia style), open/active rings, pin menu
- ✅ Tab right-click menu (Pin/Move to Group/Duplicate/Perf/Popups/Close)
- ✅ Performance Mode (🚀 badge, square corners)
- ✅ Top URL bar (clears traffic lights), nav, copy/clearcache/bookmark/share
- ✅ New-tab page (clock/greeting/Ask), input no longer clips
- ✅ Light/Dark/System theme; sidebar edge-peek
- ✅ History / Bookmarks / Downloads (data + pages), now-playing detection
- 🟡 Accent: tint wash done → switching to mono default + black picker dot (this pass)
- ❌ **Sidebar resize** (this pass)
- ❌ **URL bar Top/Sidebar mode** (this pass)
- ❌ **Thinner bezels** (this pass)
- ❌ **Split view** (next)
- ❌ Incognito tabs (⌘⇧N)
- ❌ Ad blocking (WKContentRuleList)
- ❌ Tab sleep (tabSleepHours)
- ❌ Zoom (⌘0/⌘+/⌘-), Hard Reload (⌘⇧R), Dev Tools (⌥⌘I)
- ❌ Ctrl+Tab / Ctrl+Shift+Tab / ⌘1–9 tab switching
- ❌ Drag-reorder tabs & pins
- ❌ Page right-click menu (open link, copy image, search selection, fill pw…)
- ❌ Sparkle auto-update / Check for Updates

## Settings wiring
- ✅ theme, pinSize, searchEngine, clock24, showGreeting, accent
- ✅ Danger Zone (clear data, reset)
- 🟡 urlBarPosition (this pass)
- ❌ adblockEnabled, tabSleepHours, autoPip, restoreTabs,
  flattenFullscreenCorners, webNotifications, notification/update sounds,
  site permissions, System section
- ❌ Breeze AI / Reminders (Phase C)

## Phase C
- ❌ Qwen llama.cpp assistant + tools (deferred, known)
