package com.froydinger.breeze.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** Encrypted local queue only. It does not upload, download, or imply sync. */
class EncryptedOutboxStore(context: Context) {
    private val store = EncryptedStateStore(
        context = context,
        fileName = FILE_NAME,
        keyAlias = KEY_ALIAS,
    )

    /**
     * Adds one explicit sync candidate and assigns an increasing local cursor.
     * `recordId` must be a stable caller-owned UUID or equivalent. Callers must
     * never enqueue private-session data. A true private marker is rejected.
     */
    @Synchronized
    @Throws(StateStoreException::class, IllegalArgumentException::class)
    fun enqueue(recordId: String, collection: String, operation: JSONObject): OutboxRecord {
        require(recordId.isNotBlank()) { "recordId must not be blank" }
        require(collection in ALLOWED_COLLECTIONS) { "Unsupported outbox collection" }
        require(!operation.optBoolean("privateSession", false) && !operation.optBoolean("isPrivate", false)) {
            "Private-session data cannot be added to the outbox"
        }
        val (root, records) = readState()
        val nextCursor = root.optLong("nextCursor", 1L)
        require(nextCursor > 0L && nextCursor < Long.MAX_VALUE) { "Outbox cursor is invalid or exhausted" }

        val json = JSONObject()
            .put("operationId", UUID.randomUUID().toString())
            .put("recordId", recordId)
            .put("collection", collection)
            .put("cursor", nextCursor)
            .put("operation", JSONObject(operation.toString()))
        records.put(json)
        store.save(
            JSONObject()
                .put("schemaVersion", SCHEMA_VERSION)
                .put("nextCursor", nextCursor + 1)
                .put("records", records),
        )
        return OutboxRecord(json)
    }

    /** Returns queued records in cursor order. */
    @Synchronized
    @Throws(StateStoreException::class)
    fun pending(): List<OutboxRecord> {
        val (_, records) = readState()
        return (0 until records.length())
            .map { index ->
                val json = records.optJSONObject(index)
                    ?: throw StateStoreException("Outbox contains an invalid record; original file was preserved")
                try {
                    OutboxRecord(json)
                } catch (e: Exception) {
                    throw StateStoreException("Outbox contains an invalid record; original file was preserved", e)
                }
            }
            .sortedBy { it.cursor }
    }

    /** Highest local cursor allocated, or zero before the first record. */
    @Synchronized
    @Throws(StateStoreException::class)
    fun latestCursor(): Long {
        val (root, _) = readState()
        return (root.optLong("nextCursor", 1L) - 1L).coerceAtLeast(0L)
    }

    private fun readState(): Pair<JSONObject, JSONArray> {
        val root = store.load()
        if (root.length() == 0) return JSONObject().put("nextCursor", 1L) to JSONArray()
        val records = root.optJSONArray("records")
            ?: throw StateStoreException("Outbox state is malformed; original file was preserved")
        val nextCursor = root.optLong("nextCursor", -1L)
        if (root.optInt("schemaVersion", -1) != SCHEMA_VERSION || nextCursor <= 0L) {
            throw StateStoreException("Outbox state is unsupported or malformed; original file was preserved")
        }
        return root to records
    }

    companion object {
        private const val FILE_NAME = "breeze_sync_outbox.enc"
        private const val KEY_ALIAS = "com.froydinger.breeze.data.outbox.v1"
        private const val SCHEMA_VERSION = 1
        private val ALLOWED_COLLECTIONS = setOf("bookmarks", "history", "chats")
    }
}

/** Immutable view over one durable, encrypted pending record. */
class OutboxRecord internal constructor(json: JSONObject) {
    val operationId: String = json.getString("operationId")
    val recordId: String = json.getString("recordId")
    val collection: String = json.getString("collection")
    val cursor: Long = json.getLong("cursor")
    val operation: JSONObject = JSONObject(json.getJSONObject("operation").toString())
}
