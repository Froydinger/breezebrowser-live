# Android domain and input routing contract

Package: `com.froydinger.breeze.core`. These files use only the Kotlin/JDK APIs.

## Domain types

`Models.kt` provides UUID-backed records for tabs, bookmarks, history visits, chats,
messages, and citations, plus enums and `BrowserSettings`. Models are immutable Kotlin
data classes. Storage adapters should persist the IDs rather than regenerate them when
records are loaded. Private visits are marked with `HistoryEntry.isPrivate`; callers
must avoid persisting them.

## Input routing

Call `InputRouter.route(rawInput, surface, homeMode, searchEngine, explicitSearch)`.
It returns `null` for blank input or one of:

- `InputRoute.OpenUrl(url)` for URL/domain-like input.
- `InputRoute.Search(query, engine, url)` for explicit search, Search mode, or a
  short desktop address-bar query.
- `InputRoute.StartChat(prompt, fresh = true)` for an independent home Ask chat or
  conversational webpage address input.
- `InputRoute.RunTask(task, prompt)` for a recognized slash task.

Recognized task slugs follow desktop matching: exact match first, then a unique prefix.
The included tasks are `/research`, `/summarize`, `/factcheck`, and `/youtube`.
An unrecognized slash string falls through as ordinary input. URL detection and the
webpage short-query heuristic are deterministic; home Ask intentionally does not apply
the short-query heuristic. `search ...` and `look up ...` explicitly search using the
selected engine. `search with <engine> ...` selects a named engine. On webpage address
input, desktop-compatible `google ...` is a search cue but still uses the selected
engine; on home Ask it remains ordinary chat text. “Open search results for ...” opens
the real Spectra results route. Only HTTP(S) schemes can route as URLs; custom schemes
such as `javascript:` and `file:` are not opened.

Spectra routes to `https://spectrasearch.online/search?q=...`, per the Android plan.
Other search URLs preserve desktop engine choices. This is routing policy only; it does
not open tabs, create chats, or execute tasks. The UI owns those effects.
