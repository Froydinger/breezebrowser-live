package com.froydinger.breeze.browser

import android.webkit.JavascriptInterface
import android.webkit.WebView
import org.json.JSONObject

/**
 * Media bridge for Android System WebView. WebView does not expose Gecko's
 * WebExtension video telemetry, so this observes HTML media in the page and
 * provides a reversible video-only layout while Android owns the PiP window.
 * Keep one instance per WebView, call [install] after each main-frame load, and
 * call [setPictureInPicture] on Activity PiP transitions. The script never
 * starts media; it only reports and relayouts it.
 */
class ChromiumMedia(
    private val webView: WebView,
    private val onState: (State) -> Unit,
) {
    data class State(
        val playing: Boolean,
        val video: Boolean,
        val width: Int,
        val height: Int,
        val title: String,
    )

    @Volatile private var closed = false

    private val bridge = object {
        @JavascriptInterface fun update(raw: String) {
            if (closed) return
            val state = runCatching {
                val value = JSONObject(raw)
                State(value.optBoolean("playing"), value.optBoolean("video"),
                    value.optInt("width").coerceIn(0, 4096), value.optInt("height").coerceIn(0, 4096),
                    value.optString("title").take(512))
            }.getOrNull() ?: return
            webView.post { if (!closed) onState(state) }
        }
    }

    init {
        webView.addJavascriptInterface(bridge, BRIDGE)
    }

    /** Re-run from WebViewClient.onPageFinished; page navigation resets page globals. */
    fun install() {
        if (!closed) webView.evaluateJavascript(SCRIPT, null)
    }

    /** Keep the active video in the WebView surface and suppress surrounding page content. */
    fun setPictureInPicture(enabled: Boolean) {
        if (closed) return
        val js = "window.__breezeMedia&&window.__breezeMedia.pip(${enabled})"
        webView.evaluateJavascript(js, null)
    }

    /** Ask the active document to resume/pause its current media from a native PiP action. */
    fun setPlaying(playing: Boolean) {
        if (closed) return
        webView.evaluateJavascript("window.__breezeMedia&&window.__breezeMedia.play(${playing})", null)
    }

    fun close() {
        if (closed) return
        closed = true
        runCatching { webView.removeJavascriptInterface(BRIDGE) }
    }

    companion object {
        private const val BRIDGE = "BreezeMedia"
        private val SCRIPT = """
            (function(){
              if(window.__breezeMedia) return;
              var pip=false, style=null, timer=0, last='';
              function media(){return Array.prototype.slice.call(document.querySelectorAll('video,audio'));}
              function active(){var a=media();return a.find(function(x){return !x.paused&&!x.ended;})||a.find(function(x){return x.videoWidth||x.tagName==='AUDIO';})||a[0]||null;}
              function report(){
                var e=active(); if(!e)return;
                var b=e.getBoundingClientRect();
                var s={playing:!e.paused&&!e.ended,video:e.tagName==='VIDEO',width:e.videoWidth||Math.round(b.width),height:e.videoHeight||Math.round(b.height),title:document.title||''};
                var raw=JSON.stringify(s); if(raw!==last){last=raw;try{BreezeMedia.update(raw)}catch(_){}}
              }
              function setPip(on){
                pip=!!on;
                if(pip){
                  if(!style){style=document.createElement('style');style.id='__breeze_media_pip';(document.head||document.documentElement).appendChild(style)}
                  style.textContent='html,body{background:#000!important;overflow:hidden!important}body>*{visibility:hidden!important}video{visibility:visible!important;position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;object-fit:contain!important;z-index:2147483647!important;background:#000!important}';
                }else if(style){style.remove();style=null;}
              }
              window.__breezeMedia={pip:setPip,play:function(on){var e=active();if(!e)return;if(on)e.play().catch(function(){});else e.pause();},close:function(){setPip(false);clearInterval(timer)}};
              document.addEventListener('play',report,true);document.addEventListener('pause',report,true);document.addEventListener('ended',report,true);
              document.addEventListener('loadedmetadata',report,true);document.addEventListener('timeupdate',report,true);
              timer=setInterval(report,1000);report();
            })();
        """.trimIndent()
    }
}
