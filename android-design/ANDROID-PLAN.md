# Breeze for Android: implementation plan

Approved September 23, 2026. Implementation authorized and underway; production deployment remains a separate release step. Read alongside the [visual package](README.md), [build assignments](BUILD-TASKS.md), and [Play setup guide](GOOGLE-PLAY-SETUP.md).

## Current scope amendment

September 23: user clarified there are no accounts or sync yet. Initial Android release is local-first with **Cloud sync — Coming soon** and no sign-in flow. Breeze Cloud Nav remains part of the app. The full-sync architecture below is retained as a deferred design, superseding its earlier launch requirement. Password vault stays local. Existing new sync/auth source is preparatory and must not be deployed or advertised as connected.

## 1. Product commitments

Build a native Android browser with the selected Breeze design, Breeze Cloud Nav, and **full bookmark, browsing history, and chat sync with desktop at launch**. Browsing works without signing in. Cloud AI and sync require an account. Desktop retains its existing workspace layout; mobile tools stay in chat.

### Liquid glass material refinement

Keep all approved layouts and controls unchanged. Apply subtle translucent glass to browser-owned bars, cards, and sheets, with soft specular highlights and a narrow refracting-looking edge. Preserve neutral black/charcoal in dark mode and teal accents only. Use static gradients and layered rims first; actual backdrop refraction is optional and gated on measured performance. Never repeatedly screenshot web content to simulate glass. Text stays crisp, surfaces retain sufficient opacity for contrast, and Reduce transparency disables the finish. No perpetual shimmer, motion or shader loop. Website content is unaffected.

### Input behavior is a contract

| Context/input | Result |
| --- | --- |
| Home, valid URL/domain | Open the website |
| Home in default Ask mode, any ordinary text | Start a fresh independent Nav conversation, even for short phrases |
| Recognized slash command | Start its tool in Nav chat |
| Explicit search action/modifier, or home switched to Search | Open the selected search engine |
| Existing webpage address bar | Preserve desktop URL/short-search/conversational routing |
| URL inside a conversation | Treat as context; open only on explicit request or tap |
| “Open search results for …” | Open the real Spectra results page |

Port the desktop rules from `BrowserController.submitQuery` and `looksLikeSearchTerm` as deterministic shared fixtures. Do not pay an LLM to classify a URL. Default search URL is `https://spectrasearch.online/search?q=<encoded query>`; this route was checked successfully. Desktop currently uses `.info`, so the companion update must align it with the requested `.online` domain.

### Visual contract

- Preserve the selected reference: Breeze identity, combined Ask/address field, shortcuts, recent tabs, bottom controls, one Recent chats tile. No Cloud or Nav tile on home.
- Dark surfaces use desktop charcoal `#191919` and neutral blacks; teal `#3AA6B9` is an accent. Light uses warm `#F2F0ED`. Settings: System / Light / Dark.
- Tiny “Powered by Spectra” under the home field. Offer alternative search engines in settings.
- Use the approved mobile mockup’s teal double-wave artwork. The desktop feather icon is not the mobile design. Nav sits upper-right outside the webpage address pill. Lock, tools/sliders, and reload live inside the pill.
- Night Coast, Teal Facets, Quiet Dunes, Aurora wallpapers, each with dark/light artwork. Downsample and cache locally; no wallpaper network dependency.
- History filters All / Web / Chats and Recent chats reference the same records.
- Running tools use the edge glow and Nav halo, stop on completion/error/cancel, respect reduced motion. Display actual available tool events; never fabricate visited sites or reveal private reasoning.
- All results, citations, source cards, and “Open in tab” stay inside chat. Actual Spectra pages retain Spectra’s own design.
- Mockup copy is illustrative: “Search Spectra” must become “Searching the web” when hosted search is used. Do not invent YouTube retention analytics from a public video.
- Root designs remaining account, pairing, recovery, permissions, offline, empty/error, and deletion states with the same tokens before their UI implementation.

## 2. Native architecture

