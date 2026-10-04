# Breeze for Windows: browser-first release

The Windows port is isolated in `windows/`. Version **1.0.0** ships as ordinary
**Breeze** with **Aero AI and Breeze Cloud account/sync marked Coming soon**.
This is the intentionally authorized browser-first Windows release. It does not
require, read, transfer, or embed Cloud credentials. Mac and Android releases,
features, assets, and native `vX.Y.Z` tags remain unchanged.

## Build the current Windows release

Use Node.js 22 and the committed npm lockfile:

```powershell
cd windows
npm ci
npm test
npm run check
npm run build:win:no-cloud
```

The package retains product name `Breeze` and app ID
`com.froydinger.breeze.windows`, without an account callback protocol. The x64
NSIS installer is `dist/Breeze-1.0.0-windows-x64.exe`; the unpacked executable is
`dist/win-unpacked/Breeze.exe`. Automatic electron-builder publication is disabled.

`build-config.cjs --without-cloud` emits only `development: false`,
`cloudDisabled: true`, `cloudMode: 'coming-soon'`, empty AI/Supabase URLs and
credential fields, and an empty callback URI. It bypasses environment and file
credential discovery entirely. It cannot be combined with `--development` or
`--verify-network`. The app must visibly mark Aero AI and account/sync Coming soon
and prevent those unavailable actions. Do not imply those features were tested.

The separate `--development` / `build:test:win` option remains available for
isolated Breeze Test builds. Its test identity must never be renamed or promoted
as the production Breeze installer.

## Build once; promote the exact tested bytes

1. Push to **`windows-chromium-port`**. Only this branch builds. The workflow runs
   npm CI, unit tests, syntax checks, and `build:win:no-cloud` on `windows-latest`.
   It verifies the empty no-cloud configuration, launches the packaged
   `Breeze.exe --smoke-test`, and requires exit zero plus a JSON `ok: true`, correct
   version, and Windows DPAPI round-trip evidence. Smoke tests use an isolated
   temporary profile and local HTTP fixtures without account or AI requests.
2. CI uploads immutable artifact **`breeze-windows-x64-<commit SHA>`**, containing
   the EXE, its `.exe.sha256`, and a release manifest with commit, run ID, filename,
   checksum, and `coming-soon` mode. A separate smoke artifact retains the result
   JSON and screenshot. The build branch never publishes a GitHub release.
3. Review the exact successful run's installer, checksum, screenshot, and browser
   acceptance checks below. Record its run ID and checksum. Do not rerun/replace
   the reviewed artifact and assume newly produced bytes are identical.
4. After manual QA and release authorization, create or fast-forward
   **`windows-release`** to that exact reviewed commit. A matching
   **`windows-v1.0.0`** tag is an alternate promotion trigger. No other branch/tag
   is eligible. Do not change native or Android refs.
5. The promotion job **does not rebuild** and has no dependency on the skipped
   build job. With the existing GitHub job token (`actions:read`, `contents:write`),
   it finds the latest successful port-branch Windows workflow run for the exact
   commit, requires one unexpired matching artifact, and downloads it through
   `gh run download`. It verifies the checksum and manifest's source/run/mode.
   No source checkout, npm install, compilation, or repackaging occurs here.
6. Promotion creates a draft **`windows-v1.0.0`** release, checks both attached
   EXE/checksum assets, then publishes with **`--latest=false`**. Existing releases
   and tags pointing elsewhere are never overwritten. The native Latest release
   is checked afterward. If a draft/upload is incomplete, inspect it before any
   recovery; never silently clobber a published asset.
7. Download the public EXE/checksum and compare with the manually reviewed hash.
   Update only the canonical lander (`Froydinger/breezebrowser`, `main`,
   `index.html`) with the additive Windows link, Windows-only Coming soon labels,
   and unsigned warning. Preserve Mac 6.3.7 links/schema and Android links.
   Verify deployment and the actual download before claiming the release is live.

Current versioned URLs:

- [Windows installer](https://github.com/Froydinger/breezebrowser-live/releases/download/windows-v1.0.0/Breeze-1.0.0-windows-x64.exe)
- [SHA-256 checksum](https://github.com/Froydinger/breezebrowser-live/releases/download/windows-v1.0.0/Breeze-1.0.0-windows-x64.exe.sha256)

Never use `releases/latest/download` for Windows or mark Windows as Latest.
Artifact retention is 14 days; if the reviewed artifact expires, build and review
new bytes before promotion. Reusing the source SHA does not establish byte identity.

## Unsigned installer

No Windows code-signing certificate is configured. The installer is **unsigned**;
Windows SmartScreen or Smart App Control may warn or block it. Do not describe it
as signed/notarized or bypass Windows protections on the user's behalf. Keep this
warning on the Windows release and download page. Native Mac signing is unchanged.

## Windows browser acceptance checks

- Install, start, quit, and restart on Windows 10/11 x64; check shortcuts, app icon,
  settings persistence, and uninstall preservation.
- Visit real HTTPS pages; test navigation, back/forward/reload, tabs, downloads,
  permission prompts, popup controls, and untrusted-page bridge isolation.
- Test top/sidebar address-bar layouts, light/dark/system themes, onboarding,
  history/bookmarks, local password-vault handling, and browser data persistence.
- Confirm Aero AI and Breeze Cloud sign-in/sync are visibly Coming soon and cannot
  attempt unavailable network services. No account is required for browsing.
- Compare the downloaded installer with the exact CI/manual-QA checksum. Record
  genuine failures and untested behavior; fixtures alone are not live-site QA.

## Future configured Cloud builds: explicit opt-in only

The strict `npm run build:win` path remains available separately. It requires
existing `BREEZE_CLOUD_CLIENT_TOKEN` and `BREEZE_CLOUD_SUPABASE_ANON_KEY` values;
without them it fails. Its default service origins remain the existing
`https://breeze-chat.jakefroydinger.workers.dev` and
`https://sbvjjseitpahdpewsqqc.supabase.co`, with the original auth callback.
The current GitHub workflow has **no Cloud secret or variable bindings**.

Configured mode rejects secret/service-role keys, wrong-project/expired legacy
public keys, placeholders, and incorrect service origins. Optional
`--check --verify-network` verifies existing read-only service routes with
redirects disabled and sanitized errors. It rejects development and without-cloud
configurations. Do not generate new credentials or transmit existing credentials
as part of the current browser-first release. Enabling Cloud later requires its
own configuration, live-service QA, and appropriately labeled release.

## Connector publication without shell authentication

Use the available GitHub connector to create blobs/tree/commit and create or
fast-forward the isolated branch, retaining unrelated files. Verify the ref SHA
and corresponding CI run. Creating/advancing `windows-release` is the promotion
gate; ordinary work belongs on `windows-chromium-port`. The connector does not
expose tag creation, workflow dispatch, release mutation, or Actions-secret APIs.
The promotion job uses only its existing job token; no persistent credential is
created. Do not misuse branch-name parameters as undocumented tag operations.

The official v4 action refs were verified through GitHub Git data on 2026-10-04:
checkout `11d5960a326750d5838078e36cf38b85af677262`, setup-node
`49933ea5288caeca8642d1e84afbd3f7d6820020`, and upload-artifact
`ea165f8d65b6e75b540449e92b4886f43607fa02`.

References: [GitHub push triggers](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#push),
[release creation](https://cli.github.com/manual/gh_release_create),
[draft publication](https://cli.github.com/manual/gh_release_edit),
[run artifact downloads](https://cli.github.com/manual/gh_run_download).
