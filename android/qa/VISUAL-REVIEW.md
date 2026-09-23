# Breeze Android visual review

**Review type:** independent screenshot comparison, read-only
**Reviewed:** September 23, 2026
**Approved references:** `android-design/mockups/`

## Conclusion

The reviewed emulator captures follow the approved screen hierarchy, spacing, theme palette, and control placement closely enough for this visual pass. Home, tabs, history, settings, background selection, and Nav research result/running states have been compared in dark and light where captures were available. No remaining high-priority visual mismatch was identified in the final reviewed captures.

This is a bounded screenshot review. It does not establish pixel-perfect equivalence, complete feature functionality, accessibility conformance, or physical-device acceptance.

## Captures reviewed

- Home: `final-home-dark.png`, `final-home-light.png`
- Tabs: `final-tabs-dark.png`, `final-tabs-light.png`, `final-tabs-lower-light.png`
- History: `final-history-dark.png`, `final-history-light.png`
- Settings: `final-settings-dark.png`, `final-settings-light.png`, `final-settings-lower-dark.png`
- Background picker: `final-backgrounds-dark.png`, `final-backgrounds-light.png`
- Nav: `final-chat-light.png`, `final-research-running-dark.png`, `final-research-result-dark.png`, `final-research-result-light.png`
- Additional state checks: `chat-keyboard-dark.png`, `research-sources-dark.png`

The corresponding approved examples include `home-dark.png` / `home-light.png`, `nav-chat-dark.png` / `nav-chat-light.png`, `history-dark.png` / `history-light.png`, `settings-dark.png` / `settings-light.png`, `tabs-dark.png` / `tabs-light.png`, `background-picker-dark.png` / `background-picker-light.png`, and the research running/result examples, all under `android-design/mockups/`.

## Accepted differences

- The polygon wallpaper remains in the app in place of the scenic home wallpaper.
- The bottom navigation uses a floating glass pill.
- The app uses Lucide-style outline icons, including generic globe icons where a site favicon is not supplied.
- Home keeps a small Settings shortcut so settings remain discoverable.
- Real tab titles, thumbnails, web results, citation counts, and provider-generated answer text vary from illustrative mockup content.
- Running research shows provider-reported statuses only. It does not fabricate page visits or navigation steps; the full-window edge glow and Nav mark illumination are retained for the running state.
- The emulator and reference images have different aspect ratios, so some vertical wrapping and density differences are expected.

## Evidence limits

- Captures are from an Android emulator at 1080×2424. No physical phone comparison is included.
- The reviewed history data contains same-day items, so the final captures do not exercise Yesterday/Earlier section transitions, even though the reference shows those groups.
- The results shown are particular live/local content states, not fixed visual fixtures. This review checks their layout and hierarchy rather than exact wording, source count, or thumbnails.
- Screenshots do not verify every control action, screen-reader behavior, large-font layout, rotation, or other device sizes.
