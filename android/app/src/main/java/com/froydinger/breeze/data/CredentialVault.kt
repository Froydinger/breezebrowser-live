package com.froydinger.breeze.data

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.system.ErrnoException
import android.system.Os
import android.util.Base64
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.util.UUID
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** One locally stored website credential. Password is never formatted into logs/UI by this class. */
data class VaultCredential(
    val id: String,
    val origin: String,
    val username: String,
    val password: String,
)

/** Encrypted, no-backup local credential storage. Authentication is managed by the caller. */
class CredentialVault(context: Context) {
    private val file = File(context.applicationContext.noBackupFilesDir, FILE_NAME)

    /** Reads after system authentication; the Android Keystore auth window enforces recent unlock. */
    @Synchronized
    @Throws(CredentialVaultException::class)
    fun readAfterAuthentication(): List<VaultCredential> {
        if (!file.exists()) return emptyList()
        try {
            val envelope = readEnvelope()
            val nonce = Base64.decode(envelope.getString("nonce"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
            if (nonce.size != NONCE_BYTES) throw CredentialVaultException("Vault nonce is invalid")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(TAG_BITS, nonce))
            cipher.updateAAD(AAD)
            return decode(cipher.doFinal(ciphertext))
        } catch (e: CredentialVaultException) {
            throw e
        } catch (e: AEADBadTagException) {
            throw CredentialVaultException("Vault authentication failed; original file was preserved", e)
        } catch (e: GeneralSecurityException) {
            throw CredentialVaultException("Vault could not be decrypted; original file was preserved", e)
        } catch (e: IOException) {
            throw CredentialVaultException("Vault could not be read", e)
        } catch (e: JSONException) {
            throw CredentialVaultException("Vault is malformed; original file was preserved", e)
        } catch (e: IllegalArgumentException) {
            throw CredentialVaultException("Vault encoding is invalid; original file was preserved", e)
        }
    }

    /** Encrypts all entries and atomically replaces the ciphertext file. Call only after auth. */
    @Synchronized
    @Throws(CredentialVaultException::class)
    fun writeAfterAuthentication(entries: List<VaultCredential>) {
        var temp: File? = null
        try {
            if (entries.size > MAX_ENTRIES) throw CredentialVaultException("Vault entry limit reached")
            val payload = JSONObject().put("schema", SCHEMA_VERSION).put(
                "credentials",
                JSONArray().apply {
                    entries.forEach { entry ->
                        if (entry.origin.length > MAX_ORIGIN_CHARS || entry.username.length > MAX_USERNAME_CHARS || entry.password.length > MAX_PASSWORD_CHARS) {
                            throw CredentialVaultException("A credential field exceeds the supported size")
                        }
                        put(JSONObject()
                            .put("id", entry.id)
                            .put("origin", normalizeOrigin(entry.origin))
                            .put("username", entry.username)
                            .put("password", entry.password))
                    }
                },
            ).toString().toByteArray(StandardCharsets.UTF_8)
            if (payload.size > MAX_FILE_BYTES) throw CredentialVaultException("Vault size limit reached")
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            cipher.updateAAD(AAD)
            val encrypted = cipher.doFinal(payload)
            val envelope = JSONObject()
                .put("version", ENVELOPE_VERSION)
                .put("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .toString().toByteArray(StandardCharsets.UTF_8)
            val parent = file.parentFile ?: throw IOException("Vault directory is unavailable")
            if (!parent.exists() && !parent.mkdirs() && !parent.isDirectory) throw IOException("Vault directory cannot be created")
            temp = File.createTempFile(FILE_NAME + ".", ".tmp", parent)
            FileOutputStream(temp).use { stream -> stream.write(envelope); stream.fd.sync() }
            Os.rename(temp.absolutePath, file.absolutePath)
            temp = null
        } catch (e: CredentialVaultException) {
            throw e
        } catch (e: GeneralSecurityException) {
            throw CredentialVaultException("Vault could not be encrypted", e)
        } catch (e: JSONException) {
            throw CredentialVaultException("Vault data could not be encoded", e)
        } catch (e: IOException) {
            throw CredentialVaultException("Vault could not be saved", e)
        } catch (e: ErrnoException) {
            throw CredentialVaultException("Vault could not be atomically replaced", e)
        } finally {
            temp?.delete()
        }
    }

    /** Validates and reduces a submitted URL to its origin; paths and query strings are discarded. */
    fun normalizeOrigin(raw: String): String {
        if (raw.length > MAX_ORIGIN_CHARS) throw IllegalArgumentException("Website URL is too long")
        val uri = Uri.parse(raw.trim())
        val scheme = uri.scheme?.lowercase()
        val host = uri.host?.lowercase()
        if (scheme !in setOf("https", "http") || host.isNullOrBlank() || uri.userInfo != null) {
            throw IllegalArgumentException("Enter a valid HTTP or HTTPS website URL")
        }
        val port = if (uri.port > 0 && !((scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80))) ":${uri.port}" else ""
        return "$scheme://$host$port"
    }

    /** API 29 fallback uses the system's secure device credential screen. */
    fun deviceCredentialIntent(activity: FragmentActivity): Intent? {
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) return null
        return keyguard.createConfirmDeviceCredentialIntent("Unlock password vault", "Confirm your screen lock to continue")
    }

    private fun decode(bytes: ByteArray): List<VaultCredential> {
        try {
            val payload = JSONObject(String(bytes, StandardCharsets.UTF_8))
            if (payload.optInt("schema", -1) != SCHEMA_VERSION) throw CredentialVaultException("Vault schema is unsupported; original file was preserved")
            val values = payload.optJSONArray("credentials") ?: throw CredentialVaultException("Vault data is malformed; original file was preserved")
            if (values.length() > MAX_ENTRIES) throw CredentialVaultException("Vault entry limit exceeded; original file was preserved")
            return (0 until values.length()).map { index ->
                val item = values.getJSONObject(index)
                val user = item.getString("username")
                val secret = item.getString("password")
                if (user.length > MAX_USERNAME_CHARS || secret.length > MAX_PASSWORD_CHARS) throw CredentialVaultException("Vault field size limit exceeded; original file was preserved")
                VaultCredential(
                    id = item.getString("id"),
                    origin = normalizeOrigin(item.getString("origin")),
                    username = user,
                    password = secret,
                )
            }
        } catch (e: CredentialVaultException) {
            throw e
        } catch (e: JSONException) {
            throw CredentialVaultException("Vault data is malformed; original file was preserved", e)
        }
    }

    private fun readEnvelope(): JSONObject {
        if (file.length() > MAX_FILE_BYTES) throw CredentialVaultException("Vault file exceeds the supported size; original file was preserved")
        val envelope = JSONObject(String(file.readBytes(), StandardCharsets.UTF_8))
        if (envelope.optInt("version", -1) != ENVELOPE_VERSION) throw CredentialVaultException("Vault format is unsupported; original file was preserved")
        return envelope
    }

    private fun getOrCreateKey(): SecretKey {
        val store = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val builder = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setUserAuthenticationRequired(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            builder.setUserAuthenticationParameters(
                AUTH_VALIDITY_SECONDS,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL,
            )
        } else {
            @Suppress("DEPRECATION")
            builder.setUserAuthenticationValidityDurationSeconds(AUTH_VALIDITY_SECONDS)
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(builder.build())
        return generator.generateKey()
    }

    companion object {
        private const val FILE_NAME = "breeze_credentials.enc"
        private const val KEY_ALIAS = "com.froydinger.breeze.credentials.v1"
        private const val KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val ENVELOPE_VERSION = 1
        private const val SCHEMA_VERSION = 1
        private const val AUTH_VALIDITY_SECONDS = 30
        private const val MAX_FILE_BYTES = 4 * 1024 * 1024
        private const val MAX_ENTRIES = 1000
        private const val MAX_ORIGIN_CHARS = 2048
        private const val MAX_USERNAME_CHARS = 1024
        private const val MAX_PASSWORD_CHARS = 4096
        private const val NONCE_BYTES = 12
        private const val TAG_BITS = 128
        private val AAD = "breeze-credential-vault:v1".toByteArray(StandardCharsets.UTF_8)
    }
}

/** Authentication helper: prompt first, then the short Keystore validity window authorizes crypto. */
object CredentialVaultAuthentication {
    fun authenticate(
        activity: FragmentActivity,
        onAuthenticated: () -> Unit,
        onDeviceCredentialRequired: (Intent) -> Unit,
        onError: (String) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT == Build.VERSION_CODES.Q) {
            val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
            val intent = if (keyguard.isDeviceSecure) {
                keyguard.createConfirmDeviceCredentialIntent("Unlock password vault", "Confirm your screen lock to continue")
            } else null
            if (intent == null) onError("Set a secure screen lock before using the password vault.")
            else onDeviceCredentialRequired(intent)
            return
        }
        try {
            val prompt = BiometricPrompt(
                activity,
                activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        onAuthenticated()
                    }
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        onError(errString.toString())
                    }
                },
            )
            val promptInfo = BiometricPrompt.PromptInfo.Builder()
                .setTitle("Unlock password vault")
                .setSubtitle("Confirm with biometrics or your device screen lock")
                .setAllowedAuthenticators(
                    androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        androidx.biometric.BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                )
                .build()
            prompt.authenticate(promptInfo)
        } catch (e: Exception) {
            onError(e.message ?: "Authentication could not start")
        }
    }
}

class CredentialVaultException(message: String, cause: Throwable? = null) : Exception(message, cause)
