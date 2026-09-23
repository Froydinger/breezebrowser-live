# Breeze Android visual package

This is the approved visual reference set for the Android companion app. It follows the selected reference screenshot. The package contains mockups and wallpaper artwork only; Android implementation has not started.

## Visual direction

- **Dark:** near-black browser surfaces like Breeze desktop, with teal used for small accents.
- **Light:** warm off-white surfaces, dark readable text, and the same restrained teal accents.
- Theme follows the device by default, with System, Light, and Dark choices in browser settings.
- Home backgrounds are selectable: Night Coast, Teal Facets, Quiet Dunes, and Aurora. Each has a light and dark artwork variant.

## Home and browser behavior

- Keep the selected reference’s Breeze identity, combined Ask/address field, shortcut row, recent tabs, and bottom browser controls.
- The combined field opens URLs directly. In the default Ask mode, all ordinary text starts a fresh Nav chat; an explicit search action or the optional Search mode opens search results. Spectra is the default search engine at `spectrasearch.online`, with a small “Powered by Spectra” label under the home field.
- The home page has one **Recent chats** tile. The History page includes both web visits and chats; Recent chats and History lead to the same saved conversations.
- On web pages, the Breeze Nav icon sits at the top right. The address field contains the lock and sliders/tools controls plus reload; there is no separate three-dot button.
- Search results use the real `spectrasearch.online` page when the user chooses to open them. This package intentionally does not invent a Spectra results page.

## Nav on mobile

- Chat, `/research`, `/youtube`, and other tools stay in the Nav conversation.
- While a tool is working, show the desktop-style edge glow, the glowing Nav mark, and a readable progress path. Clear the glow when the task finishes.
- Completed answers stay inline in chat. Source and video cards include **Open in tab** so the user chooses what to browse.
- The mobile layout is chat-first; it does not require desktop split panes or a separate research summary screen.

## Screens

All phone screens have dark and light pairs in `mockups/`.

| Screen | Dark | Light |
| --- | --- | --- |
| Home | [home-dark.png](mockups/home-dark.png) | [home-light.png](mockups/home-light.png) |
| Web page and address controls | [webpage-dark.png](mockups/webpage-dark.png) | [webpage-light.png](mockups/webpage-light.png) |
| Tab wall | [tabs-dark.png](mockups/tabs-dark.png) | [tabs-light.png](mockups/tabs-light.png) |
| Recent chats | [recent-chats-dark.png](mockups/recent-chats-dark.png) | [recent-chats-light.png](mockups/recent-chats-light.png) |
| History | [history-dark.png](mockups/history-dark.png) | [history-light.png](mockups/history-light.png) |
| Nav conversation | [nav-chat-dark.png](mockups/nav-chat-dark.png) | [nav-chat-light.png](mockups/nav-chat-light.png) |
| Library | [library-dark.png](mockups/library-dark.png) | [library-light.png](mockups/library-light.png) |
| Settings | [settings-dark.png](mockups/settings-dark.png) | [settings-light.png](mockups/settings-light.png) |
| Background picker | [background-picker-dark.png](mockups/background-picker-dark.png) | [background-picker-light.png](mockups/background-picker-light.png) |
| `/research` running | [research-running-dark.png](mockups/research-running-dark.png) | [research-running-light.png](mockups/research-running-light.png) |
| `/research` completed in chat | [research-chat-result-dark.png](mockups/research-chat-result-dark.png) | [research-chat-result-light.png](mockups/research-chat-result-light.png) |
| `/youtube` running | [youtube-running-dark.png](mockups/youtube-running-dark.png) | [youtube-running-light.png](mockups/youtube-running-light.png) |
| Creator Tools result in chat | [youtube-chat-result-dark.png](mockups/youtube-chat-result-dark.png) | [youtube-chat-result-light.png](mockups/youtube-chat-result-light.png) |

The original supplied design reference is [selected reference](mockups/concept-d-reference.jpg). Standalone wallpaper artwork is in `backgrounds/`.

## Selectable backgrounds

| Background | Dark | Light |
| --- | --- | --- |
| Night Coast | [night-coast-dark.png](backgrounds/night-coast-dark.png) | [night-coast-light.png](backgrounds/night-coast-light.png) |
| Teal Facets | [teal-facets-dark.png](backgrounds/teal-facets-dark.png) | [teal-facets-light.png](backgrounds/teal-facets-light.png) |
| Quiet Dunes | [quiet-dunes-dark.png](backgrounds/quiet-dunes-dark.png) | [quiet-dunes-light.png](backgrounds/quiet-dunes-light.png) |
| Aurora | [aurora-dark.png](backgrounds/aurora-dark.png) | [aurora-light.png](backgrounds/aurora-light.png) |

## Implementation plan

- [Full Android and desktop sync plan](ANDROID-PLAN.md)
- [Luna subagent build assignments](BUILD-TASKS.md)
- [Google Play setup and distribution](GOOGLE-PLAY-SETUP.md)

The implementation plan governs behavior where illustrative mockup text differs. Use actual production logos and real tool progress. Android implementation has not started.
