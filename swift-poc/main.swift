// Breeze PoC — a minimal native macOS browser on WKWebView (Safari's engine).
// Purpose: prove the M0 premise — DRM streaming (FairPlay) + passkeys + general
// browsing — before committing to a full Swift rewrite. Single window, single
// web view, address bar, back/forward/reload. Deliberately tiny.

import Cocoa
import WebKit

final class BrowserWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let window: NSWindow
    let webView: WKWebView
    let address = NSTextField()
    let back = NSButton()
    let forward = NSButton()
    let reload = NSButton()
    let progress = NSProgressIndicator()
    var progressObs: NSKeyValueObservation?

    override init() {
        // Shared, persistent data store so logins/cookies stick (passkeys too).
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.mediaTypesRequiringUserActionForPlayback = []   // let video autoplay
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if #available(macOS 13.3, *) { cfg.preferences.isElementFullscreenEnabled = true }

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // CRITICAL: WKWebView's default UA omits the "Version/x Safari/y" token,
        // which makes many sites serve degraded/legacy CSS and makes Google's
        // sign-in flow (and passkeys) balk. Present as a normal modern Safari so
        // DRM + passkey + general browsing behave like Safari does.
        webView.customUserAgent =
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
          "(KHTML, like Gecko) Version/18.5 Safari/605.1.15"

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Breeze PoC"
        window.center()
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        // ---- toolbar row ----
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        func mkBtn(_ symbol: String, _ sel: Selector) -> NSButton {
            let b = NSButton()
            b.title = symbol
            b.bezelStyle = .rounded
            b.target = self
            b.action = sel
            b.setContentHuggingPriority(.required, for: .horizontal)
            return b
        }
        back.title = "◀"; back.bezelStyle = .rounded; back.target = self; back.action = #selector(goBack)
        forward.title = "▶"; forward.bezelStyle = .rounded; forward.target = self; forward.action = #selector(goForward)
        reload.title = "⟳"; reload.bezelStyle = .rounded; reload.target = self; reload.action = #selector(doReload)

        address.placeholderString = "Search or enter URL"
        address.delegate = self
        address.bezelStyle = .roundedBezel
        address.font = .systemFont(ofSize: 14)
        address.focusRingType = .none
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bar.addArrangedSubview(back)
        bar.addArrangedSubview(forward)
        bar.addArrangedSubview(reload)
        bar.addArrangedSubview(address)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(bar)
        root.addSubview(progress)
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            progress.topAnchor.constraint(equalTo: bar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: progress.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root

        progressObs = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            self.progress.isHidden = wv.estimatedProgress >= 1.0
            self.progress.doubleValue = wv.estimatedProgress
        }

        window.makeKeyAndOrderFront(nil)
        navigate(to: "https://www.google.com")
        window.makeFirstResponder(address)
    }

    func navigate(to text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var urlString = q
        let looksLikeURL = q.contains("://") ||
            (q.contains(".") && !q.contains(" "))
        if looksLikeURL {
            if !q.contains("://") { urlString = "https://" + q }
        } else {
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            urlString = "https://www.google.com/search?q=\(enc)"
        }
        if let url = URL(string: urlString) { webView.load(URLRequest(url: url)) }
    }

    // Enter in the address bar
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { navigate(to: address.stringValue); return true }
        return false
    }

    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func doReload() { webView.reload() }

    func syncChrome() {
        back.isEnabled = webView.canGoBack
        forward.isEnabled = webView.canGoForward
        if let u = webView.url?.absoluteString, window.firstResponder != address.currentEditor() {
            address.stringValue = u
        }
        window.title = webView.title?.isEmpty == false ? webView.title! : "Breeze PoC"
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { syncChrome() }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { syncChrome() }
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { syncChrome() }

    // target=_blank / window.open → load in the same view (PoC)
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { w.load(URLRequest(url: url)) }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        browser = BrowserWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    @objc func focusAddr() { browser?.window.makeFirstResponder(browser?.address); browser?.address.currentEditor()?.selectAll(nil) }
    @objc func reload() { browser?.doReload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menus so ⌘Q / ⌘L / ⌘R and clipboard (paste passwords) work during the test.
let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Breeze PoC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Focus Address Bar", action: #selector(AppDelegate.focusAddr), keyEquivalent: "l")
fileMenu.addItem(withTitle: "Reload", action: #selector(AppDelegate.reload), keyEquivalent: "r")
fileItem.submenu = fileMenu

let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
