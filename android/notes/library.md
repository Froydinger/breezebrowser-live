# Local Library actions

The Library screen uses one `LazyColumn` for Chats, Bookmarks, and Web history so
large collections remain scrollable without a fixed item cap or nested scrolling
lists. Search filters the complete local lists by page title/URL and chat title,
message text, and source title/URL. The All filter searches all three collections.

Each bookmark, history visit, and saved chat has a Delete action with a confirmation
dialog. Deletion mutates the corresponding `BrowserState` list and calls `persist()`.
Deleting the active chat also cancels its current request and returns from Chat to the
browser screen. The Web history section has a separate confirmed Clear history action;
it clears web visits only and leaves bookmarks and chats intact.

Bookmarks can be edited in place. The editor requires a parseable HTTP(S) URL with a
host and a nonblank title. It updates the immutable `SavedPage` with `copy`, preserving
its ID and saved timestamp, replaces the existing item, and persists the change.

These operations use the existing encrypted local state store. They do not enable
account sign-in or cloud sync; sync remains Coming soon. This task was reviewed by
source inspection only. No build or tests were run.
