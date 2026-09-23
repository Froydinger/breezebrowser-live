# Local password vault foundation

`CredentialVault` is a manually managed, device-local credential store for HTTP/HTTPS website origins. It encrypts the vault JSON with AES-256-GCM under a separate Android Keystore key configured to require recent user authentication. Files live in `noBackupFilesDir`; only ciphertext is written. Each save writes a ciphertext temporary file, syncs it, then atomically renames it into place. An unreadable, unsupported, or unauthenticated vault raises an error and is not reset or overwritten.

- Android 11/API 30+: AndroidX `BiometricPrompt` with `BIOMETRIC_STRONG | DEVICE_CREDENTIAL`; after the prompt succeeds, Keystore authorizes cryptographic operations for 30 seconds. No `CryptoObject` is initialized before authentication.
- Android 10/API 29: `KeyguardManager.createConfirmDeviceCredentialIntent` confirms the secure screen lock; key use is limited by a 30-second Keystore auth window. A secure lock must be configured.
- Website URL input is validated as HTTP or HTTPS and reduced to scheme, host, and non-default port. Path, query, and fragment are discarded.
- Passwords are masked unless the user authenticates to reveal one; the screen requests `FLAG_SECURE` and clears its in-memory list/reveal state when the screen stops. There is no clipboard action, logging, external upload, backup, or sync.

This is a foundation, not a full browser password manager. It does not capture credentials from websites, offer browser save prompts or autofill, generate or store WebAuthn/passkeys, integrate Android Credential Manager, or migrate other password data. The app must not claim those features are implemented. The current UI stores entries only when a person enters them manually and confirms the local screen-lock authentication. Review threat model and device behavior before release, including Keystore invalidation, authentication fallback, process death and screen capture.

Credential entry strings necessarily exist in app memory while displayed/edited; the current design masks passwords and clears the decrypted list on screen stop, but JVM string contents cannot be reliably zeroed. Losing app data, uninstalling, losing the Keystore key, or key invalidation can make the vault unrecoverable. No recovery key exists. Do not use this store for server credentials, cookies, active browser sessions, or private-mode records.

## Website passkey release dependency

Gecko includes WebAuthn integration, but browser calls on behalf of arbitrary sites require credential-provider trust of the Android package/signing certificate. Register the final signing identity through the relevant provider process and prove registration/login on a real device; a local biometric vault does not establish this. Official guidance: https://developer.android.com/identity/sign-in/privileged-apps .
