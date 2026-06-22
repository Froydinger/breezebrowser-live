// Core data models. Phase A keeps these light; Phase B adds Codable persistence.

import Cocoa
import WebKit

let SafariUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
    "(KHTML, like Gecko) Version/18.5 Safari/605.1.15"

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
    return c
}()

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
            // Re-inject media script for play/pause detection in private tabs
            c.userContentController.addUserScript(WKUserScript(source: breezeMediaJS,
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            config = c
        } else {
            config = sharedConfig
        }
        webView = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, iOS 16.4, *) {
            webView.isInspectable = true
        }
        webView.customUserAgent = SafariUA
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
struct AIContext { let label: String; let text: String }

/// An extra context the user added: another open tab, or an attached image
/// (already described on-device by Vision).
struct AIExtra { let label: String; var tab: Tab?; var imageText: String? }

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
