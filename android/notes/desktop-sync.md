# Desktop sync wire and crypto contract

`android/deferred/desktop/SyncWire.swift` is a deferred, standalone scaffold for the
Android/desktop encrypted records contract. The initial release has no accounts or
sign-in, and sync remains “Coming soon.” This file is not wired into desktop runtime,
does not alter existing persistence, and does not automatically upload existing data.

## Envelope

The JSON envelope fields match `cloudflare/breeze-sync`: `recordId`, `collection`,
`operationId`, `deviceId`, `keyEpoch`, `nonce`, `ciphertext`, `deleted`, and
`expectedRevision`. UUIDs serialize as canonical lowercase strings. Collections are
exactly `bookmarks`, `history`, or `chats`. `nonce` and `ciphertext` use unpadded
base64url; ciphertext is AES-GCM encrypted bytes followed by the 16-byte tag.
The nonce must decode to exactly 12 bytes. `expectedRevision` is the record revision
the operation expects; server-assigned cursor/revision values in pull results stay
separate from this envelope field.

The current Worker accepts at most 64 KiB per envelope and 512 KiB per push batch.
The client caps plaintext at 46,000 bytes, ciphertext at 64,000 base64url characters,
and the conservative envelope estimate at 64 KiB. Batches contain at most 100 records.
Tombstones still carry an authenticated-encryption box, including when the plaintext
is empty. `keyEpoch` starts at 1; zero is invalid.

## Crypto interoperability

Use AES-256-GCM with a caller-supplied 32-byte vault key, a fresh random 12-byte nonce,
and no custom cipher or key derivation. The client obtains key and nonce randomness
from `SecRandomCopyBytes`. `SyncCrypto.seal` and `open` never persist the vault key.

Associated data is compact UTF-8 JSON with this exact array order and no whitespace:

```json
[1,"<recordId>","<collection>","<operationId>","<deviceId>",<keyEpoch>,<deleted>,<expectedRevision>]
```

All UUIDs are canonical lowercase strings. Integers are ordinary base-10 JSON
integers; `deleted` is a JSON boolean. For example, both clients must authenticate
exactly the UTF-8 bytes of `[1,"550e8400-e29b-41d4-a716-446655440000","bookmarks","550e8400-e29b-41d4-a716-446655440001","550e8400-e29b-41d4-a716-446655440002",1,false,0]` for the corresponding metadata. Changing any field or byte makes GCM authentication fail.

## HTTP adapter

`SyncHTTPClient` takes an HTTPS service base URL and receives an access token at each
`push` or `pull` call. It sends the token only as a Bearer header, uses ephemeral
URLSession configuration without cookies or cached responses, refuses redirects,
and bounds request and response sizes. Error response bodies are not surfaced or
logged. The routes match the current Worker:

- `POST /v1/sync/push` with `{ "operations": [...] }`
- `GET /v1/sync/pull?cursor=<number>&limit=<1..100>`

When sync is approved for a later release, its caller will own authentication,
enrollment, keychain storage, sync consent, local
outbox transactions, conflict resolution, and cursor persistence. A revision conflict
must be handled by the sync layer; this primitive does not overwrite local records or
silently retry a mutation. No live requests or tests were run for this implementation.
