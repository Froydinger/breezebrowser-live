# Android Nav SSE client

`com.froydinger.breeze.cloud.NavSseClient` posts a caller-built request to a
configured HTTPS Worker endpoint and streams validated SSE envelopes. It uses
`HttpURLConnection`, Kotlin coroutines, and Android's `org.json.JSONObject`.

```kotlin
val client = NavSseClient(endpoint = configuredWorkerUrl + "/v1/chat") { accessTokenProvider.getAccessToken() }
client.stream(requestJson) { envelope ->
    val event = NavStreamEvent.parse(envelope, expectedRunId = requestJson.getString("runId"))
    // Handle event.type and event.payload on the calling coroutine.
}
```

The endpoint and access-token provider are supplied by the integrating app. The
client does not persist tokens, issue Breeze account credentials, refresh tokens,
configure sign-in, or supply a production URL. It rejects non-HTTPS URLs, disables
redirect following, sends the token only in the Authorization header, and never logs
request bodies, event text, or credentials.

The stream parser supports CRLF/LF/CR lines, comments, and multiple `data:` lines per
event. It bounds lines to 64 Ki characters and events to 256 Ki characters, requires
schema version 1 and the request's `runId`, and rejects non-increasing event IDs.
`NavStreamEvent` provides typed event kinds plus a `JSONObject` payload. Unknown
event types remain representable as `UNKNOWN`, preserving their original wire type.
Connection and read timeouts are bounded; coroutine cancellation disconnects the
active connection. HTTP error bodies are not read or exposed, so failures contain only
the status code.

The Worker currently emits `accepted`, `status`, `tool_started`, `source`,
`text_delta`, `citation`, `completed`, and `failed`. A `cancelled` enum is reserved for
the broader protocol; the current Worker does not emit it. The Worker has no replayable
event history, refresh-token service, or durable cancellation/reconnect support, so a
lost stream must not be automatically retried with the same idempotency key.
