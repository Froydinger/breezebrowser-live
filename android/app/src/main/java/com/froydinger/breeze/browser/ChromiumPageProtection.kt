package com.froydinger.breeze.browser

import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import java.io.ByteArrayInputStream
import java.net.URI

/**
 * Small WebView adapter for Breeze's browser-level privacy controls.
 *
 * Forward WebViewClient.shouldInterceptRequest to [interceptRequest]. Call [apply]
 * on the UI thread at navigation and setting changes, then [onPageFinished] after
 * a successful load. The caller retains its own navigation WebViewClient.
 */
class ChromiumPageProtection(
    private val webView: WebView,
    private val isProtectionEnabled: (httpsOrigin: String) -> Boolean,
    private val hiddenSelectorsForOrigin: (httpsOrigin: String) -> List<String>,
){
    @Volatile private var activeOrigin: String? = null
    @Volatile private var protectionEnabled = false

    /** Updates the active HTTPS origin and applies its manual hide rules. */
    fun apply(url: String = webView.url.orEmpty()) {
        val origin = httpsOrigin(url)
        activeOrigin = origin
        protectionEnabled = origin != null && isProtectionEnabled(origin)
        if (webView.url == url) injectSelectors(if (protectionEnabled) hiddenSelectorsForOrigin(origin!!) else emptyList())
    }

    /** WebView calls this on a worker thread; only immutable/volatile policy is read. */
    fun interceptRequest(request: WebResourceRequest): WebResourceResponse? {
        val pageOrigin = activeOrigin ?: return null
        if (!protectionEnabled || request.isForMainFrame) return null
        val requestUri = runCatching { URI(request.url.toString()) }.getOrNull() ?: return null
        if (!requestUri.scheme.equals("https", ignoreCase = true)) return null
        val requestHost = requestUri.host?.lowercase()?.trimEnd('.') ?: return null
        val pageHost = runCatching { URI(pageOrigin).host?.lowercase() }.getOrNull() ?: return null
        if (requestHost == pageHost || !isKnownAdOrTracker(requestHost)) return null
        return WebResourceResponse(
            "text/plain",
            "UTF-8",
            200,
            "OK",
            mapOf("Cache-Control" to "no-store"),
            ByteArrayInputStream(ByteArray(0)),
        )
    }

    fun onPageFinished(url: String) {
        if (webView.url == url) apply(url)
    }

    private fun injectSelectors(selectors: List<String>) {
        val safe = selectors.asSequence().filter(::isSafeSelector).distinct().take(MAX_RULES).toList()
        val encoded = safe.joinToString(",") { selector -> "'${selector}'" }
        // Selectors are constrained to a grammar without quotes, escapes, or CSS
        // combinators other than child, so this JSON-like array is safe to inject.
        webView.evaluateJavascript(
            "(function(){var id='__breeze_hidden_elements';var s=document.getElementById(id);if(!s){s=document.createElement('style');s.id=id;(document.head||document.documentElement).appendChild(s)}s.textContent=[$encoded].map(function(x){return x+'{display:none!important;visibility:hidden!important}'}).join('\\n')})()",
            null,
        )
    }

    companion object {
        private const val MAX_RULES = 30
        private val selectorPattern = Regex(
            "^[a-z][a-z0-9-]{0,63}(:nth-of-type\\([1-9][0-9]{0,4}\\))?(>[a-z][a-z0-9-]{0,63}(:nth-of-type\\([1-9][0-9]{0,4}\\))?){0,32}$",
        )

        /** Stable settings key: normalized HTTPS origin, including non-default port. */
        fun httpsOrigin(url: String): String? {
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            if (!uri.scheme.equals("https", ignoreCase = true) || uri.rawUserInfo != null) return null
            val host = uri.host?.lowercase()?.trimEnd('.')?.takeIf { it.isNotBlank() } ?: return null
            val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
            return "https://$host$port"
        }

        fun isSafeSelector(value: String): Boolean = value.length <= 512 && selectorPattern.matches(value)

        private fun isKnownAdOrTracker(host: String): Boolean = blockedHosts.any { blocked ->
            host == blocked || host.endsWith(".$blocked")
        }

        // A deliberately small, bundled seed list. WebView has no Gecko-style
        // maintained content-blocking engine; this catches common third-party
        // analytics/ad endpoints without fetching external lists or data.
        private val blockedHosts = setOf(
            "doubleclick.net", "googlesyndication.com", "googleadservices.com",
            "adservice.google.com", "googletagmanager.com", "google-analytics.com",
            "connect.facebook.net", "pixel.facebook.com",
            "analytics.twitter.com", "static.ads-twitter.com", "ads.yahoo.com",
            "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "criteo.com",
            "scorecardresearch.com", "quantserve.com", "taboola.com", "outbrain.com",
            "hotjar.com", "segment.io", "mixpanel.com", "amplitude.com",
            "newrelic.com", "clarity.ms", "bat.bing.com",
        )
    }
}
