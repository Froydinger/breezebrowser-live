# Android local encrypted storage foundation

`com.froydinger.breeze.data.EncryptedStateStore` is an interim persistence adapter for small JSON state while the Android app is being established. It uses only Android platform APIs and `org.json`:

- AES-256-GCM with a random 96-bit nonce per encryption, a 128-bit authentication tag, and an app-specific Android Keystore key.
- Ciphertext envelope stored in `Context.noBackupFilesDir`; Android's normal backup/restore path does not include this directory. No plaintext state, key, or backup is written by this adapter.
- Same-directory temporary write followed by rename, after `fsync`, to replace the ciphertext atomically. The old file remains if encryption or replacement fails.
- Missing state loads as `{}`. Malformed envelopes, unsupported versions, invalid keys, and authentication failures throw `StateStoreException`; load never silently resets or overwrites a damaged file. The caller should preserve the file and surface/recover deliberately.

Example:

```kotlin
val stateStore = EncryptedStateStore(applicationContext)
val state = stateStore.load() // throws StateStoreException on unreadable/corrupt data
state.put("example", "value")
stateStore.save(state)
```

`EncryptedOutboxStore` is only an encrypted local queue foundation for future sync. It accepts stable record IDs in the `bookmarks`, `history`, or `chats` collections, gives each operation an operation ID and increasing local cursor, and exposes the pending records/cursor. It performs no network requests, server acknowledgement, upload, download, merge, retry, or claim of successful sync. There is not yet a transactional relationship with domain-record mutations; until Room is adopted, callers must treat enqueue and their own record changes as separate writes.

Private-session data must never be passed to the outbox. Explicit `privateSession: true` and `isPrivate: true` operation markers are rejected, but this small abstraction cannot infer privacy from arbitrary payloads; the caller must keep private data out entirely. The outbox intentionally has no deletion/ack API until sync semantics are designed.

## Limits and migration

This is not Room/SQLCipher and is not suitable as a large database. It rewrites one complete JSON document per save, has no cross-process or cross-instance locking, and synchronizes only calls made through the same object instance. Android Keystore key invalidation, app-data clearing, uninstall, or device/OS failure can make ciphertext unrecoverable; no recovery key or key backup exists. Keystore protects the encryption key, while app sandboxing and `noBackupFilesDir` provide the file boundary. This does not encrypt Gecko engine profiles/cookies or data held elsewhere in app storage, and it does not establish end-to-end sync encryption, account authentication, device pairing, or server security.

Replace or migrate this foundation when adopting encrypted Room/SQLCipher. Preserve a versioned migration path, verify decrypted records before removing the legacy ciphertext, and explicitly exclude private sessions. No migration or account sync is implemented here.
