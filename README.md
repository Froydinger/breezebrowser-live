# Breeze Browser

Breeze is a native macOS browser built with Swift, AppKit, and WKWebView. The
current source version is **6.3.5** for Apple Silicon Macs.

## Aero

Aero is Breeze's built-in browser assistant. It can answer questions about a
page, search and research the web, summarize content, fact-check claims, analyze
YouTube videos, use browser actions, and create reminders. Requests run through
Breeze Cloud; image generation and editing are not supported. Image attachments
can be included as context when supported by the request flow.

Spectra is the default search engine for the address bar and new-tab page. Users
can choose another engine in Settings.

## Breeze Cloud accounts and sync

Signing in with Google or email is optional. Signing in alone does not upload
browser data. Separate sync controls are available for bookmarks, open tabs,
history, Aero chats, and reminders; each category starts off. The password vault,
private tabs, cookies, and website storage stay on the Mac. Synced cloud copies
are protected in transit but are not end-to-end encrypted. Turning a category
off pauses future syncing; deleting the account removes cloud data.

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
| Toggle Aero | `⌘E` |

## More features

- EasyList ad and tracker blocking in WebKit.
- Native website permission prompts for microphone, camera, and location.
- Tab groups, pinned sites, split browsing, picture-in-picture, downloads,
  history, bookmarks, and reminders.
- Optional macOS appearance, dark, light, and accent settings.
- Packaged builds check GitHub Releases for updates.

## Download and privacy

- macOS (Apple Silicon): <https://github.com/Froydinger/breezebrowser-live/releases/latest>
- All releases: <https://github.com/Froydinger/breezebrowser-live/releases>
- Privacy Policy: <https://breeze.froydingermedia.online/privacy.html>
- Terms of Use: <https://breeze.froydingermedia.online/terms.html>

Direct Mac releases use Apple Developer ID signing, hardened runtime, and Apple notarization. Local builds remain separate. See `AGENTS.md` for the native build and release workflow.
