package com.froydinger.breeze.browser

import android.Manifest
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicLong

/**
 * Bridges Gecko site permission requests to Android runtime permissions and an origin-specific
 * consent prompt. Decisions are held by Gecko only; this adapter keeps no permission store.
 */
class BrowserPermissions(
    private val activity: FragmentActivity,
    private val onNotice: (String) -> Unit = {},
    private val resolveContext: (GeckoSession) -> PageContext?,
) : GeckoSession.PermissionDelegate {
    data class PageContext(val url: String, val privateMode: Boolean)

    private data class PendingAndroid(
        val session: GeckoSession,
        val origin: String,
        val privateMode: Boolean,
        val requested: Set<String>,
        val callback: GeckoSession.PermissionDelegate.Callback,
    )

    private val key = "breeze-gecko-permissions-${activity.javaClass.name}-${keys.incrementAndGet()}"
    private var pendingAndroid: PendingAndroid? = null
    private var pendingAndroidResult: Map<String, Boolean>? = null
    private var resumeObserver: LifecycleEventObserver? = null
    private var resumeTimeout: Runnable? = null
    private var closed = false
    private val dialogs = mutableSetOf<AlertDialog>()
    private val main = Handler(Looper.getMainLooper())
    private val androidPermissions: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            key, activity, ActivityResultContracts.RequestMultiplePermissions(),
        ) { result -> finishAndroidRequest(result) }

    override fun onAndroidPermissionsRequest(
        session: GeckoSession,
        permissions: Array<String>?,
        callback: GeckoSession.PermissionDelegate.Callback,
    ) {
        val context = currentContext(session)
        val origin = context?.let { webOrigin(it.url) }
        val rawRequested = permissions?.toSet().orEmpty()
        val requested = normalizeAndroidPermissions(rawRequested)
        if (closed || context == null || origin == null || requested == null || requested.isEmpty() || pendingAndroid != null
        ) {
            callback.reject()
            return
        }

        val pending = PendingAndroid(session, origin, context.privateMode, requested, callback)
        pendingAndroid = pending
        val missing = missingAndroidPermissions(requested)
        if (missing.isEmpty()) {
            finishAndroidRequest(requested.associateWith { permission ->
                activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            })
            return
        }
        try {
            androidPermissions.launch(missing)
        } catch (_: RuntimeException) {
            pendingAndroid = null
            callback.reject()
            onNotice("Android permission request could not be opened.")
        }
    }

    override fun onContentPermissionRequest(
        session: GeckoSession,
        perm: GeckoSession.PermissionDelegate.ContentPermission,
    ): GeckoResult<Int> {
        val denied = GeckoSession.PermissionDelegate.ContentPermission.VALUE_DENY
        val allowed = GeckoSession.PermissionDelegate.ContentPermission.VALUE_ALLOW
        val current = currentContext(session)
        val requestOrigin = webOrigin(perm.uri)
        val result = GeckoResult<Int>()

        if (closed || current == null || requestOrigin == null || webOrigin(current.url) != requestOrigin ||
            current.privateMode != perm.privateMode
        ) {
            result.complete(denied)
            return result
        }
        if (perm.value == denied) {
            result.complete(denied)
            return result
        }
        if (perm.value == allowed) {
            result.complete(allowed)
            return result
        }

        // Geolocation is the only non-media content permission this adapter exposes. In
        // particular, do not silently grant desktop notifications, persistent storage, XR,
        // local-network access, or other permissions without their own user-facing contracts.
        if (perm.permission != GeckoSession.PermissionDelegate.PERMISSION_GEOLOCATION) {
            result.complete(denied)
            return result
        }

        val host = Uri.parse(requestOrigin).host ?: run {
            result.complete(denied)
            return result
        }
        showConsent(
            title = "Allow location?",
            message = "$host wants to access this device’s location.",
            afterShown = { perm.notifyShown() },
        ) { consented ->
            if (!consented || !isCurrent(session, requestOrigin, perm.privateMode)) {
                result.complete(denied)
            } else {
                requestLocationPermission(session, requestOrigin, perm.privateMode) { granted ->
                    result.complete(if (granted && isCurrent(session, requestOrigin, perm.privateMode)) allowed else denied)
                }
            }
        }
        return result
    }

    override fun onMediaPermissionRequest(
        session: GeckoSession,
        uri: String,
        video: Array<GeckoSession.PermissionDelegate.MediaSource>?,
        audio: Array<GeckoSession.PermissionDelegate.MediaSource>?,
        callback: GeckoSession.PermissionDelegate.MediaCallback,
    ) {
        val context = currentContext(session)
        val origin = webOrigin(uri)
        val currentOrigin = context?.let { webOrigin(it.url) }
        if (closed || context == null || origin == null || currentOrigin != origin) {
            callback.reject()
            return
        }

        val videoSources = video.orEmpty()
        val audioSources = audio.orEmpty()
        val wantsVideo = video != null
        val wantsAudio = audio != null
        val camera = videoSources.firstOrNull { it.source == GeckoSession.PermissionDelegate.MediaSource.SOURCE_CAMERA }
        val microphone = audioSources.firstOrNull { it.source == GeckoSession.PermissionDelegate.MediaSource.SOURCE_MICROPHONE }
        // Screen capture and device-audio capture need separate, explicit product handling.
        if ((wantsVideo && camera == null) || (wantsAudio && microphone == null) || (!wantsVideo && !wantsAudio)) {
            callback.reject()
            return
        }

        val labels = buildList {
            if (camera != null) add("camera")
            if (microphone != null) add("microphone")
        }.joinToString(" and ")
        val host = Uri.parse(origin).host ?: run { callback.reject(); return }
        showConsent(
            title = "Allow $labels?",
            message = "$host wants to use your $labels.",
        ) { consented ->
            if (!consented || !isCurrent(session, origin, context.privateMode)) {
                callback.reject()
                return@showConsent
            }
            val required = buildSet {
                if (camera != null) add(Manifest.permission.CAMERA)
                if (microphone != null) add(Manifest.permission.RECORD_AUDIO)
            }
            requestAndroidPermissions(session, origin, context.privateMode, required) { granted ->
                if (granted && isCurrent(session, origin, context.privateMode)) callback.grant(camera, microphone)
                else callback.reject()
            }
        }
    }

    /** Reject any Gecko callback that is still pending when the activity is closing. */
    fun close() {
        closed = true
        pendingAndroid?.callback?.reject()
        pendingAndroid = null
        pendingAndroidResult = null
        resumeObserver?.let(activity.lifecycle::removeObserver)
        resumeObserver = null
        resumeTimeout?.let(main::removeCallbacks)
        resumeTimeout = null
        dialogs.toList().forEach { dialog ->
            runCatching { dialog.cancel() }
        }
        dialogs.clear()
    }

    private fun finishAndroidRequest(result: Map<String, Boolean>) {
        val pending = pendingAndroid ?: return
        pendingAndroidResult = result
        if (closed || activity.lifecycle.currentState == Lifecycle.State.DESTROYED) {
            completePendingAndroid(pending, grant = false)
        } else if (activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            completePendingAndroid(pending, grant = androidPermissionsGranted(pending, result))
        } else {
            // Activity Result delivery can precede ON_RESUME. Hold the result briefly so the
            // origin/session check runs against the restored foreground state instead of denying
            // an otherwise valid request merely because the callback arrived early.
            if (resumeObserver == null) {
                val observer = LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_RESUME) {
                        val waiting = pendingAndroid
                        val waitingResult = pendingAndroidResult
                        if (waiting != null && waitingResult != null) {
                            completePendingAndroid(waiting, androidPermissionsGranted(waiting, waitingResult))
                        }
                    } else if (event == Lifecycle.Event.ON_DESTROY) {
                        pendingAndroid?.let { completePendingAndroid(it, grant = false) }
                    }
                }
                resumeObserver = observer
                activity.lifecycle.addObserver(observer)
                val timeout = Runnable {
                    pendingAndroid?.let { completePendingAndroid(it, grant = false) }
                }
                resumeTimeout = timeout
                main.postDelayed(timeout, RESUME_RESULT_TIMEOUT_MS)
            }
        }
    }

    private fun completePendingAndroid(pending: PendingAndroid, grant: Boolean) {
        if (pendingAndroid !== pending) return
        pendingAndroid = null
        pendingAndroidResult = null
        resumeObserver?.let(activity.lifecycle::removeObserver)
        resumeObserver = null
        resumeTimeout?.let(main::removeCallbacks)
        resumeTimeout = null
        val valid = !closed && activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED) &&
            isCurrent(pending.session, pending.origin, pending.privateMode)
        if (grant && valid) pending.callback.grant() else pending.callback.reject()
    }

    private fun androidPermissionsGranted(pending: PendingAndroid, result: Map<String, Boolean>): Boolean {
        if (!isCurrent(pending.session, pending.origin, pending.privateMode)) return false
        val locationRequested = pending.requested.any { it in LOCATION_PERMISSIONS }
        val nonLocationGranted = pending.requested.filterNot { it in LOCATION_PERMISSIONS }.all { permission ->
            result[permission] == true || activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }
        val locationGranted = !locationRequested || LOCATION_PERMISSIONS.any { permission ->
            result[permission] == true || activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }
        return nonLocationGranted && locationGranted
    }

    private fun requestLocationPermission(
        session: GeckoSession,
        origin: String,
        privateMode: Boolean,
        onComplete: (Boolean) -> Unit,
    ) = requestAndroidPermissions(
        session,
        origin,
        privateMode,
        LOCATION_PERMISSIONS,
        onComplete,
    )

    private fun requestAndroidPermissions(
        session: GeckoSession,
        origin: String,
        privateMode: Boolean,
        requested: Set<String>,
        onComplete: (Boolean) -> Unit,
    ) {
        if (closed || !isCurrent(session, origin, privateMode) || pendingAndroid != null ||
            requested.isEmpty() || requested.any { it !in SUPPORTED_ANDROID_PERMISSIONS }
        ) {
            onComplete(false)
            return
        }
        val pending = PendingAndroid(
            session = session,
            origin = origin,
            privateMode = privateMode,
            requested = requested,
            callback = object : GeckoSession.PermissionDelegate.Callback {
                override fun grant() = onComplete(true)
                override fun reject() = onComplete(false)
            },
        )
        pendingAndroid = pending
        val missing = missingAndroidPermissions(requested)
        if (missing.isEmpty()) {
            finishAndroidRequest(requested.associateWith { permission ->
                activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            })
        } else {
            try {
                androidPermissions.launch(missing)
            } catch (_: RuntimeException) {
                pendingAndroid = null
                onComplete(false)
            }
        }
    }

    private fun missingAndroidPermissions(requested: Set<String>): Array<String> {
        val missing = requested.filterNot { it in LOCATION_PERMISSIONS }.filter { permission ->
            activity.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED
        }.toMutableSet()
        if (requested.any { it in LOCATION_PERMISSIONS } &&
            LOCATION_PERMISSIONS.none { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        ) {
            missing.addAll(LOCATION_PERMISSIONS)
        }
        return missing.toTypedArray()
    }

    private fun normalizeAndroidPermissions(requested: Set<String>): Set<String>? {
        if (requested.isEmpty() || requested.any { it !in SUPPORTED_ANDROID_PERMISSIONS }) return null
        return if (requested.any { it in LOCATION_PERMISSIONS }) requested + LOCATION_PERMISSIONS else requested
    }

    private fun showConsent(
        title: String,
        message: String,
        afterShown: (() -> Unit)? = null,
        onResult: (Boolean) -> Unit,
    ) {
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
            afterShown?.invoke()
        } catch (_: RuntimeException) {
            dialog?.let { dialogs.remove(it); runCatching { it.dismiss() } }
            finish(false)
        }
    }

    private fun currentContext(session: GeckoSession): PageContext? {
        if (closed || activity.lifecycle.currentState < Lifecycle.State.RESUMED) return null
        return runCatching { resolveContext(session) }.getOrNull()
    }

    private fun isCurrent(session: GeckoSession, origin: String, privateMode: Boolean): Boolean {
        val context = currentContext(session) ?: return false
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

    companion object {
        private val keys = AtomicLong()
        private val SUPPORTED_ANDROID_PERMISSIONS = setOf(
            Manifest.permission.CAMERA,
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
        private val LOCATION_PERMISSIONS = setOf(
            Manifest.permission.ACCESS_COARSE_LOCATION,
            Manifest.permission.ACCESS_FINE_LOCATION,
        )
        private val LOOPBACK_HOSTS = setOf("localhost", "127.0.0.1", "::1")
        private const val RESUME_RESULT_TIMEOUT_MS = 10_000L
    }
}
