# Breeze for Windows: build and release

The Windows port is isolated in `windows/`. Its initial release is **1.0.0**,
tagged **`windows-v1.0.0`** in `Froydinger/breezebrowser-live`. Do not change the
native macOS version, Android assets, or native `vX.Y.Z` tags. Never mark a
Windows release as GitHub Latest.

## Current development build: Cloud setup deferred

The `windows-chromium-port` branch builds **Breeze Test**, an explicitly
unconfigured, isolated browser test installer. It does not need Cloud credentials
and does not publish a GitHub release or update the download website. Aero and
Breeze Cloud are disabled in this build; complete the rest of the browser first.

```powershell
cd windows
npm ci
npm test
npm run check
npm run build:test:win
```

The test configuration is generated with `scripts/build-config.cjs --development`.
It contains only `development: true`, empty AI/Supabase URLs and credential fields,
and the isolated `com.froydinger.breeze.test://auth-callback` URI. Development mode
does not read Cloud environment variables or credential files. Combining it with
`--verify-network` is rejected, and production validation rejects the development
marker. A test build cannot satisfy the configured production release gate.

The test package uses product name `Breeze Test`, app ID
`com.froydinger.breeze.windows.test`, no registered protocol, and installer
`windows/dist/Breeze-Test-1.0.0-windows-x64.exe`. Its unpacked executable is
`windows/dist/win-unpacked/Breeze Test.exe`. CI smoke-tests that executable and
uploads `breeze-test-windows-x64-<commit>` with the EXE and SHA-256, clearly marked
unconfigured and unsigned. Test installers must never be renamed or advertised
as the production Breeze release.

## Required existing production configuration

A production release must have working Aero and Breeze Cloud configuration.
Unconfigured production builds are deliberately rejected. Do not generate replacement credentials or
put credentials in source, commit messages, command arguments, logs, screenshots,
or release notes.

| Build input | Source |
| --- | --- |
| `BREEZE_CLOUD_CLIENT_TOKEN` | Existing Breeze Cloud client token in the environment, or `cloudflare/breeze-chat-worker/.breeze-client-token` |
| `BREEZE_CLOUD_SUPABASE_ANON_KEY` | Existing Supabase **public** anon/publishable key in the environment, `native/.supabase-anon-key`, or root `.supabase-anon-key` |
| `BREEZE_CLOUD_AI_BASE_URL` | Existing service, defaults to `https://breeze-chat.jakefroydinger.workers.dev` |
| `BREEZE_CLOUD_SUPABASE_URL` | Existing native project, defaults to `https://sbvjjseitpahdpewsqqc.supabase.co` |
| `BREEZE_CLOUD_REDIRECT_URI` | Existing callback, `com.froydinger.breeze://auth-callback` |

The build script accepts only the existing service origins and callback. It
rejects secret/service-role Supabase keys, wrong-project legacy JWTs, expired
legacy keys, missing configuration, and obvious placeholders. Supabase access
continues to rely on the existing server-side RLS policies. Never bundle a
provider API key or Supabase service-role credential.

`scripts/build-config.cjs` writes ignored `config.generated.json` containing
`aiBaseURL`, `aiClientToken`, `supabaseURL`, `supabaseAnonKey`, and `redirectURI`.
This file is included in the packaged main process, never exposed through the
renderer bridge. Desktop application files can be extracted by their owner;
bundling a client credential does not make it a confidential server secret.
The existing backend must enforce its usual limits and authorization.

Only the production workflow step reads the repository secret `BREEZE_CLOUD_CLIENT_TOKEN`, and the
repository variable or secret `BREEZE_CLOUD_SUPABASE_ANON_KEY`. These are the
names expected by the build, not evidence that they have already been set.
The GitHub connector cannot list Actions secrets; historical workflows do not
establish their presence. A real configured build/health check is required.
The generated file is removed after the build and is never uploaded separately.

## Local production build on Windows (deferred)

Use Node.js 22 and the committed npm lockfile. Supply existing configuration
through the approved environment or files without printing their values.

```powershell
cd windows
npm ci
npm test
npm run check
node scripts/build-config.cjs --check --verify-network
npm run build:win
```

The connectivity check makes a read-only, authenticated request to the existing
Aero `/health` route and Supabase `/auth/v1/settings`. It rejects redirects and
logs only success or a sanitized failure. It does not create an account, change
server configuration, call a model, or spend an AI request quota.

The NSIS x64 installer is `windows/dist/Breeze-1.0.0-windows-x64.exe`. The workflow
creates a sibling `Breeze-1.0.0-windows-x64.exe.sha256`. `build:win` has automatic
electron-builder publication disabled.

## Unsigned Windows distribution

No Windows code-signing certificate is configured. The installer is **unsigned**;
Windows SmartScreen or Smart App Control may warn or block it. This is distinct
from the signed/notarized native Mac app. Do not claim the Windows build is
signed, notarized, universally installable, or bypass Windows protection on a
user's behalf. Keep the unsigned notice on the release and download page.

## Build-only CI, then deliberate release promotion

