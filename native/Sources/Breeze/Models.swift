// Core data models. Phase A keeps these light; Phase B adds Codable persistence.

import Cocoa
import WebKit

// WKWebView intentionally omits Safari's product/version tokens from its native
// user agent, which makes sites such as Google serve their legacy fallback UI.
// Append only the installed Safari version while leaving WebKit in charge of the
// device/OS/engine portion, so this stays current across macOS updates.
let breezeSafariProductToken: String? = {
    guard let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
          let safariBundle = Bundle(url: safariURL),
          let version = safariBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          !version.isEmpty else { return nil }
    return "Version/\(version) Safari/605.1.15"
}()

let sharedConfig: WKWebViewConfiguration = {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .default()
    c.mediaTypesRequiringUserActionForPlayback = []
    c.defaultWebpagePreferences.allowsContentJavaScript = true
    if #available(macOS 13.3, *) { c.preferences.isElementFullscreenEnabled = true }
    c.enablePictureInPictureAPI()
    // Internal-page bridge (defined only on file:// pages — see breezeBridgeJS).
    let script = WKUserScript(source: breezeBridgeJS, injectionTime: .atDocumentStart,
                              forMainFrameOnly: true)
    c.userContentController.addUserScript(script)
    // Media (now-playing) detection — reports play/pause to the native side.
    c.userContentController.addUserScript(WKUserScript(source: breezeMediaJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    c.userContentController.addUserScript(WKUserScript(source: breezeKeyboardJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    c.userContentController.addUserScript(WKUserScript(source: breezeLinkMenuJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    c.userContentController.addUserScript(WKUserScript(source: breezeGeolocationJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: true))
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeMsg")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeMedia")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeLinkMenu")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeGeolocation")
    return c
}()

final class BreezeScriptMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = BreezeScriptMessageRouter()

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let handler = message.webView?.navigationDelegate as? WKScriptMessageHandler else { return }
        handler.userContentController(userContentController, didReceive: message)
    }
}

extension WKWebViewConfiguration {
    /// Enable the JS Picture-in-Picture API. In a WKWebView it's OFF by default
    /// (Safari has it on), which is why `video.requestPictureInPicture()` throws
    /// `NotSupportedError`. Walks WebKit's private feature list and flips on the
    /// PiP feature(s). Fully guarded — silently no-ops if the SPI shape changes,
    /// so it can never crash.
    func enablePictureInPictureAPI() {
        let prefs = preferences
        // The WebKit preference that gates requestPictureInPicture() on macOS —
        // defaults OFF in WKWebView (Safari has it on). Verified via the live SDK:
        // -[WKPreferences _setAllowsPictureInPictureMediaPlayback:] exists and
        // flipping it true makes both the native control button and the JS PiP API
        // work. responds() guards it, so this can never crash if the SPI changes.
        let pipSel = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if prefs.responds(to: pipSel), let imp = prefs.method(for: pipSel) {
            typealias BoolFn = @convention(c)(NSObject, Selector, ObjCBool) -> Void
            unsafeBitCast(imp, to: BoolFn.self)(prefs, pipSel, true)
        }
    }
}

let breezeMediaJS = """
(function () {
  if (location.protocol === 'file:') return;
  function report(p, pip) {
    var body = { playing: p, title: document.title };
    if (pip) body.pip = pip;
    try { window.webkit.messageHandlers.breezeMedia.postMessage(body); } catch (e) {}
  }
  document.addEventListener('play', function () { report(true); }, true);
  document.addEventListener('playing', function () { report(true); }, true);
  document.addEventListener('pause', function () { report(false); }, true);
  document.addEventListener('ended', function () { report(false); }, true);
  var lastPresentationMode = '';
  function presentationModeOf(v) {
    return (v && (v.webkitPresentationMode || v.presentationMode)) || '';
  }
  function reportPresentationMode(v) {
    var mode = presentationModeOf(v);
    if (!mode || mode === lastPresentationMode) return;
    var previous = lastPresentationMode;
    lastPresentationMode = mode;
    if (mode === 'picture-in-picture') report(!(v && v.paused), 'enter');
    else if (previous === 'picture-in-picture') report(!(v && v.paused), 'leave');
  }
  document.addEventListener('enterpictureinpicture', function (event) {
    var v = event.target;
    lastPresentationMode = 'picture-in-picture';
    report(!(v && v.paused), 'enter');
  }, true);
  document.addEventListener('leavepictureinpicture', function (event) {
    var v = event.target;
    lastPresentationMode = presentationModeOf(v);
    report(!(v && v.paused), 'leave');
  }, true);
  document.addEventListener('webkitpresentationmodechanged', function (event) {
    reportPresentationMode(event.target);
  }, true);
})();
"""

let breezeLinkMenuJS = """
(function () {
  if (location.protocol === 'file:') return;
  function closestEditable(node) {
    while (node && node !== document.documentElement) {
      if (node.isContentEditable) return node;
      var tag = (node.tagName || '').toLowerCase();
      if (tag === 'textarea') return node;
      if (tag === 'input') {
        var type = (node.getAttribute('type') || 'text').toLowerCase();
        if (!/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/i.test(type)) return node;
      }
      node = node.parentElement;
    }
    return null;
  }
  function closestImage(node) {
    while (node && node !== document.documentElement) {
      if ((node.tagName || '').toLowerCase() === 'img' && (node.currentSrc || node.src)) return node;
      node = node.parentElement;
    }
    return null;
  }
  function cleanURL(value) {
    value = String(value || '').trim();
    if (!value || value === 'about:blank') return '';
    try { return new URL(value, location.href).href; } catch (e) { return ''; }
  }
  function mediaURLFromLink(link) {
    var href = cleanURL(link && link.href);
    if (!href) return '';
    return /\\.(png|jpe?g|webp|gif|svg|avif|bmp|tiff?|mp4|m4v|mov|webm|mp3|m4a|wav|ogg)(\\?|#|$)/i.test(href) ? href : '';
  }
  function closestMedia(node) {
    var cur = node;
    while (cur && cur !== document.documentElement) {
      var tag = (cur.tagName || '').toLowerCase();
      if (tag === 'img') return { kind: 'image', url: cleanURL(cur.currentSrc || cur.src) };
      if (tag === 'video') return { kind: 'video', url: cleanURL(cur.currentSrc || cur.src || (cur.querySelector('source[src]') || {}).src), poster: cleanURL(cur.poster) };
      if (tag === 'audio') return { kind: 'audio', url: cleanURL(cur.currentSrc || cur.src || (cur.querySelector('source[src]') || {}).src) };
      if (tag === 'source' && cur.parentElement) {
        var parentTag = (cur.parentElement.tagName || '').toLowerCase();
        if (parentTag === 'video' || parentTag === 'audio') return { kind: parentTag, url: cleanURL(cur.src) };
      }
      var bg = '';
      try { bg = getComputedStyle(cur).backgroundImage || ''; } catch (e) {}
      var m = bg.match(/url\\((['"]?)(.*?)\\1\\)/);
      if (m && m[2] && !m[2].startsWith('data:')) return { kind: 'image', url: cleanURL(m[2]) };
      cur = cur.parentElement;
    }
    return { kind: '', url: '' };
  }
  document.addEventListener('contextmenu', function (event) {
    var node = event.target;
    var link = node && node.closest ? node.closest('a[href]') : null;
    var image = closestImage(node);
    var editable = closestEditable(node);
    if (editable) return; // preserve WebKit's native edit/autofill/password menu.
    var media = closestMedia(node);
    var linkMedia = mediaURLFromLink(link);
    if (!media.url && linkMedia) {
      media = { kind: /\\.(mp4|m4v|mov|webm)(\\?|#|$)/i.test(linkMedia) ? 'video' : (/\\.(mp3|m4a|wav|ogg)(\\?|#|$)/i.test(linkMedia) ? 'audio' : 'image'), url: linkMedia };
    }
    var selection = '';
    try { selection = String(window.getSelection ? window.getSelection().toString() : '').trim(); } catch (e) {}
    event.preventDefault();
    try {
      window.webkit.messageHandlers.breezeLinkMenu.postMessage({
        url: link ? link.href : '',
        image: media.kind === 'image' ? (media.url || (image ? cleanURL(image.currentSrc || image.src) : '')) : '',
        media: media.kind !== 'image' ? (media.url || '') : '',
        mediaKind: media.kind || '',
        poster: media.poster || '',
        filename: link ? (link.getAttribute('download') || '') : '',
        selection: selection,
        editable: !!editable,
        pageURL: location.href,
        pageTitle: document.title || location.href
      });
    } catch (e) {}
  }, true);
})();
"""

let breezeKeyboardJS = """
(function () {
  if (location.protocol === 'file:') return;
  function editable(el) {
    while (el && el !== document.documentElement) {
      if (el.isContentEditable) return true;
      var tag = (el.tagName || '').toLowerCase();
      if (tag === 'textarea') return true;
      if (tag === 'input') {
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        return !/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/i.test(type);
      }
      if ((el.getAttribute && el.getAttribute('role')) === 'textbox') return true;
      el = el.parentElement;
    }
    return false;
  }
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Backspace' || e.metaKey || e.ctrlKey || e.altKey) return;
    if (editable(e.target || document.activeElement)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }, true);
})();
"""

// WKUIDelegate's public geolocation permission callback is macOS 27+. On the
// supported macOS 14–26 releases, route the standard web API through native
// Core Location so sites receive both Breeze's per-origin prompt and macOS's
// Location Services prompt instead of an immediate POSITION_UNAVAILABLE error.
let breezeGeolocationJS = """
(function () {
  if (location.protocol === 'file:' || window.__breezeGeolocationInstalled) return;
  var geo = navigator.geolocation;
  if (!geo) return;
  window.__breezeGeolocationInstalled = true;
  var callbacks = Object.create(null);
  var nextWatch = 1;
  function token(prefix) {
    return prefix + '-' + Date.now() + '-' + Math.random().toString(36).slice(2);
  }
  function send(id, watch, success, error, options) {
    callbacks[id] = { success: success, error: error, watch: watch };
    try {
      window.webkit.messageHandlers.breezeGeolocation.postMessage({
        action: 'request', id: id, watch: watch,
        highAccuracy: !!(options && options.enableHighAccuracy)
      });
    } catch (e) {
      delete callbacks[id];
      if (typeof error === 'function') error({ code: 2, message: 'Location is unavailable.' });
    }
  }
  window.__breezeGeoResolve = function (id, ok, value) {
    var cb = callbacks[id];
    if (!cb) return;
    if (!cb.watch || !ok) delete callbacks[id];
    try {
      if (ok) {
        if (typeof cb.success === 'function') cb.success(value);
      } else if (typeof cb.error === 'function') {
        cb.error(value);
      }
    } catch (e) {}
  };
  var replacement = {
    getCurrentPosition: function (success, error, options) {
      send(token('once'), false, success, error, options || {});
    },
    watchPosition: function (success, error, options) {
      var watchId = nextWatch++;
      send('watch-' + watchId + '-' + token('geo'), true, success, error, options || {});
      return watchId;
    },
    clearWatch: function (watchId) {
      var prefix = 'watch-' + watchId + '-';
      Object.keys(callbacks).forEach(function (id) {
        if (id.indexOf(prefix) !== 0) return;
        delete callbacks[id];
        try { window.webkit.messageHandlers.breezeGeolocation.postMessage({ action: 'clear', id: id }); } catch (e) {}
      });
    }
  };
  try { Object.defineProperty(navigator, 'geolocation', { configurable: true, value: replacement }); }
  catch (e) {
    try {
      geo.getCurrentPosition = replacement.getCurrentPosition;
      geo.watchPosition = replacement.watchPosition;
      geo.clearWatch = replacement.clearWatch;
    } catch (_) {}
  }
})();
"""

func hostOf(_ url: URL?) -> String {
    guard let h = url?.host else { return "" }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
}

final class Tab {
    let id = UUID()
    let webView: WKWebView
    var title = "New Tab"
    var isNewTab = true          // show the native new-tab page instead of the web view
    var isChatTab = false        // shows the AI assistant panel instead of a web view
    var groupId: Int?            // nil = ungrouped
    var pinUrl: String?          // the pinned app this tab represents, if any
    var perfMode = false         // 🚀 boost: no throttle, square corners
    var isPlaying = false        // media currently playing in this tab
    var mediaTitle = ""
    var lastMediaPauseAt: Date?
    var isInPiP = false
    var keepsMediaAlive = false  // native PiP X dismissed; keep background playback attached
    var sleeping = false         // discarded to save memory; reloads on activate
    var sleptURL: String?        // URL to restore when woken
    var lastActive = Date()
    var splitPartnerId: UUID?    // if in a split pair, the UUID of the other tab
    var splitIsRight = false     // true if this tab is placed on the right side of the split
    var isPopup = false          // opened via window.open() (e.g. an OAuth sign-in window)
    var isPrivate = false
    var pageZoom: CGFloat = 1.0

    // `configuration` defaults to the shared config; window.open() popups must pass the
    // configuration WebKit hands us so window.opener/postMessage keep working.
    init(configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let config: WKWebViewConfiguration
        if let configuration = configuration {
            config = configuration
        } else if isPrivate {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = .nonPersistent()
            c.mediaTypesRequiringUserActionForPlayback = []
            c.defaultWebpagePreferences.allowsContentJavaScript = true
            if #available(macOS 13.3, *) { c.preferences.isElementFullscreenEnabled = true }
            c.enablePictureInPictureAPI()
            // Re-inject media script for private tabs
            c.userContentController.addUserScript(WKUserScript(source: breezeMediaJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.addUserScript(WKUserScript(source: breezeKeyboardJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.addUserScript(WKUserScript(source: breezeLinkMenuJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.addUserScript(WKUserScript(source: breezeGeolocationJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeLinkMenu")
            c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeGeolocation")
            config = c
        } else {
            config = sharedConfig
        }
        config.applicationNameForUserAgent = breezeSafariProductToken
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        // WKWebView needs a backing layer for hardware video. Do not mutate that
        // layer's clipping/corner properties; WebKit reparents it for fullscreen.
        webView.wantsLayer = true
    }
}

struct Pin {
    var url: String
    var title: String
}

/// A page's text given to the assistant as context (current tab + @-added tabs).
/// `isCurrent` marks the tab the user is actively viewing — it's surfaced to the
/// model as "the page you're looking at" (the referent of "this page/video/article"),
/// distinct from reference-only context like history, bookmarks, and other tabs.
struct AIContext { let label: String; let text: String; var isCurrent: Bool = false }

/// An extra context the user added: another open tab, or an attached image
/// (already described on-device by Vision).
struct AIExtra {
    let label: String
    var tab: Tab?
    var imageText: String?
    var imageData: Data?
    var imageFilename: String?

    init(label: String, tab: Tab? = nil, imageText: String? = nil, imageData: Data? = nil, imageFilename: String? = nil) {
        self.label = label
        self.tab = tab
        self.imageText = imageText
        self.imageData = imageData
        self.imageFilename = imageFilename
    }
}

/// Pin squircle sizing — matches the Electron --pin-min values (Settings).
enum PinSize: String {
    case small, medium, large
    var minPt: CGFloat { switch self { case .small: 36; case .medium: 44; case .large: 52 } }
}

struct TabGroup {
    var id: Int
    var name: String
    var collapsed: Bool = false
}

/// Shared favicon fetch + cache. Tries DuckDuckGo's icon service first — it 404s on
/// a real miss, so we can tell when it failed and fall through. Google's s2 service
/// always returns *something* (a generic globe) even when it can't find the real
/// icon, which is why sites like Lovable showed a placeholder; it's the last resort.
final class Favicons {
    static let shared = Favicons()
    private var cache: [String: NSImage] = [:]

    func image(for host: String, _ done: @escaping (NSImage?) -> Void) {
        guard !host.isEmpty else { done(nil); return }
        if let img = cache[host] { done(img); return }
        let sources = [
            "https://icons.duckduckgo.com/ip3/\(host).ico",
            "https://\(host)/favicon.ico",
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
        ]
        fetch(host: host, sources: sources, index: 0, done: done)
    }

    private func fetch(host: String, sources: [String], index: Int, done: @escaping (NSImage?) -> Void) {
        guard index < sources.count, let u = URL(string: sources[index]) else {
            DispatchQueue.main.async { done(nil) }; return
        }
        URLSession.shared.dataTask(with: u) { [weak self] d, resp, _ in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200, let d, !d.isEmpty, let img = NSImage(data: d), img.size.width >= 8 {
                DispatchQueue.main.async { self?.cache[host] = img; done(img) }
            } else {
                self?.fetch(host: host, sources: sources, index: index + 1, done: done)
            }
        }.resume()
    }
}
