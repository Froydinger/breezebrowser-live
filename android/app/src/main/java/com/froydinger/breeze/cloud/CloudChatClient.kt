package com.froydinger.breeze.cloud

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.net.URL
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

/**
 * Development client for the existing Breeze Cloud Chat Completions endpoint.
 * The supplied token is sent only as a bearer credential over HTTPS.
 */
class CloudChatClient(
    endpoint: String,
    private val tokenProvider: suspend () -> String,
) {
    private val endpointUrl: URL = validateEndpoint(endpoint)

    @OptIn(InternalCoroutinesApi::class)
    suspend fun complete(messages: JSONArray, requestId: String): String {
        require(requestId.matches(Regex("[A-Za-z0-9_-]{1,128}"))) { "Request ID is missing or invalid" }
        val token = tokenProvider().trim()
        if (token.isEmpty() || token.any { it.isWhitespace() }) throw IOException("Cloud authentication is unavailable")

        val payload = JSONObject()
            .put("messages", JSONArray(messages.toString()))
            .put("max_completion_tokens", MAX_COMPLETION_TOKENS)
            .put("breeze_reasoning_effort", "low")
            .toString()
            .toByteArray(Charsets.UTF_8)
        if (payload.size > MAX_REQUEST_BYTES) throw IOException("Cloud request exceeded the size limit")

        return withContext(Dispatchers.IO) {
            currentCoroutineContext().ensureActive()
            val connectionRef = AtomicReference<HttpsURLConnection?>()
            val job = currentCoroutineContext()[Job]
            val cancellationHandle: DisposableHandle? = job?.invokeOnCompletion(
                onCancelling = true,
                invokeImmediately = true,
            ) { cause ->
                if (cause != null) connectionRef.get()?.disconnect()
            }
            var connection: HttpsURLConnection? = null
            try {
                currentCoroutineContext().ensureActive()
                val activeConnection = (endpointUrl.openConnection() as HttpsURLConnection).apply {
                    requestMethod = "POST"
                    doOutput = true
                    doInput = true
                    useCaches = false
                    instanceFollowRedirects = false
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                    setRequestProperty("Authorization", "Bearer $token")
                    setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    setRequestProperty("Accept", "application/json")
                    setRequestProperty("X-Breeze-Client-Id", DEVELOPMENT_CLIENT_ID)
                    setRequestProperty("X-Breeze-Request-Id", requestId)
                }
                connection = activeConnection
                connectionRef.set(activeConnection)
                currentCoroutineContext().ensureActive()
                activeConnection.outputStream.use { output ->
                    output.write(payload)
                    output.flush()
                }
                currentCoroutineContext().ensureActive()
                val status = activeConnection.responseCode
                if (status !in 200..299) throw IOException("Cloud request failed (HTTP $status)")
                val contentType = activeConnection.contentType.orEmpty().substringBefore(';').trim()
                if (!contentType.equals("application/json", ignoreCase = true)) {
                    throw IOException("Cloud returned an unexpected response type")
                }
                val declaredLength = activeConnection.getHeaderFieldLong("Content-Length", -1L)
                if (declaredLength > MAX_RESPONSE_BYTES) throw IOException("Cloud response exceeded the size limit")
                val bytes = readBounded(activeConnection.inputStream, MAX_RESPONSE_BYTES)
                currentCoroutineContext().ensureActive()
                extractContent(bytes)
            } finally {
                cancellationHandle?.dispose()
                connectionRef.set(null)
                connection?.disconnect()
            }
        }
    }

    private fun readBounded(input: java.io.InputStream, maxBytes: Int): ByteArray {
        input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (output.size() + count > maxBytes) throw IOException("Cloud response exceeded the size limit")
                output.write(buffer, 0, count)
            }
            return output.toByteArray()
        }
    }

    private fun extractContent(bytes: ByteArray): String {
        val response = try {
            JSONObject(String(bytes, Charsets.UTF_8))
        } catch (_: JSONException) {
            throw IOException("Cloud returned invalid JSON")
        }
        val choices = response.optJSONArray("choices")
        val content = choices?.optJSONObject(0)?.optJSONObject("message")?.opt("content")
        return content as? String ?: throw IOException("Cloud response did not contain assistant text")
    }

    companion object {
        private const val DEVELOPMENT_CLIENT_ID = "breeze-android-development"
        private const val MAX_COMPLETION_TOKENS = 4096
        private const val MAX_REQUEST_BYTES = 2 * 1024 * 1024
        private const val MAX_RESPONSE_BYTES = 1024 * 1024
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 120_000

        private fun validateEndpoint(value: String): URL {
            val uri = try {
                URI(value)
            } catch (_: Exception) {
                throw IllegalArgumentException("Cloud endpoint is invalid")
            }
            require(uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank() && uri.userInfo == null) {
                "Cloud endpoint must be an HTTPS URL"
            }
            require(uri.fragment == null) { "Cloud endpoint must not include a fragment" }
            return uri.toURL()
        }
    }
}
