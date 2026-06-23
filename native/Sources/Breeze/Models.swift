// Core data models. Phase A keeps these light; Phase B adds Codable persistence.

import Cocoa
import WebKit

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
    // Element-fullscreen detection — lets us flatten the rounded web-area corners
    // while a video is fullscreen (rounded corners kill the HW video overlay → black).
    c.userContentController.addUserScript(WKUserScript(source: breezeFullscreenJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    c.userContentController.addUserScript(WKUserScript(source: breezeLinkMenuJS,
        injectionTime: .atDocumentStart, forMainFrameOnly: false))
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeMsg")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeMedia")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeFullscreen")
    c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeLinkMenu")
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
  function report(p) {
    try { window.webkit.messageHandlers.breezeMedia.postMessage({ playing: p, title: document.title }); } catch (e) {}
  }
  document.addEventListener('play', function () { report(true); }, true);
  document.addEventListener('playing', function () { report(true); }, true);
  document.addEventListener('pause', function () { report(false); }, true);
  document.addEventListener('ended', function () { report(false); }, true);
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
      if ((node.tagName || '').toLowerCase() === 'img' && node.currentSrc) return node;
      node = node.parentElement;
    }
    return null;
  }
  document.addEventListener('contextmenu', function (event) {
    var node = event.target;
    var link = node && node.closest ? node.closest('a[href]') : null;
    var image = closestImage(node);
    var editable = closestEditable(node);
    var selection = '';
    try { selection = String(window.getSelection ? window.getSelection().toString() : '').trim(); } catch (e) {}
    event.preventDefault();
    try {
      window.webkit.messageHandlers.breezeLinkMenu.postMessage({
        url: link ? link.href : '',
        image: image ? image.currentSrc : '',
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

// Reports HTML5 element-fullscreen enter/exit (YouTube's fullscreen button, etc.)
// to the native side. Runs in every frame so cross-origin embeds (e.g. an
// embedded YouTube iframe) are caught too. postMessage is a no-op if the handler
// isn't registered (private tabs), so this can never throw.
let breezeFullscreenJS = """
(function () {
  if (location.protocol === 'file:') return;
  function report() {
    var el = document.fullscreenElement || document.webkitFullscreenElement || document.webkitCurrentFullScreenElement;
    try { window.webkit.messageHandlers.breezeFullscreen.postMessage(!!el); } catch (e) {}
  }
  document.addEventListener('fullscreenchange', report, true);
  document.addEventListener('webkitfullscreenchange', report, true);
  document.addEventListener('webkitbeginfullscreen', function () { report(); }, true);
  document.addEventListener('webkitendfullscreen', function () { report(); }, true);
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
    var sleeping = false         // discarded to save memory; reloads on activate
    var sleptURL: String?        // URL to restore when woken
    var lastActive = Date()
    var splitPartnerId: UUID?    // if in a split pair, the UUID of the other tab
    var splitIsRight = false     // true if this tab is placed on the right side of the split
    var isPopup = false          // opened via window.open() (e.g. an OAuth sign-in window)
    var isPrivate = false

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
            // Re-inject media + fullscreen scripts for private tabs
            c.userContentController.addUserScript(WKUserScript(source: breezeMediaJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.addUserScript(WKUserScript(source: breezeFullscreenJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.addUserScript(WKUserScript(source: breezeLinkMenuJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            c.userContentController.add(BreezeScriptMessageRouter.shared, name: "breezeLinkMenu")
            config = c
        } else {
            config = sharedConfig
        }
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        // NOTE: do NOT set masksToBounds/cornerRadius on the web view's own layer —
        // it clips WebKit's fullscreen video presentation to a black screen. The
        // rounded-corner look is applied to the parent webContainer instead.
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

struct AIImageAttachment {
    let data: Data
    let filename: String
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

/// Shared favicon fetch + cache (Google s2 service, like the Electron app).
final class Favicons {
    static let shared = Favicons()
    private var cache: [String: NSImage] = [:]

    func image(for host: String, _ done: @escaping (NSImage?) -> Void) {
        guard !host.isEmpty else { done(nil); return }
        if let img = cache[host] { done(img); return }
        guard let u = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64")
        else { done(nil); return }
        URLSession.shared.dataTask(with: u) { [weak self] d, _, _ in
            guard let d, let img = NSImage(data: d) else { DispatchQueue.main.async { done(nil) }; return }
            DispatchQueue.main.async { self?.cache[host] = img; done(img) }
        }.resume()
    }
}
