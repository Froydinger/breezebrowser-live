package com.froydinger.breeze.browser

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.CookieManager
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.fragment.app.FragmentActivity
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Download adapter for Android WebView's DownloadListener. Register before the Activity reaches
 * STARTED. The caller supplies the page URL captured when the download event fired and its private
 * mode; saved history is reported only for regular tabs.
 *
 * WebView does not expose the original request's arbitrary headers or auth cache to DownloadListener.
 * This adapter intentionally replays only WebView cookies, and only for an HTTPS download whose
 * scheme/host/port exactly match the captured source page. It never forwards cookies across redirects.
 */
class ChromiumDownloads(
    private val activity: FragmentActivity,
    private val onNotice: (String) -> Unit = {},
    private val onDownloadSaved: (uri: String, name: String) -> Unit = { _, _ -> },
) {
    private data class Pending(
        val url: String,
        val sourceUrl: String,
        val userAgent: String?,
        val filename: String,
        val mimeType: String,
        val privateMode: Boolean,
        val cookieManager: CookieManager,
    )

    private var pending: Pending? = null
    @Volatile private var busy = false
    @Volatile private var closed = false
    @Volatile private var activeConnection: HttpURLConnection? = null
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val picker: ActivityResultLauncher<Pair<String, String>> =
        activity.activityResultRegistry.register(
            "breeze-chromium-download-${activity.javaClass.name}", activity, CreateFileContract(),
        ) { uri -> finishPicker(uri) }

    /** Suitable as the WebViewClient/WebView DownloadListener callback body. */
    fun handleDownload(
        url: String,
        userAgent: String?,
        contentDisposition: String?,
        mimeType: String?,
        sourcePageUrl: String,
        privateMode: Boolean,
        /** Pass WebViewCompat.getProfile(webView).cookieManager for isolated private tabs. */
        cookieManager: CookieManager,
    ) {
        if (closed || busy || pending != null) {
            onNotice(if (busy || pending != null) "Another download is already in progress." else "Download is unavailable while the browser is closing.")
            return
        }
        val parsed = runCatching { Uri.parse(url) }.getOrNull()
        if (parsed == null || parsed.scheme?.lowercase() !in setOf("http", "https") || parsed.host.isNullOrBlank()) {
            onNotice("This download address is not supported.")
            return
        }
        val name = safeFilename(contentDisposition, parsed.lastPathSegment)
        val mime = safeMimeType(mimeType)
        val item = Pending(url, sourcePageUrl, userAgent?.takeIf { it.isNotBlank() }, name, mime, privateMode, cookieManager)
        pending = item
        try {
            picker.launch(name to mime)
        } catch (_: IllegalStateException) {
            pending = null
            onNotice("Download picker is unavailable right now.")
        } catch (_: SecurityException) {
            pending = null
            onNotice("Download permission was not granted.")
        }
    }

    fun close() {
        closed = true
        pending = null
        activeConnection?.disconnect()
        executor.shutdownNow()
    }

    private fun finishPicker(uri: Uri?) {
        val item = pending.also { pending = null } ?: return
        if (uri == null) {
            onNotice("Download cancelled.")
            return
        }
        if (closed || busy) {
            onNotice("Another download is already in progress.")
            return
        }
        busy = true
        onNotice("Saving download…")
        try {
            executor.execute {
                val result = transfer(item, uri)
                activity.runOnUiThread {
                    busy = false
                    if (closed) return@runOnUiThread
                    if (result.saved && !item.privateMode) runCatching {
                        onDownloadSaved(uri.toString(), item.filename)
                    }
                    onNotice(result.message)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            busy = false
            onNotice("Download was cancelled because the browser is closing.")
        }
    }

    private data class TransferResult(val saved: Boolean, val message: String)

    private fun transfer(item: Pending, destination: Uri): TransferResult {
        var bytes = 0L
        var connection: HttpURLConnection? = null
        return try {
            val sourceOrigin = httpsOrigin(item.sourceUrl)
            var current = URL(item.url)
            var cookieAllowed = sourceOrigin != null && sourceOrigin == httpsOrigin(current.toString())
            var redirects = 0
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                connection = (current.openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    connectTimeout = CONNECT_TIMEOUT_MS
                    readTimeout = READ_TIMEOUT_MS
                    requestMethod = "GET"
                    item.userAgent?.let { setRequestProperty("User-Agent", it.take(MAX_HEADER_CHARS)) }
                    if (cookieAllowed && current.protocol.equals("https", true)) {
                        item.cookieManager.getCookie(current.toString())
                            ?.takeIf { it.length <= MAX_HEADER_CHARS }
                            ?.let { setRequestProperty("Cookie", it) }
                    }
                }
                activeConnection = connection
                val status = connection!!.responseCode
                if (status in REDIRECT_CODES) {
                    val location = connection!!.getHeaderField("Location") ?: throw IllegalStateException("Redirect missing location")
                    if (++redirects > MAX_REDIRECTS) throw IllegalStateException("Too many redirects")
                    val next = URL(current, location)
                    if (!next.protocol.equals("http", true) && !next.protocol.equals("https", true)) throw IllegalStateException("Unsupported redirect")
                    if (current.protocol.equals("https", true) && next.protocol.equals("http", true)) throw IllegalStateException("Insecure redirect")
                    cookieAllowed = cookieAllowed && sourceOrigin != null && sourceOrigin == httpsOrigin(next.toString())
                    connection!!.disconnect()
                    activeConnection = null
                    connection = null
                    current = next
                    continue
                }
                if (status !in 200..299) throw IllegalStateException("Download request failed")
                val declared = connection!!.contentLengthLong
                if (declared > MAX_DOWNLOAD_BYTES) throw SizeLimitException()
                val output = activity.contentResolver.openOutputStream(destination, "w")
                    ?: throw IllegalStateException("Destination unavailable")
                connection!!.inputStream.use { input ->
                    output.use { sink ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            if (Thread.currentThread().isInterrupted) throw InterruptedException()
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count
                            if (bytes > MAX_DOWNLOAD_BYTES) throw SizeLimitException()
                            sink.write(buffer, 0, count)
                        }
                        sink.flush()
                    }
                }
                break
            }
            TransferResult(true, "Download saved (${humanBytes(bytes)}).")
        } catch (_: SizeLimitException) {
            deletePartial(destination)
            TransferResult(false, "Download exceeds the 512 MB limit.")
        } catch (_: InterruptedException) {
            deletePartial(destination)
            Thread.currentThread().interrupt()
            TransferResult(false, "Download was cancelled.")
        } catch (_: Exception) {
            deletePartial(destination)
            TransferResult(false, "Download could not be saved.")
        } finally {
            connection?.disconnect()
            activeConnection = null
        }
    }

    private fun deletePartial(uri: Uri) {
        runCatching { activity.contentResolver.delete(uri, null, null) }
    }

    private fun httpsOrigin(value: String): String? = runCatching {
        val uri = Uri.parse(value)
        val host = uri.host?.lowercase()?.takeIf(String::isNotBlank)
        if (!uri.scheme.equals("https", true) || host == null) null
        else "https://$host:${if (uri.port >= 0) uri.port else 443}"
    }.getOrNull()

    private fun safeFilename(disposition: String?, pathName: String?): String {
        val extended = disposition?.let { Regex("(?i)(?:^|;)\\s*filename\\*=\\s*UTF-8''([^;]+)").find(it)?.groupValues?.getOrNull(1) }
            ?.let { runCatching { Uri.decode(it.trim().trim('"')) }.getOrNull() }
        val plain = disposition?.let { Regex("(?i)(?:^|;)\\s*filename\\s*=\\s*(?:\"([^\"]*)\"|([^;]*))").find(it) }
            ?.let { it.groupValues[1].ifBlank { it.groupValues[2] }.trim() }
        val candidate = (extended ?: plain ?: pathName ?: "download").substringAfterLast('/').substringAfterLast('\\')
        return candidate.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.', '_').take(MAX_FILENAME_CHARS).ifBlank { "download" }
    }

    private fun safeMimeType(raw: String?): String = raw?.substringBefore(';')?.trim()?.lowercase()
        ?.takeIf { MIME_TYPE.matches(it) } ?: "application/octet-stream"

    private fun humanBytes(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> "${bytes / (1024 * 1024)} MB"
    }

    private class SizeLimitException : Exception()

    private class CreateFileContract : ActivityResultContract<Pair<String, String>, Uri?>() {
        override fun createIntent(context: Context, input: Pair<String, String>): Intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(input.second)
            .putExtra(Intent.EXTRA_TITLE, input.first)

        override fun parseResult(resultCode: Int, intent: Intent?): Uri? =
            if (resultCode == Activity.RESULT_OK) intent?.data else null
    }

    private companion object {
        const val MAX_DOWNLOAD_BYTES = 512L * 1024L * 1024L
        const val MAX_FILENAME_CHARS = 120
        const val MAX_HEADER_CHARS = 16 * 1024
        const val CONNECT_TIMEOUT_MS = 20_000
        const val READ_TIMEOUT_MS = 30_000
        const val MAX_REDIRECTS = 5
        val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)
        val MIME_TYPE = Regex("^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")
    }
}
