# Development-only mobile Responses route

`POST /v1/mobile/responses` is a development bridge that reuses the existing
Breeze chat Worker's `BREEZE_CLIENT_TOKEN`. It is protected by the same bearer
check as the desktop endpoints and **must not ship as the public mobile account
auth design**. The shared token is extractable from a development client build.
For public use, replace this gate with separately designed app/account
authentication and install attestation before distributing the app.

The new mobile route fails closed if `BREEZE_CLIENT_TOKEN` is missing. Existing
`/v1/chat/completions` and `/v1/realtime/token` routes retain their legacy
missing-token behavior and payloads; the legacy routes still allow requests
when that secret is absent and need a separately scoped hardening change.
Provider credentials continue to come from the existing Worker secret bindings;
do not add keys to TOML, source, or an APK.

## Request and stream

The request body is:

```json
{
  "chatId": "chat-id",
  "turnId": "turn-id",
  "runId": "run-id",
  "idempotencyKey": "retry-key",
  "task": "chat",
  "input": "Question text",
  "context": "Optional selected page text"
}
```

Tasks: `chat`, `research`, `summarize`, `factcheck`, `youtube`. IDs accept
letters, digits, `_`, and `-`, up to 128 characters. Input is capped at 12,000
characters, selected context at 20,000, and the request body at 5.5 MiB (to
allow a user-selected image attachment).
The Worker selects the server-configured `AI_CHAT_MODEL` (set to `gpt-6-luna` in
the existing Wrangler config), uses the configured OpenAI provider secret and
Responses API, sets `store: false`, caps output at 8,192 tokens and hosted tool
calls at twelve, and aborts after two minutes. The official GPT-6 Luna model page
lists Responses and web search support.

Task behavior is server selected:

- `chat`: substantive requests require web search and responses are instructed
  to include clickable links to the sources used. Concrete recommendations
  should link each pick; video requests should link actual videos where search
  results provide them. Plain greetings and brief social replies do not search,
  so “hey” stays a conversation.
- `research`: web search is required and the prompt asks for at least three
  distinct credible sources when available, comparison, synthesis, and actual
  citations.
- `factcheck`: web search is required; the prompt asks to compare at least two
  distinct reliable sources where available and separate supported,
  contradicted, and uncertain claims.
- `summarize`: web search is disabled. The model summarizes only the user's
  request and explicitly selected page/attachment context.
- `youtube`: the Worker attempts to fetch publicly available captions for the
  supplied YouTube URL, then uses web search for public metadata and context.
  The model can analyze retrieved captions or selected page text, but cannot
  see video frames or access private analytics. If captions are unavailable, it
  must state the scope limit and avoid claims about spoken content.

When web search is enabled, the request asks Responses to include
`web_search_call.action.sources`. The Worker emits actual collected URLs as
`source` events and inline `url_citation` annotations as `citation` events,
including URL, title, and citation character range where present. The Android
client should render citation links visibly and make them tappable. OpenAI
documents that citations should be clearly visible and clickable. The Android
client renders Worker sources as tappable cards and extracts Markdown links from
completed answers so recommendations stay easy to open. Search is required for
substantive chat, research, factcheck, and YouTube requests; simple social replies
and summarize use `tool_choice: "none"`.

Each SSE `data:` JSON event has `v: 1`, `runId`, request-local monotonic
`eventId`, and `type`: `accepted`, `status`, `tool_started`, `source`,
`text_delta`, `citation`, `completed`, or `failed`. Only an upstream
`response.completed` emits `completed`; upstream failures, incomplete results,
or premature EOF emit `failed`. Status events include a short message; web
search emits a `tool_started` event and a `Searching the web` status. Sources
and citation annotations come from actual upstream output, not inferred page
navigation. The only hosted tool currently wired is OpenAI `web_search`; there
are no native browser actions or video-frame analysis on this route.

The quota uses the existing Durable Object with a server-selected fixed
development identity, so callers cannot choose a quota identity via
`X-Breeze-Client-Id`. This is a single shared daily bucket for every client
using the shared token. `MOBILE_DAILY_LIMIT` can be configured; if absent the
fallback is 30 requests per UTC day. Every mobile request counts, including a
retry: `idempotencyKey` is carried in the protocol but is not cached or
deduplicated yet. There is no per-account quota, concurrency reservation,
refresh token, durable replay, or public install attestation in this development
route.

## Configuration and verification boundary

The existing deployed Worker must have `BREEZE_CLIENT_TOKEN` and provider-key
secrets configured. `AI_CHAT_MODEL` must select the intended server model. Keep
the development shared client token out of any public mobile release. No
deployment or live provider request is performed by adding this route; release
and rotation remain separate operational steps.

References: [GPT-6 Luna model support](https://developers.openai.com/api/docs/models/gpt-6-luna),
[Responses web search and citations](https://developers.openai.com/api/docs/guides/tools-web-search),
[Responses streaming events](https://developers.openai.com/api/docs/guides/streaming-responses).
