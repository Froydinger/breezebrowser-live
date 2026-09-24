package com.froydinger.breeze.browser

import android.Manifest
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.net.Uri
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebChromeClient.FileChooserParams
import android.webkit.WebView
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import java.util.concurrent.atomic.AtomicLong
import android.os.Handler
import android.os.Looper

/**
 * WebView's native site-prompt and file-chooser adapter. Build during Activity.onCreate, before
 * STARTED, and install [client] on each browser WebView. The context resolver must return the
 * currently selected browser page so callbacks from stale or background tabs fail closed.
 *
 * Only geolocation, camera and microphone are supported. Media requests are origin-bound, require
 * an explicit site prompt plus Android runtime permission, and are revalidated after the system
 * prompt returns. Display/screen capture, MIDI, protected media and unknown resources are denied.
 * File selection is user initiated through SAF; capture requests, folder selection, and unknown
 * chooser modes are denied. Selected files are returned only to the same still-current origin.
 */
class ChromiumWebPrompts(
    private val activity: FragmentActivity,
    private val resolveCurrentPage: () -> PageContext?,
    private val onNotice: (String) -> Unit = {},
) {
    data class PageContext(val url: String, val privateMode: Boolean)

    private data class RuntimeRequest(
        val origin: String,
        val privateMode: Boolean,
        val permissions: Set<String>,
        val finish: (Boolean) -> Unit,
    )

    private data class PendingFile(
        val callback: ValueCallback<Array<Uri>>,
        val origin: String,
        val privateMode: Boolean,
    )

    private val key = "breeze-chromium-prompts-${activity.javaClass.name}-${keys.incrementAndGet()}"
    private var closed = false
    private var runtimeRequest: RuntimeRequest? = null
    private var pendingMediaRequest: PermissionRequest? = null
    private var pendingFile: PendingFile? = null
    private var resumeObserver: LifecycleEventObserver? = null
    private var resumeTimeout: Runnable? = null
    private var waitingPermissionResult: Map<String, Boolean>? = null
    private val main = Handler(Looper.getMainLooper())
    private val dialogs = mutableSetOf<AlertDialog>()

    private val runtimePermissions: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            "$key-android-permissions", activity, ActivityResultContracts.RequestMultiplePermissions(),
        ) { result -> finishRuntimePermissionRequest(result) }

    private val singleFile: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            "$key-file-single", activity, ActivityResultContracts.OpenDocument(),
        ) { uri -> finishFileChooser(uri?.let { arrayOf(it) }) }

    private val multipleFiles: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            "$key-file-multiple", activity, ActivityResultContracts.OpenMultipleDocuments(),
        ) { uris -> finishFileChooser(uris.toTypedArray().takeIf { it.isNotEmpty() }) }

    val client: WebChromeClient = object : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) {
            handleMediaRequest(request)
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest) {
            // WebView may cancel while the site prompt or Android dialog is open. Runtime Android
            // permission UI cannot be programmatically cancelled; its callback is rejected when it
            // returns because the owning request no longer matches.
            if (pendingMediaRequest === request) {
                // Chromium has already cancelled this callback; drop our wait state without
                // attempting a second grant/deny on the cancelled PermissionRequest.
                pendingMediaRequest = null
                runtimeRequest = null
                clearResumeWait()
            }
        }

        override fun onGeolocationPermissionsShowPrompt(origin: String, callback: android.webkit.GeolocationPermissions.Callback) {
            handleGeolocationRequest(origin) { allowed -> callback.invoke(origin, allowed, false) }
        }

        override fun onShowFileChooser(
            webView: WebView,
            filePathCallback: ValueCallback<Array<Uri>>,
            fileChooserParams: FileChooserParams,
        ): Boolean = handleFileChooser(filePathCallback, fileChooserParams)
    }

    fun close() {
        if (closed) return
        closed = true
        val activeRuntime = runtimeRequest
        runtimeRequest = null
        if (activeRuntime != null) activeRuntime.finish(false) else pendingMediaRequest?.deny()
        pendingMediaRequest = null
        waitingPermissionResult = null
        clearResumeWait()
        pendingFile?.callback?.onReceiveValue(null)
        pendingFile = null
        dialogs.toList().forEach { runCatching { it.cancel() } }
        dialogs.clear()
    }

    private fun handleMediaRequest(request: PermissionRequest) {
        if (closed || runtimeRequest != null || pendingMediaRequest != null || activity.lifecycle.currentState < Lifecycle.State.RESUMED) {
            request.deny()
            return
        }
        val context = currentContext() ?: run { request.deny(); return }
        pendingMediaRequest = request
        val origin = webOrigin(request.origin.toString())
        if (origin == null || webOrigin(context.url) != origin) {
            pendingMediaRequest = null
            request.deny()
            return
        }
        val resources = request.resources?.toSet().orEmpty()
        if (resources.isEmpty() || resources.any { it !in MEDIA_RESOURCES }) {
            pendingMediaRequest = null
            request.deny()
            return
        }
        val wantsCamera = PermissionRequest.RESOURCE_VIDEO_CAPTURE in resources
        val wantsMicrophone = PermissionRequest.RESOURCE_AUDIO_CAPTURE in resources
        val required = buildSet {
            if (wantsCamera) add(Manifest.permission.CAMERA)
            if (wantsMicrophone) add(Manifest.permission.RECORD_AUDIO)
        }
        val labels = buildList {
            if (wantsCamera) add("camera")
            if (wantsMicrophone) add("microphone")
        }.joinToString(" and ")
        val host = Uri.parse(origin).host ?: run { pendingMediaRequest = null; request.deny(); return }
        showConsent("Allow $labels?", "$host wants to use your $labels.") { consented ->
            if (pendingMediaRequest !== request) return@showConsent
            if (!consented || !isCurrent(origin, context.privateMode)) {
                pendingMediaRequest = null
                request.deny()
                return@showConsent
            }
            requestRuntimePermissions(origin, context.privateMode, required) { granted ->
                if (pendingMediaRequest !== request) return@requestRuntimePermissions
                if (!granted || !isCurrent(origin, context.privateMode)) {
                    pendingMediaRequest = null
                    request.deny()
                } else {
                    pendingMediaRequest = null
                    val allowedResources = buildList {
                        if (wantsCamera) add(PermissionRequest.RESOURCE_VIDEO_CAPTURE)
                        if (wantsMicrophone) add(PermissionRequest.RESOURCE_AUDIO_CAPTURE)
                    }.toTypedArray()
                    request.grant(allowedResources)
                }
            }
        }
    }

    private fun handleGeolocationRequest(originValue: String, finish: (Boolean) -> Unit) {
        if (closed || runtimeRequest != null || activity.lifecycle.currentState < Lifecycle.State.RESUMED) {
            finish(false)
            return
        }
        val context = currentContext()
        val origin = webOrigin(originValue)
        if (context == null || origin == null || webOrigin(context.url) != origin) {
            finish(false)
            return
        }
        val host = Uri.parse(origin).host ?: run { finish(false); return }
        showConsent("Allow location?", "$host wants to access this device’s location.") { consented ->
            if (!consented || !isCurrent(origin, context.privateMode)) {
                finish(false)
                return@showConsent
            }
            requestRuntimePermissions(origin, context.privateMode, LOCATION_PERMISSIONS) { granted ->
                finish(granted && isCurrent(origin, context.privateMode))
            }
        }
    }

    private fun handleFileChooser(callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
        if (closed || activity.lifecycle.currentState < Lifecycle.State.RESUMED) {
            callback.onReceiveValue(null)
            return true
        }
        if (params.isCaptureEnabled) {
            callback.onReceiveValue(null)
            onNotice("Direct camera or microphone capture from file upload is not supported.")
            return true
        }
        val mode = params.mode
        if (mode != FileChooserParams.MODE_OPEN && mode != FileChooserParams.MODE_OPEN_MULTIPLE) {
            callback.onReceiveValue(null)
            return true
        }
        val context = currentContext()
        val origin = context?.let { webOrigin(it.url) }
        if (context == null || origin == null) {
            callback.onReceiveValue(null)
            return true
        }
        pendingFile?.callback?.onReceiveValue(null)
        pendingFile = PendingFile(callback, origin, context.privateMode)
        val mimeTypes = normalizedMimeTypes(params.acceptTypes)
        try {
            if (mode == FileChooserParams.MODE_OPEN_MULTIPLE) multipleFiles.launch(mimeTypes)
            else singleFile.launch(mimeTypes)
        } catch (_: RuntimeException) {
            finishFileChooser(null)
            onNotice("File picker is unavailable right now.")
        }
        return true
    }

    private fun finishFileChooser(uris: Array<Uri>?) {
        val pending = pendingFile.also { pendingFile = null } ?: return
        val valid = !closed && isCurrent(pending.origin, pending.privateMode)
        pending.callback.onReceiveValue(uris?.takeIf { valid })
    }

    private fun normalizedMimeTypes(raw: Array<String>?): Array<String> {
        val values = raw.orEmpty().flatMap { it.split(',') }.map { it.trim().lowercase() }
            .filter { it == "*/*" || MIME_TYPE.matches(it) }
            .distinct().take(MAX_ACCEPT_TYPES)
        return if (values.isEmpty()) arrayOf("*/*") else values.toTypedArray()
    }

    private fun requestRuntimePermissions(
        origin: String,
        privateMode: Boolean,
        requested: Set<String>,
        finish: (Boolean) -> Unit,
    ) {
        if (closed || runtimeRequest != null || !isCurrent(origin, privateMode) || requested.isEmpty() ||
            requested.any { it !in SUPPORTED_ANDROID_PERMISSIONS }
        ) {
            finish(false)
            return
        }
        runtimeRequest = RuntimeRequest(origin, privateMode, requested, finish)
        val missing = missingPermissions(requested)
        if (missing.isEmpty()) {
            completeRuntimeRequest(true)
            return
        }
        try {
            runtimePermissions.launch(missing)
        } catch (_: RuntimeException) {
            completeRuntimeRequest(false)
            onNotice("Android permission request could not be opened.")
        }
    }

    private fun missingPermissions(requested: Set<String>): Array<String> {
        val missing = requested.filterNot { it in LOCATION_PERMISSIONS }.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }.toMutableSet()
        if (requested.any { it in LOCATION_PERMISSIONS } &&
            LOCATION_PERMISSIONS.none { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        ) missing.addAll(LOCATION_PERMISSIONS)
        return missing.toTypedArray()
    }

    private fun finishRuntimePermissionRequest(result: Map<String, Boolean>) {
        val request = runtimeRequest ?: return
        waitingPermissionResult = result
        if (closed || activity.lifecycle.currentState == Lifecycle.State.DESTROYED) {
            completeRuntimeRequest(false)
        } else if (activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            completeRuntimeRequest(hasPermissions(request, result))
        } else if (resumeObserver == null) {
            val observer = LifecycleEventObserver { _, event ->
                when (event) {
                    Lifecycle.Event.ON_RESUME -> {
                        val active = runtimeRequest
                        val waiting = waitingPermissionResult
                        if (active != null && waiting != null) completeRuntimeRequest(hasPermissions(active, waiting))
                    }
                    Lifecycle.Event.ON_DESTROY -> completeRuntimeRequest(false)
                    else -> Unit
                }
            }
            resumeObserver = observer
            activity.lifecycle.addObserver(observer)
            val timeout = Runnable { completeRuntimeRequest(false) }
            resumeTimeout = timeout
            main.postDelayed(timeout, RESUME_RESULT_TIMEOUT_MS)
        }
    }

    private fun hasPermissions(request: RuntimeRequest, result: Map<String, Boolean>): Boolean {
        if (!isCurrent(request.origin, request.privateMode)) return false
        val locationRequested = request.permissions.any { it in LOCATION_PERMISSIONS }
        val otherGranted = request.permissions.filterNot { it in LOCATION_PERMISSIONS }.all {
            result[it] == true || activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
        val locationGranted = !locationRequested || LOCATION_PERMISSIONS.any {
            result[it] == true || activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        }
        return otherGranted && locationGranted
    }

    private fun completeRuntimeRequest(granted: Boolean) {
        val request = runtimeRequest ?: return
        runtimeRequest = null
        waitingPermissionResult = null
        clearResumeWait()
        val valid = granted && !closed && activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
            isCurrent(request.origin, request.privateMode)
        request.finish(valid)
    }

    private fun showConsent(title: String, message: String, onResult: (Boolean) -> Unit) {
        if (closed || activity.lifecycle.currentState < Lifecycle.State.RESUMED) {
            onResult(false)
            return
        }
        var resolved = false
        var dialog: AlertDialog? = null
        fun finish(allow: Boolean) {
            if (resolved) return
            resolved = true
            dialog?.let(dialogs::remove)
            onResult(allow)
        }
        try {
            dialog = AlertDialog.Builder(activity)
                .setTitle(title)
                .setMessage(message)
                .setPositiveButton("Allow") { _, _ -> finish(true) }
                .setNegativeButton("Don’t allow") { _, _ -> finish(false) }
                .setOnCancelListener { finish(false) }
                .create()
            dialog?.show()
            dialog?.let(dialogs::add)
        } catch (_: RuntimeException) {
            dialog?.let { dialogs.remove(it); runCatching { it.dismiss() } }
            finish(false)
        }
    }

    private fun currentContext(): PageContext? {
        if (closed || activity.lifecycle.currentState < Lifecycle.State.RESUMED) return null
        return runCatching(resolveCurrentPage).getOrNull()
    }

    private fun isCurrent(origin: String, privateMode: Boolean): Boolean {
        val context = currentContext() ?: return false
        return context.privateMode == privateMode && webOrigin(context.url) == origin
    }

    private fun webOrigin(value: String?): String? {
        if (value.isNullOrBlank()) return null
        val uri = runCatching { Uri.parse(value.trim()) }.getOrNull() ?: return null
        val scheme = uri.scheme?.lowercase() ?: return null
        val host = uri.host?.lowercase()?.takeIf(String::isNotBlank) ?: return null
        if (scheme != "https" && !(scheme == "http" && host in LOOPBACK_HOSTS)) return null
        if (uri.userInfo != null) return null
        val defaultPort = (scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)
        val port = if (uri.port > 0 && !defaultPort) ":${uri.port}" else ""
        return "$scheme://$host$port"
    }

    private fun clearResumeWait() {
        resumeObserver?.let(activity.lifecycle::removeObserver)
        resumeObserver = null
        resumeTimeout?.let(main::removeCallbacks)
        resumeTimeout = null
    }


    private companion object {
        val keys = AtomicLong()
        val MEDIA_RESOURCES = setOf(PermissionRequest.RESOURCE_VIDEO_CAPTURE, PermissionRequest.RESOURCE_AUDIO_CAPTURE)
        val LOCATION_PERMISSIONS = setOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
        val SUPPORTED_ANDROID_PERMISSIONS = LOCATION_PERMISSIONS + setOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
        val MIME_TYPE = Regex("^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$")
        val LOOPBACK_HOSTS = setOf("localhost", "127.0.0.1", "::1")
        const val MAX_ACCEPT_TYPES = 16
        const val RESUME_RESULT_TIMEOUT_MS = 10_000L
    }
}
