package com.froydinger.breeze.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.system.Os
import android.system.ErrnoException
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.StandardCharsets
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small encrypted JSON persistence foundation. This is intended as a temporary
 * local store until the app adopts encrypted Room/SQLCipher storage.
 *
 * Each instance owns one file and one Android Keystore AES-256-GCM key. All
 * methods are synchronized for callers sharing this instance. Use one instance
 * per file in a process; this class does not coordinate independent instances.
 */
class EncryptedStateStore(
    context: Context,
    fileName: String = DEFAULT_FILE_NAME,
    private val keyAlias: String = DEFAULT_KEY_ALIAS,
) {
    private val file: File
    private val aad: ByteArray

    init {
        require(fileName.matches(Regex("[A-Za-z0-9_.-]+")) && !fileName.startsWith('.')) {
            "fileName must be a simple internal filename"
        }
        require(keyAlias.isNotBlank()) { "keyAlias must not be blank" }
        val appContext = context.applicationContext
        file = File(appContext.noBackupFilesDir, fileName)
        aad = (FORMAT_TAG + ":" + fileName).toByteArray(StandardCharsets.UTF_8)
    }

    /** Returns an empty object only when no state file exists. Corruption is reported. */
    @Synchronized
    @Throws(StateStoreException::class)
    fun load(): JSONObject {
        if (!file.exists()) return JSONObject()
        try {
            val envelope = JSONObject(String(file.readBytes(), StandardCharsets.UTF_8))
            if (envelope.optInt("version", -1) != FORMAT_VERSION) {
                throw StateStoreException("Unsupported encrypted state format")
            }
            val nonce = Base64.decode(envelope.getString("nonce"), Base64.NO_WRAP)
            val ciphertext = Base64.decode(envelope.getString("ciphertext"), Base64.NO_WRAP)
            if (nonce.size != GCM_NONCE_BYTES || ciphertext.size < GCM_TAG_BYTES) {
                throw StateStoreException("Invalid encrypted state envelope")
            }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, nonce))
            cipher.updateAAD(aad)
            val plaintext = cipher.doFinal(ciphertext)
            return JSONObject(String(plaintext, StandardCharsets.UTF_8))
        } catch (e: StateStoreException) {
            throw e
        } catch (e: AEADBadTagException) {
            throw StateStoreException("Encrypted state failed authentication; original file was preserved", e)
        } catch (e: JSONException) {
            throw StateStoreException("Encrypted state is malformed; original file was preserved", e)
        } catch (e: GeneralSecurityException) {
            throw StateStoreException("Encrypted state could not be opened; original file was preserved", e)
        } catch (e: IOException) {
            throw StateStoreException("Encrypted state could not be read", e)
        } catch (e: IllegalArgumentException) {
            throw StateStoreException("Encrypted state encoding is invalid; original file was preserved", e)
        }
    }

    /** Encrypts before writing and atomically replaces the previous ciphertext file. */
    @Synchronized
    @Throws(StateStoreException::class)
    fun save(state: JSONObject) {
        val plaintext = state.toString().toByteArray(StandardCharsets.UTF_8)
        var temp: File? = null
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            cipher.updateAAD(aad)
            val ciphertext = cipher.doFinal(plaintext)
            val envelope = JSONObject()
                .put("version", FORMAT_VERSION)
                .put("nonce", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                .put("ciphertext", Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                .toString()
                .toByteArray(StandardCharsets.UTF_8)

            val parent = file.parentFile ?: throw IOException("Missing internal storage directory")
            if (!parent.exists() && !parent.mkdirs() && !parent.isDirectory) {
                throw IOException("Could not create internal storage directory")
            }
            temp = File.createTempFile(file.name + ".", ".tmp", parent)
            FileOutputStream(temp).use { stream ->
                stream.write(envelope)
                stream.fd.sync()
            }
            // Same-directory rename is atomic on Android's filesystem. Existing file
            // stays in place if this operation fails.
            Os.rename(temp.absolutePath, file.absolutePath)
            temp = null
        } catch (e: StateStoreException) {
            throw e
        } catch (e: GeneralSecurityException) {
            throw StateStoreException("Encrypted state could not be saved", e)
        } catch (e: JSONException) {
            throw StateStoreException("Encrypted state could not be encoded", e)
        } catch (e: IOException) {
            throw StateStoreException("Encrypted state could not be saved", e)
        } catch (e: ErrnoException) {
            throw StateStoreException("Encrypted state could not be atomically replaced", e)
        } finally {
            temp?.delete()
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(keyAlias, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    companion object {
        const val DEFAULT_FILE_NAME = "breeze_state.enc"
        const val DEFAULT_KEY_ALIAS = "com.froydinger.breeze.data.state.v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_TAG = "breeze-encrypted-json"
        private const val FORMAT_VERSION = 1
        private const val GCM_NONCE_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
    }
}

/** A storage failure that callers must surface instead of replacing user data. */
class StateStoreException(message: String, cause: Throwable? = null) : Exception(message, cause)