1. Push the tested port to `windows-chromium-port`. The Windows workflow runs
   `npm ci`, tests, syntax checks, and `npm run build:test:win` on
   `windows-latest`, then launches `Breeze Test.exe` with `--smoke-test`.
   That check uses an isolated temporary profile and local HTTP fixtures to test
   navigation and untrusted-page bridge isolation, without account or AI calls.
   It creates a clearly named test installer/checksum artifact without reading
   Cloud secrets, checking Cloud connectivity, or publishing a release.
2. Review the exact commit's successful CI run and download its artifact. Verify
   the SHA-256 and successful packaged-app smoke result. Passing unit tests alone
   does not prove that an installer starts or that real websites work. Record
   outstanding full Windows installation/live-service acceptance checks below.
3. Cloud setup and production publication are deferred. Only after existing
   Cloud configuration is supplied, those checks pass, and release authorization
   is current, create or fast-forward the
   dedicated `windows-release` branch to that reviewed commit. This is the
   publication gate. Its workflow requires real Cloud configuration and live
   service verification, then rebuilds/tests a production package, verifies the
   installer/checksum, creates a draft tagged `windows-v1.0.0`, checks both assets,
   and publishes with `--latest=false` using the existing job `GITHUB_TOKEN`.
   Existing tags pointing elsewhere and existing releases are never overwritten.
4. A pushed matching `windows-v1.0.0` tag is an alternate publication trigger.
   Manual `workflow_dispatch` may build; its `publish` input only works on
   `windows-release`. The GitHub Actions manual UI/dispatch API requires the
   workflow to exist on the repository's default branch, so branch push is the
   initial path and does not require modifying the Mac default branch.
5. Inspect the published release and download both public assets. Check the EXE's
   downloaded checksum matches. Confirm the native Latest release remains the
   native `v6.x` release and existing Mac/Android assets are unchanged. Complete
   Windows installation and live-service acceptance checks using those exact
   downloaded bytes before calling the release fully verified.
6. Update **only the canonical lander** in `Froydinger/breezebrowser`, `main`,
   `index.html`, with an additive Windows download section and unsigned notice.
   Preserve Mac 6.3.7 and Android links and Mac schema/version. Do not create a
   second website in this source repository. Verify deployment and the final
   public link before saying the Windows release is live.

Exact Windows download:

`https://github.com/Froydinger/breezebrowser-live/releases/download/windows-v1.0.0/Breeze-1.0.0-windows-x64.exe`

Checksum:

`https://github.com/Froydinger/breezebrowser-live/releases/download/windows-v1.0.0/Breeze-1.0.0-windows-x64.exe.sha256`

Use versioned links, never `releases/latest/download`. If publication stops after
creating a draft, inspect that draft and its exact source/assets before resuming;
do not delete/recreate or clobber a published release to make a retry pass.

## Windows acceptance checks

- Install, start, quit, and restart on supported Windows 10/11 x64; verify the
  NSIS shortcut, app icon, remembered settings, and uninstall preservation.
- Open a normal HTTPS page, follow a link, use back/forward/reload, close/reopen
  tabs, and confirm page isolation, permissions, navigation, and download safety.
- Check top/sidebar address-bar layouts, light/dark/system themes, onboarding,
  history/bookmarks, and browser data persistence.
- Confirm Aero can answer with page context and execute the supported browsing
  actions; test cancel/repeated submission and error recovery. These production
  checks remain deferred; an unconfigured test build must instead clearly report
  that Aero and Cloud are unavailable.
- Sign in through existing Breeze Cloud using an authorized test account, sync
  selected categories, sign out, and verify no password vault data is synced.
- Verify the app handles the existing auth callback, rejects unrelated callbacks,
  and does not expose Cloud tokens to an untrusted page or renderer response.
- Record failures and any untested functionality accurately. Do not advertise
  successful end-to-end validation based only on fixtures or static checks.

## Connector publication without shell authentication

The available GitHub connector supports object-based branch updates:

1. Read the base commit and tree using `fetch` Git data endpoints.
2. Create changed blobs (`create_blob`) and a tree with the existing base tree
   (`create_tree`), preserving every unrelated file.
3. Create a commit with the observed branch tip as parent (`create_commit`).
4. Create the isolated branch if absent (`create_branch`) or fast-forward it with
   `update_ref(force=false)`. Read it back and compare its SHA.
5. Read `/actions/runs?branch=windows-chromium-port` and the matching commit's jobs.
   Use the supported artifact download action to inspect the produced installer.
6. After the release gate, create/advance `windows-release` to the tested commit.

There is no exposed connector action for creating a tag, dispatching a workflow,
writing a release, or listing/creating Actions secrets. Do not misuse the
branch-name parameter as an undocumented tag API. The release job handles tag
and release creation with its existing, job-scoped `contents:write` token.

References: [GitHub push triggers](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#push),
[GitHub CLI release creation](https://cli.github.com/manual/gh_release_create),
[GitHub CLI draft publication](https://cli.github.com/manual/gh_release_edit),
[Supabase public and secret keys](https://supabase.com/docs/guides/getting-started/api-keys).
