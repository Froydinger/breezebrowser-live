package com.froydinger.breeze.browser

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.froydinger.breeze.data.CredentialVault
import com.froydinger.breeze.data.CredentialVaultAuthentication
import com.froydinger.breeze.data.VaultCredential
import org.mozilla.geckoview.Autocomplete
import org.mozilla.geckoview.GeckoResult
import org.mozilla.geckoview.GeckoSession
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Local-only Gecko login storage. It never opens the vault during page loading: an explicit call
 * to [unlockForSite] must authenticate the user for the exact active HTTPS origin first.
 *
 * Attach this instance to GeckoRuntime as its Autocomplete.StorageDelegate. Keep active page
 * context current with [updatePageContext], and call [close] when the owning activity is destroyed.
 */
class BrowserCredentials(
    private val activity: FragmentActivity,
    private val onNotice: (String) -> Unit = {},
) : Autocomplete.StorageDelegate {
    private data class ApprovedSave(
        val session: GeckoSession,
        val origin: String,
        val username: String,
        val password: String,
        val expiresAt: Long,
    )

    private val vault = CredentialVault(activity.applicationContext)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var activeSession: GeckoSession? = null
    private var activeOrigin: String? = null
    private var activePrivate = true
    private var unlockedOrigin: String? = null
    private var unlockedSession: GeckoSession? = null
    private var unlockedEntries: List<VaultCredential> = emptyList()
    private var unlockedUntil = 0L
    private var approvedSave: ApprovedSave? = null
    private var authInProgress = false
    private var keyguardAction: (() -> Unit)? = null
    private var keyguardError: (() -> Unit)? = null
    private val expireAction = Runnable { clearUnlock() }
    private val clearApprovedSaveAction = Runnable { approvedSave = null }

    private val keyguardLauncher: ActivityResultLauncher<Intent> =
        activity.activityResultRegistry.register(
            "breeze-login-vault-keyguard", activity, ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            authInProgress = false
            val action = keyguardAction.also { keyguardAction = null }
            val error = keyguardError.also { keyguardError = null }
            if (result.resultCode == Activity.RESULT_OK) action?.invoke() else error?.invoke()
        }

    private val lifecycleObserver = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_STOP && !authInProgress) {
            clearUnlock()
            clearApprovedSave()
        }
    }

    init {
        activity.lifecycle.addObserver(lifecycleObserver)
    }

    /** Keep this synchronized with tab selection, navigation, and private-tab state. */
    fun updatePageContext(session: GeckoSession?, url: String?, isPrivate: Boolean) {
        val nextOrigin = httpsOrigin(url)
        if (session !== activeSession || nextOrigin != activeOrigin || isPrivate != activePrivate) {
            clearUnlock()
            clearApprovedSave()
        }
        activeSession = session
        activeOrigin = nextOrigin
        activePrivate = isPrivate
    }

    /** Clear decrypted session credentials, e.g. when leaving the password page or browser screen. */
    fun clearUnlock() {
        main.removeCallbacks(expireAction)
        unlockedEntries = emptyList()
        unlockedOrigin = null
        unlockedSession = null
        unlockedUntil = 0L
    }

    /**
     * Explicit user action from the page tools. Authenticates, then opens an exact-origin cache for
     * at most 30 seconds. HTTP pages and private tabs fail closed.
     */
    fun unlockForSite(origin: String, onReady: (Boolean) -> Unit) {
        val normalized = httpsOrigin(origin)
        val sessionAtStart = activeSession
        if (activePrivate || sessionAtStart == null || normalized == null || normalized != activeOrigin) {
            clearUnlock()
            onReady(false)
            return
        }
        authorize(
            onSuccess = {
                try {
                    if (activePrivate || activeOrigin != normalized || activeSession !== sessionAtStart) {
                        clearUnlock()
                        onReady(false)
                        return@authorize
                    }
                    val entries = vault.readAfterAuthentication().filter { entry ->
                        httpsOrigin(entry.origin) == normalized
                    }
                    unlockedEntries = entries
                    unlockedOrigin = normalized
                    unlockedSession = activeSession
                    unlockedUntil = SystemClock.elapsedRealtime() + UNLOCK_WINDOW_MS
                    scheduleExpiration()
                    onReady(true)
                } catch (_: Exception) {
                    clearUnlock()
                    onNotice("Saved logins could not be opened.")
                    onReady(false)
                }
            },
            onError = { message -> onNotice(message); onReady(false) },
        )
    }

    /** Passive Gecko fetches only see an already-unlocked exact-origin cache; no file/key access here. */
    override fun onLoginFetch(domain: String): GeckoResult<Array<Autocomplete.LoginEntry>> {
        val origin = validUnlockedOrigin() ?: return emptyLogins()
        if (activePrivate || unlockedSession !== activeSession || origin != activeOrigin) return emptyLogins()
        if (domainHost(domain) != Uri.parse(origin).host?.lowercase()) return emptyLogins()
        val logins = unlockedEntries
            .filter { httpsOrigin(it.origin) == origin }
            .map { entry ->
                Autocomplete.LoginEntry.Builder()
                    .guid(entry.id)
                    .origin(entry.origin)
                    .username(entry.username)
                    .password(entry.password)
                    .build()
            }
            .toTypedArray()
        return GeckoResult.fromValue(logins)
    }

    /** Gecko's domainless fetch must never enumerate the local vault. */
    override fun onLoginFetch(): GeckoResult<Array<Autocomplete.LoginEntry>> = emptyLogins()

    /** Accepts storage writes only when the matching Gecko save prompt was approved and authenticated. */
    override fun onLoginSave(login: Autocomplete.LoginEntry) {
        val approved = approvedSave ?: return
        if (SystemClock.elapsedRealtime() > approved.expiresAt || activePrivate ||
            activeOrigin != approved.origin || activeSession !== approved.session ||
            httpsOrigin(login.origin) != approved.origin || login.username != approved.username || login.password != approved.password
        ) {
            approvedSave = null
            return
        }
        clearApprovedSave()
        io.execute {
            try {
                val existing = vault.readAfterAuthentication().toMutableList()
                val same = existing.indexOfFirst { it.origin == approved.origin && it.username == approved.username }
                val id = login.guid?.takeIf(String::isNotBlank)
                    ?: existing.getOrNull(same)?.id
                    ?: UUID.randomUUID().toString()
                val row = VaultCredential(id, approved.origin, approved.username, approved.password)
                if (same >= 0) existing[same] = row else existing.add(row)
                vault.writeAfterAuthentication(existing)
                main.post {
                    if (!activePrivate && activeOrigin == approved.origin && unlockedSession === activeSession) {
                        unlockedEntries = existing.filter { httpsOrigin(it.origin) == approved.origin }
                        unlockedUntil = SystemClock.elapsedRealtime() + UNLOCK_WINDOW_MS
                        scheduleExpiration()
                    }
                    onNotice("Login saved in the local password vault.")
                }
            } catch (_: Exception) {
                main.post { onNotice("Login could not be saved in the local password vault.") }
            }
        }
    }

    /** No usage telemetry or credential strings are logged. */
    override fun onLoginUsed(login: Autocomplete.LoginEntry, usedFields: Int) = Unit

    /** Native, explicit account choice. Each candidate is rechecked against the unlocked vault. */
    fun onLoginSelect(
        session: GeckoSession,
        request: GeckoSession.PromptDelegate.AutocompleteRequest<Autocomplete.LoginSelectOption>,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val origin = validUnlockedOrigin()
        if (origin == null || session !== activeSession || unlockedSession !== session || activePrivate || activeOrigin != origin) {
            return GeckoResult.fromValue(request.dismiss())
        }
        val allowed = unlockedEntries.associateBy { Triple(it.id, it.username, it.password) }
        val options = request.options.filter { option ->
            val login = option.value
            httpsOrigin(login.origin) == origin && allowed.containsKey(Triple(login.guid.orEmpty(), login.username, login.password))
        }
        if (options.isEmpty()) return GeckoResult.fromValue(request.dismiss())

        val result = GeckoResult<GeckoSession.PromptDelegate.PromptResponse>()
        val labels = options.map { it.value.username.ifBlank { "Saved login" } }.toTypedArray()
        try {
            AlertDialog.Builder(activity)
                .setTitle("Saved logins · ${Uri.parse(origin).host}")
                .setItems(labels) { _, which ->
                    val selected = options.getOrNull(which)
                    if (validUnlockedOrigin() != origin || session !== activeSession || activePrivate || selected == null) {
                        result.complete(request.dismiss())
                    } else {
                        result.complete(request.confirm(selected))
                    }
                }
                .setOnCancelListener { completeDismiss(result, request.dismiss()) }
                .show()
        } catch (_: RuntimeException) {
            result.complete(request.dismiss())
        }
        return result
    }

    /** User must approve the Gecko save prompt and complete device authentication before storage. */
    fun onLoginSave(
        session: GeckoSession,
        request: GeckoSession.PromptDelegate.AutocompleteRequest<Autocomplete.LoginSaveOption>,
    ): GeckoResult<GeckoSession.PromptDelegate.PromptResponse> {
        val origin = activeOrigin
        val candidate = request.options.firstOrNull()?.value
            ?: return GeckoResult.fromValue(request.dismiss())
        if (session !== activeSession || activePrivate || origin == null || !isValidSameOriginLogin(candidate, origin)) {
            return GeckoResult.fromValue(request.dismiss())
        }
        val result = GeckoResult<GeckoSession.PromptDelegate.PromptResponse>()
        try {
            AlertDialog.Builder(activity)
                .setTitle("Save this login?")
                .setMessage("Save ${candidate.username.ifBlank { "this account" }} for ${Uri.parse(origin).host} in the on-device vault?")
                .setPositiveButton("Save") { _, _ ->
                    authorize(
                        onSuccess = {
                            if (activePrivate || session !== activeSession || activeOrigin != origin) {
                                result.complete(request.dismiss())
                            } else {
                                approvedSave = ApprovedSave(
                                    session = session,
                                    origin = origin,
                                    username = candidate.username,
                                    password = candidate.password,
                                    expiresAt = SystemClock.elapsedRealtime() + APPROVAL_WINDOW_MS,
                                )
                                main.removeCallbacks(clearApprovedSaveAction)
                                main.postDelayed(clearApprovedSaveAction, APPROVAL_WINDOW_MS)
                                val option = request.options.firstOrNull { it.value === candidate } ?: request.options.first()
                                result.complete(request.confirm(option))
                            }
                        },
                        onError = { result.complete(request.dismiss()); onNotice("Password-vault authentication was not completed.") },
                    )
                }
                .setNegativeButton("Not now") { _, _ -> result.complete(request.dismiss()) }
                .setOnCancelListener { completeDismiss(result, request.dismiss()) }
                .show()
        } catch (_: RuntimeException) {
            result.complete(request.dismiss())
        }
        return result
    }

    fun close() {
        clearUnlock()
        clearApprovedSave()
        activity.lifecycle.removeObserver(lifecycleObserver)
        io.shutdownNow()
    }

    private fun authorize(onSuccess: () -> Unit, onError: (String) -> Unit) {
        if (authInProgress) {
            onError("Another password-vault authentication is already open.")
            return
        }
        authInProgress = true
        CredentialVaultAuthentication.authenticate(
            activity = activity,
            onAuthenticated = { authInProgress = false; onSuccess() },
            onDeviceCredentialRequired = { intent ->
                keyguardAction = { authInProgress = false; onSuccess() }
                keyguardError = { authInProgress = false; onError("Device authentication was cancelled.") }
                try {
                    keyguardLauncher.launch(intent)
                } catch (_: RuntimeException) {
                    keyguardAction = null; keyguardError = null; authInProgress = false
                    onError("Device authentication could not start.")
                }
            },
            onError = { authInProgress = false; onError(it) },
        )
    }

    private fun clearApprovedSave() {
        main.removeCallbacks(clearApprovedSaveAction)
        approvedSave = null
    }

    private fun validUnlockedOrigin(): String? {
        val origin = unlockedOrigin ?: return null
        if (SystemClock.elapsedRealtime() >= unlockedUntil || activePrivate || origin != activeOrigin || unlockedSession !== activeSession) {
            clearUnlock()
            return null
        }
        return origin
    }

    private fun scheduleExpiration() {
        main.removeCallbacks(expireAction)
        main.postDelayed(expireAction, UNLOCK_WINDOW_MS)
    }

    private fun isValidSameOriginLogin(login: Autocomplete.LoginEntry?, origin: String): Boolean {
        if (login == null || login.username.isBlank() || login.password.isEmpty() || httpsOrigin(login.origin) != origin) return false
        val actionOrigin = login.formActionOrigin?.takeIf(String::isNotBlank)
        return actionOrigin == null || httpsOrigin(actionOrigin) == origin
    }

    private fun httpsOrigin(value: String?): String? {
        if (value.isNullOrBlank()) return null
        val normalized = runCatching { vault.normalizeOrigin(value) }.getOrNull() ?: return null
        return normalized.takeIf { it.startsWith("https://") }
    }

    private fun domainHost(value: String): String? {
        if (value.isBlank() || value.contains('/') || value.contains('@')) return null
        val uri = Uri.parse("https://$value")
        if (uri.path.orEmpty().isNotEmpty() || uri.query != null || uri.fragment != null || uri.port != -1) return null
        return uri.host?.lowercase()
    }

    private fun emptyLogins() = GeckoResult.fromValue(emptyArray<Autocomplete.LoginEntry>())

    private fun completeDismiss(
        result: GeckoResult<GeckoSession.PromptDelegate.PromptResponse>,
        response: GeckoSession.PromptDelegate.PromptResponse,
    ) {
        try { result.complete(response) } catch (_: IllegalStateException) { }
    }

    companion object {
        private const val UNLOCK_WINDOW_MS = 30_000L
        private const val APPROVAL_WINDOW_MS = 30_000L
    }
}
