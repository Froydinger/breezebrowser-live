package com.froydinger.breeze.browser

import android.app.AlertDialog
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.text.InputType
import android.widget.EditText
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContract
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import org.mozilla.geckoview.AllowOrDeny
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import org.mozilla.geckoview.WebResponse
import java.io.InputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Native Gecko site-prompt adapter. Construct in FragmentActivity.onCreate before STARTED so SAF
 * result launchers are registered in time. Handles JavaScript alert/confirm/prompt, HTML select,
 * before-unload/repost confirmation, and file inputs through the system document picker.
 */
class BrowserPrompts(
    private val activity: FragmentActivity,
    private val onNotice: (String) -> Unit = {},
    private val onDownloadSaved: (uri: String, name: String) -> Unit = { _, _ -> },
) : GeckoSession.PromptDelegate {
    private data class PendingFile(
        val prompt: GeckoSession.PromptDelegate.FilePrompt,
        val result: GeckoResult<GeckoSession.PromptDelegate.PromptResponse>,
    )

    private val keySeed = AtomicLong(0)
    private var pendingFile: PendingFile? = null
    private data class PendingDownload(val body: InputStream, val filename: String, val mimeType: String, val saveInHistory: Boolean)
    private var pendingDownload: PendingDownload? = null
    @Volatile private var activeDownload: PendingDownload? = null
    private var downloadBusy = false
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val singleDocument: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            key("single"), activity, ActivityResultContracts.OpenDocument(),
        ) { uri -> finishSingleFile(uri) }

    private val multipleDocuments: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            key("multiple"), activity, ActivityResultContracts.OpenMultipleDocuments(),
        ) { uris -> finishMultipleFiles(uris) }

    private val folderDocument: ActivityResultLauncher<Uri?> =
        activity.activityResultRegistry.register(
            key("folder"), activity, ActivityResultContracts.OpenDocumentTree(),
        ) { uri -> finishFolder(uri) }

    private val downloadDocument: ActivityResultLauncher<Pair<String, String>> =
        activity.activityResultRegistry.register(
            key("download"), activity, CreateFileContract(),
        ) { uri -> finishDownload(uri) }

    private fun key(kind: String) = "breeze-gecko-$kind-${activity.javaClass.name}-${keySeed.incrementAndGet()}"

    override fun onAlertPrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.AlertPrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> =
        showResult { result ->
            AlertDialog.Builder(activity)
                .setTitle(prompt.title ?: "Page alert")
                .setMessage(prompt.message.orEmpty())
                .setPositiveButton(android.R.string.ok) { _, _ -> complete(result, prompt.dismiss()) }
                .setOnCancelListener { complete(result, prompt.dismiss()) }
                .show()
        }

    override fun onButtonPrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.ButtonPrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> =
        showResult { result ->
            AlertDialog.Builder(activity)
                .setTitle(prompt.title ?: "Confirm")
                .setMessage(prompt.message.orEmpty())
                .setPositiveButton(android.R.string.ok) { _, _ ->
                    complete(result, prompt.confirm(GeckoSession.PromptDelegate.ButtonPrompt.Type.POSITIVE))
                }
                .setNegativeButton(android.R.string.cancel) { _, _ ->
                    complete(result, prompt.confirm(GeckoSession.PromptDelegate.ButtonPrompt.Type.NEGATIVE))
                }
                .setOnCancelListener { complete(result, prompt.confirm(GeckoSession.PromptDelegate.ButtonPrompt.Type.NEGATIVE)) }
                .show()
        }

    override fun onTextPrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.TextPrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> =
        showResult { result ->
            val input = EditText(activity).apply {
                setText(prompt.defaultValue.orEmpty())
                inputType = InputType.TYPE_CLASS_TEXT
                setSingleLine(true)
            }
            AlertDialog.Builder(activity)
                .setTitle(prompt.title ?: "Page input")
                .setMessage(prompt.message.orEmpty())
                .setView(input)
                .setPositiveButton(android.R.string.ok) { _, _ -> complete(result, prompt.confirm(input.text.toString())) }
                .setNegativeButton(android.R.string.cancel) { _, _ -> complete(result, prompt.dismiss()) }
                .setOnCancelListener { complete(result, prompt.dismiss()) }
                .show()
        }

    override fun onChoicePrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.ChoicePrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val choices = flatten(prompt.choices)
        if (choices.isEmpty()) return GeckoResult.fromValue(prompt.dismiss())
        return showResult { result ->
            val labels = choices.map { it.second }.toTypedArray()
            val selected = BooleanArray(choices.size) { choices[it].first.selected }
            val builder = AlertDialog.Builder(activity).setTitle(prompt.title ?: "Choose an option")
            if (prompt.type == GeckoSession.PromptDelegate.ChoicePrompt.Type.MULTIPLE) {
                builder.setMultiChoiceItems(labels, selected) { _, which, checked -> selected[which] = checked }
                builder.setPositiveButton(android.R.string.ok) { _, _ ->
                    val ids = choices.indices.filter { selected[it] }.map { choices[it].first.id }.toTypedArray()
                    complete(result, prompt.confirm(ids))
                }
            } else {
                var selectedIndex = selected.indexOfFirst { it }.coerceAtLeast(-1)
                builder.setSingleChoiceItems(labels, selectedIndex) { dialog, which -> selectedIndex = which }
                    .setPositiveButton(android.R.string.ok) { _, _ ->
                        if (selectedIndex in choices.indices) complete(result, prompt.confirm(choices[selectedIndex].first.id))
                        else complete(result, prompt.dismiss())
                    }
            }
            builder.setNegativeButton(android.R.string.cancel) { _, _ -> complete(result, prompt.dismiss()) }
                .setOnCancelListener { complete(result, prompt.dismiss()) }
                .show()
        }
    }

    override fun onBeforeUnloadPrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.BeforeUnloadPrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> =
        showResult { result ->
            AlertDialog.Builder(activity)
                .setTitle(prompt.title ?: "Leave this page?")
                .setMessage("Changes you made may not be saved.")
                .setPositiveButton("Leave") { _, _ -> complete(result, prompt.confirm(AllowOrDeny.ALLOW)) }
                .setNegativeButton("Stay") { _, _ -> complete(result, prompt.confirm(AllowOrDeny.DENY)) }
                .setOnCancelListener { complete(result, prompt.confirm(AllowOrDeny.DENY)) }
                .show()
        }

    override fun onRepostConfirmPrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.RepostConfirmPrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> =
        showResult { result ->
            AlertDialog.Builder(activity)
                .setTitle("Resend form?")
                .setMessage("This page may send the same form data again.")
                .setPositiveButton("Resend") { _, _ -> complete(result, prompt.confirm(AllowOrDeny.ALLOW)) }
                .setNegativeButton(android.R.string.cancel) { _, _ -> complete(result, prompt.confirm(AllowOrDeny.DENY)) }
                .setOnCancelListener { complete(result, prompt.confirm(AllowOrDeny.DENY)) }
                .show()
        }

    override fun onFilePrompt(
        session: GeckoSession,
        prompt: GeckoSession.PromptDelegate.FilePrompt,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val result = GeckoResult<GeckoSession.PromptDelegate.PromptResponse>()
        if (activity.lifecycle.currentState == Lifecycle.State.DESTROYED) {
            result.complete(prompt.dismiss())
            return result
        }
        pendingFile?.let { old ->
            pendingFile = null
            old.result.complete(old.prompt.dismiss())
        }
        pendingFile = PendingFile(prompt, result)
        val mimeTypes = prompt.mimeTypes?.filter(String::isNotBlank)?.distinct()?.toTypedArray()
            ?.takeIf { it.isNotEmpty() } ?: arrayOf("*/*")
        try {
            when (prompt.type) {
                GeckoSession.PromptDelegate.FilePrompt.Type.FOLDER -> folderDocument.launch(null)
                GeckoSession.PromptDelegate.FilePrompt.Type.MULTIPLE -> multipleDocuments.launch(mimeTypes)
                else -> singleDocument.launch(mimeTypes)
            }
        } catch (_: IllegalStateException) {
            pendingFile = null
            result.complete(prompt.dismiss())
        } catch (_: SecurityException) {
            pendingFile = null
            result.complete(prompt.dismiss())
        }
        return result
    }


    /** Presents a SAF destination picker and streams this Gecko response to the chosen URI. */
    fun handleDownload(response: WebResponse, privateMode: Boolean = false) {
        val body = response.body
        if (body == null) {
            onNotice("Download could not start because no response body was available.")
            return
        }
        if (response.statusCode !in 200..299 || downloadBusy || pendingDownload != null) {
            runCatching { body.close() }
            onNotice(if (downloadBusy || pendingDownload != null) "Another download is already in progress." else "This response could not be downloaded.")
            return
        }
        val pending = PendingDownload(body, safeFilename(response), safeMimeType(response), saveInHistory = !privateMode)
        pendingDownload = pending
        try {
            downloadDocument.launch(pending.filename to pending.mimeType)
        } catch (_: IllegalStateException) {
            pendingDownload = null
            closeQuietly(pending.body)
            onNotice("Download picker is unavailable right now.")
        } catch (_: SecurityException) {
            pendingDownload = null
            closeQuietly(pending.body)
            onNotice("Download permission was not granted.")
        }
    }

    /** Closes outstanding response streams and stops background transfer work. */
    fun close() {
        pendingFile?.let { file ->
            pendingFile = null
            runCatching { file.result.complete(file.prompt.dismiss()) }
        }
        pendingDownload?.let { closeQuietly(it.body) }
        pendingDownload = null
        activeDownload?.let { closeQuietly(it.body) }
        activeDownload = null
        ioExecutor.shutdownNow()
    }

    private fun finishDownload(uri: Uri?) {
        val download = pendingDownload.also { pendingDownload = null } ?: return
        if (uri == null) {
            closeQuietly(download.body)
            onNotice("Download cancelled.")
            return
        }
        downloadBusy = true
        activeDownload = download
        onNotice("Saving download…")
        try {
            ioExecutor.execute {
                val outcome = copyBounded(download, uri)
                activeDownload = null
                activity.runOnUiThread {
                    downloadBusy = false
                    if (outcome.startsWith("Download saved") && download.saveInHistory) {
                        runCatching { onDownloadSaved(uri.toString(), download.filename) }
                    }
                    onNotice(outcome)
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            activeDownload = null
            downloadBusy = false
            closeQuietly(download.body)
            onNotice("Download was cancelled because the browser is closing.")
        }
    }

    private fun copyBounded(download: PendingDownload, destination: Uri): String {
        var bytes = 0L
        return try {
            val output = activity.contentResolver.openOutputStream(destination, "w")
                ?: throw IllegalStateException("Destination could not be opened")
            download.body.use { input ->
                output.use { sink ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        bytes += count
                        if (bytes > MAX_DOWNLOAD_BYTES) throw IllegalStateException("Download exceeds the supported size limit")
                        sink.write(buffer, 0, count)
                    }
                    sink.flush()
                }
            }
            "Download saved (${humanBytes(bytes)})."
        } catch (error: Exception) {
            runCatching { activity.contentResolver.delete(destination, null, null) }
            if (error.message == "Download exceeds the supported size limit") "Download exceeds the 512 MB limit."
            else "Download could not be saved."
        } finally {
            closeQuietly(download.body)
        }
    }

    private fun safeFilename(response: WebResponse): String {
        val disposition = response.headers.entries.firstOrNull { it.key.equals("content-disposition", true) }?.value.orEmpty()
        val fromHeader = Regex("(?i)(?:^|;)\\s*filename\\*?=(?:UTF-8''|\")?([^;\"]+)").find(disposition)?.groupValues?.getOrNull(1)
        val candidate = fromHeader?.trim()?.let { Uri.decode(it) }
            ?: Uri.parse(response.uri).lastPathSegment
            ?: "download"
        val basename = candidate.substringAfterLast('/').substringAfterLast('\\')
        val sanitized = basename.replace(Regex("[^A-Za-z0-9._-]"), "_").trim('.', '_').take(MAX_FILENAME_CHARS)
        return sanitized.ifBlank { "download" }
    }

    private fun safeMimeType(response: WebResponse): String {
        val header = response.headers.entries.firstOrNull { it.key.equals("content-type", true) }?.value
            ?.substringBefore(';')?.trim()?.lowercase()
        return header?.takeIf { MIME_TYPE.matches(it) } ?: "application/octet-stream"
    }

    private fun humanBytes(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "${bytes / 1024} KB"
        else -> "${bytes / (1024 * 1024)} MB"
    }

    private fun closeQuietly(stream: InputStream) { runCatching { stream.close() } }

    private fun finishSingleFile(uri: Uri?) {
        val pending = takePendingFile() ?: return
        if (uri == null) pending.result.complete(pending.prompt.dismiss())
        else pending.result.complete(pending.prompt.confirm(activity.applicationContext, uri))
    }

    private fun finishMultipleFiles(uris: List<Uri>) {
        val pending = takePendingFile() ?: return
        if (uris.isEmpty()) pending.result.complete(pending.prompt.dismiss())
        else pending.result.complete(pending.prompt.confirm(activity.applicationContext, uris.toTypedArray()))
    }

    private fun finishFolder(uri: Uri?) {
        val pending = takePendingFile() ?: return
        if (uri == null) pending.result.complete(pending.prompt.dismiss())
        else pending.result.complete(pending.prompt.confirm(activity.applicationContext, uri))
    }

    private fun takePendingFile(): PendingFile? = pendingFile.also { pendingFile = null }

    private fun flatten(choices: Array<GeckoSession.PromptDelegate.ChoicePrompt.Choice>): List<Pair<GeckoSession.PromptDelegate.ChoicePrompt.Choice, String>> {
        val output = mutableListOf<Pair<GeckoSession.PromptDelegate.ChoicePrompt.Choice, String>>()
        fun visit(items: Array<GeckoSession.PromptDelegate.ChoicePrompt.Choice>, prefix: String) {
            items.forEach { choice ->
                if (choice.disabled || choice.separator) return@forEach
                val nested = choice.items
                if (nested.isNullOrEmpty()) output += choice to (prefix + choice.label)
                else visit(nested, prefix + choice.label + " › ")
            }
        }
        visit(choices, "")
        return output
    }

    private fun <T> showResult(show: (GeckoResult<T>) -> Unit): GeckoResult<T> {
        val result = GeckoResult<T>()
        try {
            show(result)
        } catch (error: RuntimeException) {
            // Activity teardown is surfaced to Gecko rather than leaving the page waiting forever.
            result.completeExceptionally(error)
        }
        return result
    }

    private class CreateFileContract : ActivityResultContract<Pair<String, String>, Uri?>() {
        override fun createIntent(context: Context, input: Pair<String, String>): Intent = Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(input.second)
            .putExtra(Intent.EXTRA_TITLE, input.first)

        override fun parseResult(resultCode: Int, intent: Intent?): Uri? =
            if (resultCode == android.app.Activity.RESULT_OK) intent?.data else null
    }

    private fun <T> complete(result: GeckoResult<T>, value: T) {
        try {
            result.complete(value)
        } catch (_: IllegalStateException) {
            // A late dialog callback can arrive after Gecko has dismissed the prompt.
        }
    }


    companion object {
        private const val MAX_DOWNLOAD_BYTES = 512L * 1024L * 1024L
        private const val MAX_FILENAME_CHARS = 120
        private val MIME_TYPE = Regex("^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")
    }
}
