package com.froydinger.breeze.cloud

import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStreamReader
import java.io.PushbackReader
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.DisposableHandle
import org.json.JSONException
import org.json.JSONObject

enum class NavEventType(val wireName: String) {
    ACCEPTED("accepted"), STATUS("status"), TOOL_STARTED("tool_started"), SOURCE("source"),
    TEXT_DELTA("text_delta"), CITATION("citation"), COMPLETED("completed"), FAILED("failed"),
    CANCELLED("cancelled"), UNKNOWN("unknown");

    companion object {
        fun fromWireName(value: String): NavEventType = values().firstOrNull { it.wireName == value } ?: UNKNOWN
    }
}

/** Typed view of one versioned Worker event. Fields beyond the envelope stay in payload. */
data class NavStreamEvent(
    val version: Int,
    val runId: String,
    val eventId: Long,
    val type: NavEventType,
    val wireType: String,
    val payload: JSONObject,
) {
    fun toJsonObject(): JSONObject = JSONObject().apply {
        put("v", version)
        put("runId", runId)
        put("eventId", eventId)
        put("type", wireType)
        val keys = payload.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            put(key, payload.opt(key))
        }
    }

    companion object {
        @Throws(IOException::class)
        fun parse(value: JSONObject, expectedRunId: String? = null): NavStreamEvent {
            val version = value.optInt("v", -1)
            val runId = value.optString("runId", "")
            val eventId = value.optLong("eventId", -1L)
            val wireType = value.optString("type", "")
            if (version != 1 || runId.isBlank() || eventId <= 0L || wireType.isBlank()) {
                throw IOException("Invalid Nav event envelope")
            }
            if (expectedRunId != null && runId != expectedRunId) {
                throw IOException("Nav event run ID mismatch")
            }
            val payload = JSONObject()
            val keys = value.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                if (key != "v" && key != "runId" && key != "eventId" && key != "type") {
                    payload.put(key, value.opt(key))
                }
            }
            return NavStreamEvent(version, runId, eventId, NavEventType.fromWireName(wireType), wireType, payload)
        }
    }
}

