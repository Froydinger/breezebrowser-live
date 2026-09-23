# Breeze Mobile Worker foundation

This separate Worker is an early authenticated Nav API foundation. It does not
modify `breeze-chat-worker`, issue Breeze account tokens, implement account
sign-in, sync, durable background runs, or provide replayable stream history.
No deployment or live provider request is part of this change.

## Contract

- `GET /health` returns a minimal health response.
- `POST /v1/chat` requires `Authorization: Bearer <JWT>`. The token must have a
  valid signature from `JWT_JWKS_URL` and matching `JWT_ISSUER` and
  `JWT_AUDIENCE`, plus a stable `sub` claim. Missing auth configuration fails
  closed.
- Request JSON: `{ "chatId", "turnId", "runId", "idempotencyKey",
  "task": "chat" | "research" | "summarize" | "factcheck" | "youtube",
  "input", "context"? }`. IDs use letters,
  digits, `_` and `-`. Input is capped at 12,000 characters and selected context
  at 20,000 characters.
- Response is Server-Sent Events. Each `data:` JSON envelope has `v: 1`,
  `runId`, request-local monotonic `eventId`, `type`, and event fields. Types:
  `accepted`, `status`, `tool_started`, `source`, `text_delta`, `citation`,
  `completed`, `failed`.

The Worker selects `gpt-6-luna` and uses OpenAI Responses with `store: false`.
`web_search` is available for chat, research, factcheck, and YouTube public
metadata requests; the model chooses whether to use it. Summarize has no search
tool and is instructed to use only supplied material. YouTube transcript/video
retrieval is not implemented: without supplied transcript or metadata, Nav must
say so and ask for the material. Output is capped at 8,192 tokens, provider tool
calls at eight, input at 12,000 characters plus 20,000 context characters, and a
request at two minutes. These character limits bound approximate input tokens;
they are not a measured token quota. A per-subject Durable Object reserves daily
allowance and concurrent capacity before contacting the provider. Research has
its own daily bucket; chat, summarize, factcheck, and YouTube metadata share the
chat daily bucket. Counters reset by UTC date. Active reservations expire after
150 seconds if the Worker crashes before release. Provider/API errors are
returned generically.

JWT verification requires an HTTPS JWKS URL from configuration, configured
issuer and audience, a stable `sub`, `exp` and `iat`, a maximum token age of 24
hours, and one of `RS256`, `PS256`, or `ES256`. No token-provided URL or subject
can select the JWKS host. Account subjects are SHA-256 hashed before using them
as Durable Object names.

The reservation ledger rejects a repeated idempotency key or active run ID with
HTTP 409; it does not yet cache completed results or compare duplicate request
payloads. Losing the stream therefore requires the client to reconcile or
explicitly start a new run. There is no durable event log,
reconnect cursor, cancellation persistence, refresh-token service, account
provisioning, Play Integrity check, global emergency spend ceiling, or usage
settlement. Daily limits and concurrency are initial local caps, not a complete
production billing/quota system. These gaps are intentional and must not be
represented as complete auth, sync, or durable run support.

## Local configuration

Copy `wrangler.example.toml` to an ignored local `wrangler.toml`, replace the
example issuer, audience, and JWKS URL with a staging identity provider, and add
the provider key locally with `wrangler secret put OPENAI_API_KEY`. Never put a
secret in TOML, source, an APK, or command output. Use separate staging
resources and credentials; do not point this example at production.

`npm install`, `npm run typecheck`, and `npm run dev` are available. `dev` uses
the safe example config; until valid auth/provider configuration is supplied,
chat requests fail closed. No secrets or keys are included in this repository.
