# Build assignments and checkpoints

## Scope update

User deferred accounts and Cloud sync: show **Coming soon**, no login for this version. S01–S04 and account-broker work are deferred; preserve existing scaffolds without activating them. Root must resolve accountless Breeze Cloud authorization for mobile before public release.

## Working arrangement

As requested, use **gpt-6-luna subagents for implementation**, with the primary model doing architecture, design, orchestration and final review. Maximum three concurrent subagents plus root. Give each a compact task packet and relevant files rather than the whole conversation. No recursive agent spawning, shared-file races or delegated production deployment.

Root owns design tokens, app/module wiring, Gradle/manifest changes, API/schema contracts, auth/crypto decisions, desktop migration integration and release decisions. Luna owns bounded modules after interfaces are settled. Each packet specifies allowed paths, requirements, dependencies, acceptance criteria, and required handoff notes. Agents report changed files and what remains unverified. Test work follows an explicit user request for the verification pass.

## Task queue

| ID | Owner | Work | Depends on | Completion evidence |
| --- | --- | --- | --- | --- |
| F01 | Root | Engine choice, stable toolchain, package ID, scaffold and architecture records | Build authorization | Reproducible local app build; engine gaps recorded |
| F02 | Root | Auth + sync envelope + event/tool schemas, fixtures and crypto interoperability design | F01 | Frozen versioned contracts and migration mapping |
| F03 | Root | Tokens, real logos, reference screen mapping, remaining settings/recovery designs | F01 | Reviewable layouts for dark/light and failure states |
| B01 | Luna A | Home/shortcuts/wallpapers, Ask/Search and routing UI | F02,F03 | Exact product routing and reference match |
| B02 | Luna B | Gecko session adapter, tab lifecycle, navigation/site permissions | F01,F02 | Real sites, stable session identifiers, isolated private mode |
| B03 | Luna C | Local encrypted repositories, bookmarks/history/chat projections | F02 | Transactional operations, migration-ready IDs |
| N01 | Luna A | Chat UI, streaming reducer, sources, task progress/glow | B01,F02 | Partial/final/error/cancel states; no invented progress |
| N02 | Luna B | Mobile Worker Responses adapter, typed tools and budgets | F02 | Staging protocol integration; no secrets in client |
| N03 | Root | Account broker, device credentials, backend deployment configuration | F02 | Auth trust boundaries and staging integration review |
| S01 | Luna A | Android sync outbox/inbox under approved crypto interface | B03,N03 | Offline queue and revision handling |
| S02 | Luna B | Sync Worker encrypted operation log and attachment endpoints | F02,N03 | Account isolation, cursors and tombstones |
| S03 | Luna C | Desktop sync adapter in new dedicated files | F02,N03 | Compatible encrypted wire records |
| S04 | Root | Desktop Store migration/wiring, enrollment/recovery/key lifecycle | S01,S02,S03 | Preserved desktop data and complete pairing flow |
| C01 | Luna A | Tab wall, library/settings and accessibility completion | B01,B02,B03 | Complete required states and controls |
| C02 | Luna B | Downloads/files/media/blocking and site exceptions | B02 | Actual engine hooks and recovery UI |
| C03 | Luna C | Account/device/recovery/deletion UI and supported reminders | S04 | User-visible controls backed by real operations |
| R01 | Root + scoped Luna tasks | Requested verification, defect resolution, performance | All above | Actual Pixel and BreezeTest evidence, measured results |
| R02 | Root | AAB/signing, listing/privacy, release and rollout preparation | R01 | Concrete reviewable release package |

The table is a dependency graph, not permission to run all rows simultaneously. Root reassigns lanes as tasks finish. Shared routing, schema or wiring changes return to root. Use small commits/checkpoints when authorized; preserve pre-existing user work.

## Verification plan for the requested build QA pass

- Unit/contract coverage: routing, streaming reducer, quota/idempotency, sync conflicts/tombstones, crypto vectors, migration fixtures.
- Integration coverage: signed-in staging chat/search, reconnect/background task, source tabs, two-client sync, recovery/revocation/deletion.
- Device coverage: wireless Pixel, process death, offline transitions, credentials/media/forms/downloads, private storage, large text and TalkBack.
- Visual comparison: all 13 screen pairs, real asset use, neutral dark surfaces, Nav location, URL controls and keyboard/insets.
- Security review: account isolation, missing-auth failure, native bridge/URL validation, prompt injection boundaries, SSRF, log redaction and key handling.

Do not equate compiling, installing, or a mocked test with successful real use. Record each evidence tier and remaining gaps. Root requests no production release until the concrete signed candidate and deployment diff are ready.

## Release separation

Use staging Cloudflare resources until release authorization. Preserve desktop `breeze-chat` compatibility. Desktop changes use isolated BreezeTest bundle/profile. Keep Android signing credentials outside the repository. Android tags and distribution files must not confuse the existing desktop updater.