/** Authenticated HTTPS SSE client for POST /v1/chat. The token is requested per call. */
class NavSseClient(
    endpoint: String,
    private val tokenProvider: suspend () -> String,
) {
    private val endpointUrl: URL = validateEndpoint(endpoint)

    /** Streams validated Worker envelopes as JSON, preserving the documented callback API. */
    @OptIn(InternalCoroutinesApi::class)
    suspend fun stream(request: JSONObject, onEvent: suspend (JSONObject) -> Unit) {
        val runId = request.optString("runId", "")
        if (!runId.matches(Regex("[A-Za-z0-9_-]{1,128}"))) throw IllegalArgumentException("Request runId is missing or invalid")
        val token = tokenProvider().trim()
        if (token.isEmpty() || token.any { it.isWhitespace() }) throw IOException("Nav authentication is unavailable")

        withContext(Dispatchers.IO) {
            currentCoroutineContext().ensureActive()
            val connectionRef = AtomicReference<HttpURLConnection?>()
            val job = currentCoroutineContext()[Job]
            val cancellationHandle: DisposableHandle? = job?.invokeOnCompletion(
                onCancelling = true,
                invokeImmediately = true,
            ) { cause ->
                if (cause != null) connectionRef.get()?.disconnect()
            }
            var connection: HttpURLConnection? = null
            try {
                currentCoroutineContext().ensureActive()
                val activeConnection = (endpointUrl.openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    doInput = true
                    useCaches = false
                    instanceFollowRedirects = false
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                    setRequestProperty("Authorization", "Bearer $token")
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    setRequestProperty("Accept", "text/event-stream")
                }
                connection = activeConnection
                connectionRef.set(activeConnection)
                currentCoroutineContext().ensureActive()
                activeConnection.outputStream.use { output ->
                    output.write(request.toString().toByteArray(Charsets.UTF_8))
                    output.flush()
                }
                currentCoroutineContext().ensureActive()
                val status = activeConnection.responseCode
                if (status !in 200..299) {
                    throw IOException(httpErrorMessage(status, readBoundedErrorBody(activeConnection)))
                }
                val contentType = activeConnection.contentType.orEmpty()
                if (!contentType.substringBefore(';').trim().equals("text/event-stream", ignoreCase = true)) {
                    throw IOException("Nav returned an unexpected response type")
                }
                val stream = activeConnection.inputStream
                val reader = PushbackReader(BufferedReader(InputStreamReader(stream, Charsets.UTF_8)), 1)
                try {
                    readEvents(reader, runId, onEvent)
                } finally {
                    reader.close()
                }
            } finally {
                cancellationHandle?.dispose()
                connectionRef.set(null)
                connection?.disconnect()
            }
        }
    }

    private suspend fun readEvents(
        reader: PushbackReader,
        expectedRunId: String,
        onEvent: suspend (JSONObject) -> Unit,
    ) {
        val dataLines = ArrayList<String>()
        var eventChars = 0
        var previousEventId = 0L

        suspend fun dispatch() {
            if (dataLines.isEmpty()) {
                eventChars = 0
                return
            }
            val data = dataLines.joinToString("\n")
            dataLines.clear()
            eventChars = 0
            val envelope = try {
                JSONObject(data)
            } catch (_: JSONException) {
                throw IOException("Nav stream contained invalid event JSON")
            }
            val event = NavStreamEvent.parse(envelope, expectedRunId)
            if (event.eventId <= previousEventId) throw IOException("Nav event IDs are not increasing")
            previousEventId = event.eventId
            currentCoroutineContext().ensureActive()
            onEvent(event.toJsonObject())
        }

        while (true) {
            currentCoroutineContext().ensureActive()
            val line = readBoundedLine(reader, MAX_LINE_CHARS) ?: break
            eventChars += line.length + 1
            if (eventChars > MAX_EVENT_CHARS) throw IOException("Nav stream event exceeded the size limit")
            if (line.isEmpty()) {
                dispatch()
                continue
            }
            if (line[0] == ':') continue // SSE comment/heartbeat
            val colon = line.indexOf(':')
            val field = if (colon < 0) line else line.substring(0, colon)
            var value = if (colon < 0) "" else line.substring(colon + 1)
            if (value.startsWith(' ')) value = value.drop(1)
            if (field == "data") dataLines += value
        }
        dispatch()
    }

    private fun readBoundedLine(reader: PushbackReader, maxChars: Int): String? {
        val result = StringBuilder()
        while (true) {
            val code = reader.read()
            if (code < 0) return if (result.isEmpty()) null else result.toString()
            when (code.toChar()) {
                '\n' -> return result.toString()
                '\r' -> {
                    val next = reader.read()
                    if (next >= 0 && next.toChar() != '\n') reader.unread(next)
                    return result.toString()
                }
                else -> {
                    if (result.length >= maxChars) throw IOException("Nav stream line exceeded the size limit")
                    result.append(code.toChar())
                }
            }
        }
    }

    companion object {
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 125_000
        private const val MAX_LINE_CHARS = 64 * 1024
        private const val MAX_EVENT_CHARS = 256 * 1024
        private const val MAX_ERROR_BODY_BYTES = 4 * 1024

        private fun readBoundedErrorBody(connection: HttpURLConnection): String? {
            return try {
                val stream = connection.errorStream ?: return null
                stream.use { input ->
                    val output = ByteArrayOutputStream()
                    val buffer = ByteArray(512)
                    while (output.size() <= MAX_ERROR_BODY_BYTES) {
                        val bytesToRead = minOf(buffer.size, MAX_ERROR_BODY_BYTES + 1 - output.size())
                        val count = input.read(buffer, 0, bytesToRead)
                        if (count <= 0) break
                        output.write(buffer, 0, count)
                    }
                    if (output.size() > MAX_ERROR_BODY_BYTES) null
                    else String(output.toByteArray(), Charsets.UTF_8)
                }
            } catch (_: Exception) {
                null
            }
        }

        private fun httpErrorMessage(status: Int, body: String?): String {
            val fallback = "Nav request failed (HTTP $status)"
            if (status != 429 || body == null) return fallback

            val quotaError = try {
                JSONObject(body)
            } catch (_: JSONException) {
                return fallback
            }
            // Only recognize the Worker quota response. Never surface arbitrary response text.
            if (quotaError.optString("error", "") != "Daily mobile limit reached.") return fallback

            val used = quotaError.boundedCount("used")
            val limit = quotaError.boundedCount("limit")
            val remaining = quotaError.boundedCount("remaining")
            if (used != null && limit != null) {
                val remainingText = remaining?.let { ", $it remaining" }.orEmpty()
                return "Nav daily request limit reached ($used of $limit used$remainingText). It resets at UTC midnight."
            }
            return "Nav daily request limit reached. It resets at UTC midnight."
        }

        private fun JSONObject.boundedCount(key: String): Int? {
            val number = opt(key) as? Number ?: return null
            val value = number.toDouble()
            if (!value.isFinite() || value < 0.0 || value > 1_000_000.0 || value % 1.0 != 0.0) return null
            return value.toInt()
        }

        private fun validateEndpoint(value: String): URL {
            val uri = try {
                URI(value)
            } catch (_: Exception) {
                throw IllegalArgumentException("Nav endpoint is invalid")
            }
            require(uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank() && uri.userInfo == null) {
                "Nav endpoint must be an HTTPS URL"
            }
            require(uri.fragment == null) { "Nav endpoint must not include a fragment" }
            return uri.toURL()
        }
    }
}