**Kotlin + Jetpack Compose + stable GeckoView** is the proposed foundation. GeckoView provides a browser engine intended for embedding full browsers and offers browser/session and extension control. Its bundled engine increases download size and requires timely app updates for engine security fixes. An early compatibility gate must confirm password-manager/autofill, passkeys, DRM/video, downloads, uploads, accessibility, and private-session behavior before committing the complete product. [Mozilla GeckoView](https://mozilla.github.io/geckoview/)

Use one engine, not parallel WebView and Gecko implementations. Android System WebView is a lighter alternative if the engine gate exposes an unacceptable compatibility gap; changing that decision requires a concrete findings report.

Proposed minimum Android 10/API 29; compile/target at least API 36, updated to the then-current Play requirement at release. Pin a stable compatible Kotlin/Compose/AGP/Gecko set and a Gradle wrapper at kickoff. Use JDK 17 explicitly. Validate every native library, including Gecko and SQLCipher, on 16 KB page-size devices. [Target SDK policy](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en), [16 KB guidance](https://developer.android.com/guide/practices/page-sizes)

Suggested modules:

- `app`: dependency wiring, lifecycle, intents, navigation.
- `core-model`, `core-design`, `core-data`, `core-network`, `core-crypto`: small stable interfaces.
- `browser-engine`: sessions, navigation, permissions, downloads, content extraction.
- `feature-home`, `feature-tabs`, `feature-library`, `feature-settings`, `feature-nav`.
- `sync`: outbox, merge rules, encryption, devices, migration.

Use Room with current SQLCipher Android for sensitive app records; DataStore for nonsecret preferences. Protect database keys with Android Keystore. Engine profiles and cookies are a separate storage boundary protected by Android sandbox/device encryption; encrypting Room does not automatically encrypt Gecko’s files. Exclude sensitive data and keys from inappropriate Android backup paths. [SQLCipher Android integration](https://www.zetetic.net/sqlcipher/sqlcipher-for-android-migration/)

## 3. Browser launch scope

| Area | Required behavior |
| --- | --- |
| Tabs | Visual wall, new/close/undo, reorder/groups, restore after process death, sleeping tabs, explicit open-source-in-tab |
| Library | Searchable bookmarks/folders, imports/exports, mixed history/chats, downloads, selective clearing |
| Navigation | Back/forward/reload/home, predictive back integration, links/intents/default-browser role, safe external-app handoff |
| Page tools | Find, share, copy link, reader where supported, desktop site, zoom/text scale, long-press menus |
| Files/media | Android file/photo picker, downloads with progress/cancel/retry, fullscreen video and supported PiP |
| Permissions | Origin-specific camera/mic/location prompts and revocation; no blanket grants |
| Credentials | Existing password managers/autofill/passkeys through supported engine integration; a separate local encrypted password vault unlocked with device biometrics/PIN; website passkeys through the platform credential provider |
| Privacy | Private sessions, isolated storage, no private history/sync/thumbnail persistence, clear site data, tracking protection |
| Blocking | Engine tracking protection plus maintained compatible adblock filtering; site exceptions and breakage recovery |
| Accessibility | TalkBack labels/order, 48 dp targets, large fonts, contrast, reduced motion, keyboard handling |
| Nav | Chat, research, summarize, factcheck, YouTube tools, supported reminders, source opening; attachment/camera affordances with clear permissions |

Evaluate a bundled first-party extension using a maintained EasyList-compatible engine such as Ghostery’s adblocker. Audit code/filter licenses and distribution obligations. Start with stable lists, compile/cache off the UI thread, and provide per-site exceptions. Do not promise blocking every ad or YouTube video ad. [Adblocker project](https://github.com/ghostery/adblocker), [GeckoView extensions](https://mozilla.github.io/geckoview/consumer/docs/web-extensions)

General extension installation, VPN, and complete PWA/web-push support are not implicit launch commitments. Record engine support and product requirements before adding them. No image-generation product feature or local model/model picker.

## 4. Breeze Cloud and mobile Nav

### Existing system, inspected locally

`cloudflare/breeze-chat-worker` currently proxies Chat Completions and realtime-token requests. Config selects `gpt-6-luna`; it has no hosted web-search or streamed chat response path. It uses a shared client token, permits access if that secret is absent, and accepts a caller-provided quota identity. Those are unsuitable as public mobile account controls. Existing desktop behavior must remain functional during migration.

Wrangler 4.103.0 is installed locally and authenticated with Worker permissions. Chrome is an administration fallback, not a browser session exposed to the cloud. No Worker was changed or deployed during planning.

### Deployment boundaries

1. Keep `breeze-chat` compatible for existing desktop clients.
2. Add `breeze-mobile` for authenticated mobile Nav and durable tool runs.
3. Add `breeze-sync` for shared account/device/sync services used by Android and the desktop companion release.
4. Separate development/staging/production bindings, secrets, databases, quotas, and origins. No production shared token in the APK.

Use OpenAI Responses with server-selected `gpt-6-luna`, streaming, and the `web_search` tool. Official model documentation lists support; no paid provider request was run for this plan. Tavily is unnecessary for the initial architecture. Keep an internal search adapter so a future change does not alter the UI contract. [Luna model](https://developers.openai.com/api/docs/models/gpt-6-luna), [Web search API](https://developers.openai.com/api/docs/guides/tools-web-search)

Render actual citation annotations and request `web_search_call.action.sources` when supported. Show “Searching the web” when only a generic search event is available; a detailed path requires actual source events. Hosted search does not mean tabs are visibly navigating on the device.

### Run protocol

Versioned requests carry `chatId`, `turnId`, `runId`, idempotency key, task type, and explicitly selected context. Events carry schema version, run ID, monotonic event ID, type and payload: accepted, status, tool-started, source, text-delta, citation, completed, failed, cancelled. Persist final messages and reconcile partial text after reconnect without duplicate messages.

Use typed tool actions and JSON schemas. Do not parse arbitrary model prose such as `OPEN:` as executable commands. Any selected-page context is bound to tab ID, document ID, and origin; reject stale navigation context. Website text is untrusted. Restrict native extension messages by extension identity, origin/frame, document and request nonce. Never expose generic native execution or secrets to websites.

Cloud fetch tools must allow only supported public HTTP(S) destinations, revalidate redirects, block private/link-local/metadata networks, bound response size/time/content types, and avoid forwarding browser cookies. Never upload entire history/bookmarks/open tabs by default. Desktop’s existing opt-in context preferences remain opt-in.

Opening a link is explicit user intent or a tapped source card. Purchases, publishing, account changes, or destructive site actions require a concrete user confirmation. Research itself can search/read public sources without repeatedly interrupting the user.

### Background work and cost control

Ordinary chat streams while foregrounded. Longer research/YouTube runs use Cloudflare Workflows with a Durable Object event log and reconnect cursor. Cancellation is best effort for an already-running provider call and stops subsequent work. Do not depend on unbounded `waitUntil` or continuous phone wake locks. [Cloudflare Workflows](https://developers.cloudflare.com/workflows/)

Paid steps need request-hash idempotency, checkpoints, bounded retries, and explicit handling of uncertain upstream completion. Never silently repeat a paid call because the UI reconnects. Configure workflow retries deliberately. Record only minimal references in workflow outputs; audit the platform’s retained step history before claiming deletion limits.

Account-derived quotas, atomic reservations before requests, token/search/tool/concurrency limits, timeout caps, and global emergency budget ceilings are launch requirements. Starting caps for evaluation: 8,192 output tokens for chat, 16,384 for research, and eight tool calls per run. Tune from quality/cost measurements. Do not inherit the existing 128,000 output limit blindly. Reconcile reservations against actual usage; cache completed duplicate requests. Cloud usage is separate from Codex build credits. Set the public free allowance and monthly spend ceiling before opening unrestricted registration.

YouTube tools use legitimately available transcripts/metadata. If a transcript is unavailable, state the limitation and offer a user-supplied transcript. Never imply the system watched a video or knows private retention metrics without evidence.

## 5. Account and complete sync at launch

### Account identity

Use Google sign-in initially for a Breeze account, with minimal OpenID/email/profile scopes. Prefer a maintained OIDC implementation and a server auth broker on an owned HTTPS domain. Validate issuer, audience, expiry, nonce, signature/JWKS and stable subject; do not identify accounts by changeable email alone. Use state and PKCE. Return a one-use app grant bound to the requesting client, not provider access tokens in deep links. Android verified App Links and an appropriate desktop native callback complete the flow. Freeze exact provider integration after a short cross-client authentication spike. [Google OIDC](https://developers.google.com/identity/openid-connect/reference)

Issue short-lived Breeze access tokens and rotating refresh credentials with server-side hashed storage and device revocation. Fail closed on missing auth configuration. Play Integrity verifies the expected app/package/signing certificate and request binding for public mobile use; it supplements account auth and limits, not replaces them. Keep debug enrollment isolated to staging. [Play Integrity](https://developer.android.com/google/play/integrity/standard)

### Encryption boundary

Bookmarks, web history, and saved chat records sync as **end-to-end encrypted records**. Generate a random vault root key on a trusted client; protect local keys with Android Keystore and macOS Keychain. Use vetted AES-GCM implementations with unique random nonces and authenticated record ID, collection, schema, key epoch, and device metadata.

Pair a new signed-in device using a short-lived QR flow and verification code. Wrap keys with a standard interoperable HPKE suite; authenticated device enrollment is required because encryption alone does not authenticate the sender. Verify Tink/CryptoKit interoperability, serialization and published vectors before shipping. Root owns this design and review. [Tink HPKE](https://developers.google.com/tink/hybrid), [CryptoKit HPKE](https://developer.apple.com/documentation/cryptokit/hpke)

Provide a user-held recovery key with an explicit save-and-confirm step. Google sign-in alone cannot decrypt the vault. Losing every trusted device and recovery key means losing access to encrypted data. Revocation blocks subsequent access and rotates future keys; it cannot erase copies a device already received.

**AI processing is a different boundary:** selected prompts/context are decrypted on the client and sent over TLS to Breeze Cloud and OpenAI for processing. Do not market AI requests as end-to-end encrypted. Minimize transient run retention, use `store:false` where applicable, and accurately disclose provider retention instead of promising zero retention. Avoid prompt, URL and response content in ordinary logs. [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data)

### Sync mechanics

- D1 stores account/device metadata; a per-account Durable Object serializes encrypted operations and cursors; R2 holds encrypted large attachments/snapshots. Do not use eventually consistent KV as the authoritative ordered log.
- Local data mutation and outbox insertion are one transaction. Retry uploads idempotently; apply downloaded operations transactionally before advancing the cursor.
- Stable UUID records and server revisions; bookmarks merge by field with deterministic conflicts. History visits are immutable events. Chat messages have immutable IDs and parent links; concurrent continuations preserve branches instead of overwriting a conversation.
- Deletes propagate as tombstones. Devices older than the retained cursor floor must resnapshot, preventing old backups from resurrecting deleted records. Define compaction and tombstone rules before implementing clients.
- Category toggles and explicit initial-sync consent; paginated/resumable backfill without silent record caps. Keep private sessions out. Sync chat citations and user-selected attachments with the chat.
- Show last sync, pending count, errors, devices, recovery and account deletion in settings. Offline browsing and local records remain usable.
- Passwords, cookies, login sessions, and active private tabs are not part of these three requested synced collections.

### Desktop companion work

Current desktop data is local JSON and timestamp-based chat IDs. Add a sync adapter, stable-ID migration, device registration and account/settings UI. Migrate sensitive collections to versioned encrypted persistence with a recoverable encrypted backup, verification before replacement, and no initial upload until the user enables sync. Preserve existing bookmarks, chat content, history and IDs through a deterministic mapping.

Exercise migrations in isolated BreezeTest profiles first. Keep working desktop Cloud contracts and desktop tool presentation intact. A compatible desktop release is a launch dependency, not a later optional enhancement.

## 6. Performance, reliability and security gates

Provisional Pixel targets: usable cold home within 1.5 seconds, warm resume within 400 ms, local action feedback within 100 ms, and live tab switching within 150 ms. Measure on the actual device and state conditions. These are targets, not verified claims. Track frame jank, memory, battery, cold/warm launches and provider p50/p95 separately.

Maintain an adaptive small live-session budget, initially around three; sleep inactive tabs while preserving navigation state and protecting unsaved forms/media. Never block first paint on cloud, sync, wallpaper decoding or filter compilation. Pause animation when offscreen. Use WorkManager for bounded sync retry with backoff, not continuous polling.

Before release, verify:

- Routing fixtures match desktop semantics; real Spectra navigation; no chat context leaks between new conversations.
- Browser navigation, forms, uploads, media, downloads, credentials and site permissions on actual Pixel.
- Process death, airplane mode, flaky connectivity, cancellations and stream reconnection without duplicate paid turns.
- Two-device Android/Swift sync: offline edits, conflicts, deletion, initial migration, recovery, revoked device and cross-account denial.
- Private mode leaves no persistent app history/thumbnail/sync records and sends no AI context without explicit user action.
- Encryption interoperability, tampered ciphertext rejection, nonce/key handling, server auth failure cases, quotas and injection boundaries.
- Dark/light/system visuals compared to references, large fonts, TalkBack, keyboard/insets, reduced motion.
- AAB native-library compatibility, Play pre-launch findings, signing and production backend configuration.

These are future build/release acceptance gates. No app tests were added or executed during this planning task. Ask for the verification pass when implementation reaches the relevant checkpoint.

## 7. Delivery sequence

1. **Contracts and feasibility:** engine/auth/crypto spikes, approved UI tokens, protocol/schema fixtures, stable-ID migration design, app ID and owned callback domain.
2. **Local browser:** real engine, exact home routing, themed chrome, tab wall, local library/private browsing and default-browser behavior.
3. **Cloud Nav:** staging auth, Responses search/streaming, tool chat, citations, source tabs, quotas, reconnect/cancel and error states.
4. **Full sync:** both clients, pairing/recovery, migration, encrypted offline operations and deletion. Complete before launch.
5. **Browser completion:** blocking/site controls, files/media, credentials, reminders, accessibility and measured performance.
6. **Release candidate:** requested verification pass, signed AAB, actual-device screenshots, privacy/Data safety, AI reporting and account deletion support.
7. **Distribution:** internal testing, required closed test, production access application and controlled rollout after release authorization.

The [build assignments](BUILD-TASKS.md) divide implementation into bounded Luna subagent tasks. Root remains responsible for architecture, design and integration. No reliable calendar estimate until the engine and sync interoperability spikes pass; Play’s mandatory testing period is a separate external dependency.

## 8. Current readiness and remaining decisions

Confirmed locally: Java 17 works through Homebrew, Android SDK 35 and ADB exist, Wrangler is authenticated, repo has no Android app yet. Need SDK 36/compatible build tools, reproducible wrapper, wireless Pixel pairing, and staging services during the build. `adb devices` and mDNS were empty during inspection.

Before first production setup, settle permanent application ID, Google account type/legal publisher, public support contact, OAuth domain and cloud spend ceiling. Proposed Android release tags use `android-v…` so desktop updater release selection stays independent. Extend the existing Breeze site at `https://breeze.froydingermedia.online/` for Play link, privacy and account deletion. Do not publish generated mockups as actual app screenshots.

No deployment, APK installation or app implementation was performed. Google Play subsequently confirmed developer-account creation by the user; identity verification remains in progress. See the setup guide for the observed state.

### Added after approval: password management

User requested password management. Include a separate encrypted local vault gated by strong biometrics or device credentials, origin-bound autofill/save prompts, and website passkeys via the platform credential provider. Local vault unlock is not itself a website passkey. Never expose credentials to AI context, browsing-history sync, logs, screenshots or unrequested clipboard copies. Credential sync is a separate product/security decision from the approved bookmark/history/chat sync.
