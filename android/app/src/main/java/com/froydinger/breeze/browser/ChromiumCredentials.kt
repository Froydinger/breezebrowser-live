package com.froydinger.breeze.browser

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.webkit.WebView
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.froydinger.breeze.data.CredentialVault
import com.froydinger.breeze.data.CredentialVaultAuthentication
import com.froydinger.breeze.data.VaultCredential
import org.json.JSONObject
import java.net.URI
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Local credential support for Chromium WebView.
 *
 * Integrators call [updatePageContext] before each top-level navigation and when the active tab
 * changes, and wire a native page-tools action to [requestFill]. Only the exact HTTPS origin is
 * permitted in WebView's WebMessageListener allowlist. The page channel can submit a form-derived
 * save candidate, but it cannot enumerate, read, or receive vault entries. Every save candidate
 * requires a native confirmation and device authentication. Filling requires an explicit native
 * account choice after authentication; secrets are inserted into the current page but never sent
 * over the WebMessage channel.
 *
 * Private tabs and HTTP pages have no credential channel. If the installed WebView lacks either
 * required AndroidX WebKit feature, this adapter fails closed.
 */
class ChromiumCredentials(
    private val activity: FragmentActivity,
    private val onNotice: (String) -> Unit = {},
) {
    private data class Page(val webView: WebView, val origin: String, val privateMode: Boolean)

    private val vault = CredentialVault(activity.applicationContext)
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var page: Page? = null
    private var scriptHandler: ScriptHandler? = null
    private var authInProgress = false
    private var interactionInProgress = false
    private var keyguardAction: (() -> Unit)? = null
    private var keyguardError: (() -> Unit)? = null
    private var closed = false

    private val keyguardLauncher: ActivityResultLauncher<Intent> =
        activity.activityResultRegistry.register(
            "breeze-chromium-credential-keyguard-${activity.javaClass.name}",
            activity,
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            authInProgress = false
            val success = keyguardAction.also { keyguardAction = null }
            val failure = keyguardError.also { keyguardError = null }
            if (result.resultCode == Activity.RESULT_OK) success?.invoke() else failure?.invoke()
        }

    private val lifecycleObserver = LifecycleEventObserver { _, event ->
        if (event == Lifecycle.Event.ON_STOP && !authInProgress) clearPage()
    }

    init {
        activity.lifecycle.addObserver(lifecycleObserver)
    }

    /**
     * Call before loading [url]. Re-registering on each navigation makes the WebMessageListener
     * allowlist exact-origin scoped; a cross-origin redirect is denied until the host updates the
     * context for that new top-level origin.
     */
    fun updatePageContext(webView: WebView?, url: String?, privateMode: Boolean): Boolean {
        detachCurrent()
        val origin = httpsOrigin(url)
        if (closed || privateMode || webView == null || origin == null) return false
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) ||
            !WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
        ) return false

        val current = Page(webView, origin, false)
        page = current
        return try {
            WebViewCompat.addWebMessageListener(
                webView,
                BRIDGE_NAME,
                setOf(origin),
                { view, message, sourceOrigin, isMainFrame, _ ->
                    if (!isMainFrame || view !== current.webView || !isCurrent(current) ||
                        httpsOrigin(sourceOrigin.toString()) != current.origin
                    ) return@addWebMessageListener
                    receiveSaveCandidate(current, message)
                },
            )
            scriptHandler = WebViewCompat.addDocumentStartJavaScript(
                webView,
                SAVE_CAPTURE_SCRIPT,
                setOf(origin),
            )
            true
        } catch (_: RuntimeException) {
            detachCurrent()
            false
        }
    }

    /**
     * Call from the owning WebViewClient's `onPageFinished`. This fallback covers hosts that learn
     * the final page URL only after navigation started, when document-start script installation
     * was too late for that document. The WebMessageListener remains exact-origin and main-frame
     * checked; this injects only the submit observer into the verified current page.
     */
    fun onPageFinished(webView: WebView, url: String) {
        val current = page ?: return
        if (current.webView !== webView || httpsOrigin(url) != current.origin || !isCurrent(current)) return
        webView.evaluateJavascript(SAVE_CAPTURE_SCRIPT, null)
    }

    /** Starts the explicit native fill flow for the currently active eligible page. */
    fun requestFill() {
        val current = page?.takeIf(::isCurrent) ?: run {
            onNotice("Saved logins are available on secure websites in regular tabs.")
            return
        }
        if (!beginInteraction()) return
        authorize(
            onSuccess = {
                if (!isCurrent(current)) { finishInteraction(); return@authorize }
                try {
                    io.execute {
                        val entries = runCatching {
                            vault.readAfterAuthentication().filter { httpsOrigin(it.origin) == current.origin }
                        }.getOrElse {
                            main.post {
                                if (isCurrent(current)) onNotice("Saved logins could not be opened.")
                                finishInteraction()
                            }
                            return@execute
                        }
                        main.post {
                            if (!isCurrent(current)) { finishInteraction(); return@post }
                            if (entries.isEmpty()) {
                                onNotice("No saved login is stored for this website.")
                                finishInteraction()
                            } else showFillChoices(current, entries)
                        }
                    }
                } catch (_: RuntimeException) {
                    finishInteraction()
                    onNotice("Saved logins could not be opened.")
                }
            },
            onError = { message -> finishInteraction(); onNotice(message) },
        )
    }

    fun close() {
        if (closed) return
        closed = true
        detachCurrent()
        activity.lifecycle.removeObserver(lifecycleObserver)
        io.shutdownNow()
    }

    private fun receiveSaveCandidate(current: Page, message: WebMessageCompat) {
        if (!isCurrent(current) || message.type != WebMessageCompat.TYPE_STRING) return
        val payload = runCatching { JSONObject(message.data ?: return) }.getOrNull() ?: return
        if (payload.optString("type") != "saveCandidate") return
        val username = payload.optString("username").takeIf { it.isNotBlank() && it.length <= MAX_USERNAME_CHARS } ?: return
        val password = payload.optString("password").takeIf { it.isNotEmpty() && it.length <= MAX_PASSWORD_CHARS } ?: return
        activity.runOnUiThread { confirmSave(current, username, password) }
    }

    private fun confirmSave(current: Page, username: String, password: String) {
        if (!isCurrent(current) || !beginInteraction()) return
        try {
            AlertDialog.Builder(activity)
                .setTitle("Save this login?")
                .setMessage("Save ${username.take(100)} for ${Uri.parse(current.origin).host} in the on-device vault?")
                .setPositiveButton("Save") { _, _ ->
                    authorize(
                        onSuccess = {
                            if (!isCurrent(current)) { finishInteraction(); return@authorize }
                            try {
                                io.execute {
                                    val outcome = runCatching {
                                        val entries = vault.readAfterAuthentication().toMutableList()
                                        val index = entries.indexOfFirst { it.origin == current.origin && it.username == username }
                                        val id = entries.getOrNull(index)?.id ?: UUID.randomUUID().toString()
                                        val credential = VaultCredential(id, current.origin, username, password)
                                        if (index >= 0) entries[index] = credential else entries.add(credential)
                                        vault.writeAfterAuthentication(entries)
                                    }
                                    main.post {
                                        if (isCurrent(current)) onNotice(
                                            if (outcome.isSuccess) "Login saved in the local password vault."
                                            else "Login could not be saved in the local password vault.",
                                        )
                                        finishInteraction()
                                    }
                                }
                            } catch (_: RuntimeException) {
                                finishInteraction()
                                onNotice("Login could not be saved in the local password vault.")
                            }
                        },
                        onError = { message -> finishInteraction(); onNotice(message) },
                    )
                }
                .setNegativeButton("Not now") { _, _ -> finishInteraction() }
                .setOnCancelListener { finishInteraction() }
                .show()
        } catch (_: RuntimeException) {
            finishInteraction()
        }
    }

    private fun showFillChoices(current: Page, entries: List<VaultCredential>) {
        if (!isCurrent(current)) { finishInteraction(); return }
        val labels = entries.map { it.username.take(100) }.toTypedArray()
        try {
            AlertDialog.Builder(activity)
                .setTitle("Saved logins · ${Uri.parse(current.origin).host}")
                .setItems(labels) { _, which ->
                    val selected = entries.getOrNull(which)
                    if (!isCurrent(current) || selected == null || httpsOrigin(selected.origin) != current.origin) {
                        finishInteraction()
                    } else {
                        fillCurrentPage(current, selected)
                        finishInteraction()
                    }
                }
                .setOnCancelListener { finishInteraction() }
                .show()
        } catch (_: RuntimeException) {
            finishInteraction()
        }
    }

    private fun fillCurrentPage(current: Page, credential: VaultCredential) {
        if (!isCurrent(current) || httpsOrigin(credential.origin) != current.origin) return
        val expectedOrigin = JSONObject.quote(current.origin)
        val username = JSONObject.quote(credential.username)
        val password = JSONObject.quote(credential.password)
        // This is a native user-approved fill. Credentials are never returned to page JavaScript
        // through the message channel or written to logs; the selected form receives them directly.
        val script = """
            (function(expected,u,p){
              if(window!==window.top||location.origin!==expected)return false;
              var forms=Array.prototype.slice.call(document.forms||[]);
              var active=document.activeElement;
              var form=active&&active.form||forms.find(function(f){return f.querySelector('input[type=password]')})||forms[0];
              if(!form)return false;
              var pass=form.querySelector('input[type=password]');
              if(!pass)return false;
              var user=form.querySelector('input[autocomplete=username],input[type=email],input[name*=user i],input[name*=email i],input[type=text]');
              function set(el,v){if(!el)return;var d=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el),'value');if(d&&d.set)d.set.call(el,v);else el.value=v;el.dispatchEvent(new Event('input',{bubbles:true}));el.dispatchEvent(new Event('change',{bubbles:true}));}
              set(user,u);set(pass,p);return true;
            })($expectedOrigin,$username,$password)
        """.trimIndent()
        current.webView.evaluateJavascript(script, null)
    }

    private fun authorize(onSuccess: () -> Unit, onError: (String) -> Unit) {
        if (authInProgress) { onError("Another password-vault authentication is already open."); return }
        authInProgress = true
        CredentialVaultAuthentication.authenticate(
            activity = activity,
            onAuthenticated = { authInProgress = false; onSuccess() },
            onDeviceCredentialRequired = { intent ->
                keyguardAction = { authInProgress = false; onSuccess() }
                keyguardError = { authInProgress = false; onError("Device authentication was cancelled.") }
                try { keyguardLauncher.launch(intent) } catch (_: RuntimeException) {
                    keyguardAction = null; keyguardError = null; authInProgress = false
                    onError("Device authentication could not start.")
                }
            },
            onError = { authInProgress = false; onError("Password-vault authentication was not completed.") },
        )
    }

    private fun beginInteraction(): Boolean {
        if (closed || interactionInProgress) return false
        interactionInProgress = true
        return true
    }

    private fun finishInteraction() { interactionInProgress = false }

    private fun isCurrent(candidate: Page): Boolean =
        !closed && page === candidate && !candidate.privateMode &&
            httpsOrigin(candidate.webView.url) == candidate.origin

    private fun detachCurrent() {
        val current = page
        page = null
        scriptHandler?.remove()
        scriptHandler = null
        current?.let { runCatching { WebViewCompat.removeWebMessageListener(it.webView, BRIDGE_NAME) } }
        interactionInProgress = false
    }

    private fun clearPage() = detachCurrent()

    companion object {
        private const val BRIDGE_NAME = "breezeCredentials"
        private const val MAX_USERNAME_CHARS = 1024
        private const val MAX_PASSWORD_CHARS = 4096

        /** Normalized exact HTTPS origin, including a non-default port. */
        fun httpsOrigin(raw: String?): String? {
            if (raw.isNullOrBlank()) return null
            val uri = runCatching { URI(raw) }.getOrNull() ?: return null
            if (!uri.scheme.equals("https", ignoreCase = true) || uri.rawUserInfo != null) return null
            val host = uri.host?.lowercase()?.trimEnd('.')?.takeIf(String::isNotBlank) ?: return null
            val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
            return "https://$host$port"
        }

        private val SAVE_CAPTURE_SCRIPT = """
            (function(){
              if(window!==window.top||window.__breezeCredentialCapture)return;
              window.__breezeCredentialCapture=true;
              document.addEventListener('submit',function(event){
                var form=event.target;
                if(!(form instanceof HTMLFormElement))return;
                var pass=form.querySelector('input[type=password]');
                if(!pass||!window.breezeCredentials||typeof window.breezeCredentials.postMessage!=='function')return;
                var user=form.querySelector('input[autocomplete=username],input[type=email],input[name*=user i],input[name*=email i],input[type=text]');
                var username=user?String(user.value||''):'';
                var password=String(pass.value||'');
                if(!username||!password||username.length>1024||password.length>4096)return;
                window.breezeCredentials.postMessage(JSON.stringify({type:'saveCandidate',username:username,password:password}));
              },true);
            })();
        """.trimIndent()
    }
}
