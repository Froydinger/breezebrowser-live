package com.froydinger.breeze.browser

import android.webkit.WebView

/**
 * Reports which web notification primitives the active Android System WebView exposes.
 * This is a capability probe only: WebView does not expose the Web Push API, and this helper
 * deliberately does not emulate it or grant native notification permission to a site.
 */
object ChromiumWebPushSupport {
    enum class Capability {
        PUSH_AND_NOTIFICATIONS,
        NOTIFICATIONS_WITHOUT_PUSH,
        NONE,
        UNKNOWN,
    }

    private const val PROBE = """
        (function() {
          try {
            var notifications = typeof window.Notification !== 'undefined';
            var push = typeof window.PushManager !== 'undefined' &&
              typeof navigator.serviceWorker !== 'undefined';
            return push && notifications ? 'push' :
              (notifications ? 'notifications-only' : 'none');
          } catch (_) { return 'none'; }
        })();
    """

    /** Must be called on the WebView's UI thread, typically after its main frame finishes loading. */
    fun inspect(webView: WebView, callback: (Capability) -> Unit) {
        webView.evaluateJavascript(PROBE) { result ->
            callback(
                when (result?.trim('"')) {
                    "push" -> Capability.PUSH_AND_NOTIFICATIONS
                    "notifications-only" -> Capability.NOTIFICATIONS_WITHOUT_PUSH
                    "none" -> Capability.NONE
                    else -> Capability.UNKNOWN
                },
            )
        }
    }
}
