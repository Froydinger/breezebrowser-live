# Breeze Sync Worker foundation

This standalone Worker is a ciphertext-only ordered operation transport. It
does not modify the mobile or desktop chat Workers. It derives account identity
from a verified JWT subject, hashes that subject into a per-account Durable
Object name, and never accepts a caller-selected account ID.

## API

- `GET /health`: public minimal health response.
- `POST /v1/devices`: authenticated registration of `{ "deviceId", "name"? }`.
- `GET /v1/devices`: authenticated device listing.
- `DELETE /v1/devices/{deviceId}`: authenticated revocation.
- `POST /v1/sync/push`: authenticated push of `{ "operations": [envelope, ...] }`.
- `GET /v1/sync/pull?deviceId=...&cursor=...&limit=...`: authenticated ordered
  pull. The device must be registered and not revoked.

Each envelope has exactly these used fields: `recordId`, `collection`
(`bookmarks`, `history`, or `chats`), `operationId`, `deviceId`, `keyEpoch`,
base64url `nonce`, opaque base64url `ciphertext`, `deleted`, and
`expectedRevision`. The Worker cannot inspect record content. Tombstones retain
the same encrypted envelope format. Per-record revisions start at zero and
increment on each accepted operation; conflict responses include the current
ciphertext envelope (or null for a not-yet-created record) for client-side
resolution.

Pushes are atomic per batch and capped at 100 operations, 64 KiB per encoded
operation, and 512 KiB combined encoded operation data. A Durable Object
transaction serializes cursor assignment, idempotency-index writes, record heads,
and log entries. A batch may contain at most one operation per record to keep
revision conflicts anchored to the committed record head. Immutable operation IDs are indexed with a SHA-256 hash of the
canonical envelope: identical retries return their original cursors, while
reusing an ID with different ciphertext or metadata returns 409. Revisions use
optimistic `expectedRevision`; mismatches return 409 and current ciphertext.
Pull pages contain at most 100 entries.

## Security and missing pieces

JWT validation follows the mobile Worker: HTTPS-configured JWKS, configured
issuer and audience, required `sub`, `exp`, `iat`, max token age 24 hours, and
only `RS256`, `PS256`, or `ES256`. Invalid or absent auth configuration fails
closed. Account subjects are SHA-256 hashed before becoming Durable Object
names. The user’s JWT account identity is not itself a trusted-device pairing
proof. Registration currently records a device ID and display name only; there
is no cryptographic device attestation, owner-approved pairing, device-bound
proof-of-possession, HPKE key transfer, or recovery-key flow. Clients must not
send a vault key to this Worker, and the server cannot claim that devices are
trusted or that complete end-to-end encrypted sync is ready.

There is no log compaction, cursor floor/resnapshot protocol, account-wide data
deletion endpoint, signed operation authorship, or retention policy yet. The
per-account log grows without bound until those policies are implemented. Device
revocation blocks new pulls and pushes after the revocation is observed; it
cannot retract data already downloaded by that device.

## Local config

Copy `wrangler.example.toml` to a local ignored `wrangler.toml`; configure an
isolated staging identity provider’s issuer, audience, and JWKS URL, then run
`npm install`, `npm run typecheck`, or `npm run dev`. Never store credentials or
encryption keys in TOML, source, logs, or Worker bindings. `wrangler dev` uses
the safe example configuration. No secrets or live service credentials are
included.
