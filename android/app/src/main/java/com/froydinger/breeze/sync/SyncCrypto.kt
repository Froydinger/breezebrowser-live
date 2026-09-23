package com.froydinger.breeze.sync

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Interoperable encrypted records. Account authentication does not supply a vault key. */
data class SyncEnvelope(
    val recordId: String, val collection: String, val operationId: String,
    val deviceId: String, val keyEpoch: Int, val deleted: Boolean,
    val expectedRevision: Long, val nonce: String, val ciphertext: String,
) {
    fun toJson() = JSONObject().put("recordId",recordId).put("collection",collection)
        .put("operationId",operationId).put("deviceId",deviceId).put("keyEpoch",keyEpoch)
        .put("deleted",deleted).put("expectedRevision",expectedRevision).put("nonce",nonce).put("ciphertext",ciphertext)
    companion object {
        fun fromJson(json: JSONObject) = SyncEnvelope(json.getString("recordId"),json.getString("collection"),json.getString("operationId"),json.getString("deviceId"),json.getInt("keyEpoch"),json.getBoolean("deleted"),json.getLong("expectedRevision"),json.getString("nonce"),json.getString("ciphertext"))
    }
}
object SyncCrypto {
    private const val FLAGS = Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
    fun generateKey(): ByteArray = ByteArray(32).also { SecureRandom().nextBytes(it) }
    fun seal(key: ByteArray, recordId: String, collection: String, deviceId: String, keyEpoch: Int, expectedRevision: Long, deleted: Boolean, plaintext: ByteArray, operationId: String = UUID.randomUUID().toString()): SyncEnvelope {
        require(key.size == 32 && plaintext.size <= 46_000)
        val envelope = SyncEnvelope(recordId,collection,operationId,deviceId,keyEpoch,deleted,expectedRevision,"","")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        cipher.init(Cipher.ENCRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce))
        cipher.updateAAD(aad(envelope))
        return envelope.copy(nonce=Base64.encodeToString(nonce,FLAGS),ciphertext=Base64.encodeToString(cipher.doFinal(plaintext),FLAGS))
    }
    fun open(key: ByteArray, envelope: SyncEnvelope): ByteArray {
        require(key.size == 32 && envelope.ciphertext.length <= 64_000)
        val nonce = Base64.decode(envelope.nonce,FLAGS)
        val ciphertext = Base64.decode(envelope.ciphertext,FLAGS)
        require(nonce.size == 12 && ciphertext.size >= 16)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce))
        cipher.updateAAD(aad(envelope))
        return cipher.doFinal(ciphertext)
    }
    private fun aad(e: SyncEnvelope): ByteArray {
        for (id in listOf(e.recordId,e.operationId,e.deviceId)) require(UUID.fromString(id).toString() == id) { "IDs must be canonical lowercase UUIDs" }
        require(e.collection in listOf("bookmarks","history","chats") && e.keyEpoch >= 1 && e.expectedRevision >= 0)
        return JSONArray().put(1).put(e.recordId).put(e.collection).put(e.operationId).put(e.deviceId).put(e.keyEpoch).put(e.deleted).put(e.expectedRevision).toString().toByteArray(Charsets.UTF_8)
    }
}
