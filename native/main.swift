// Breeze Native — M1 (Liquid Glass). Native macOS 26+ browser: AppKit + WKWebView
// with the new Liquid Glass material (NSGlassEffectView) for the sidebar, the
// toolbar capsule, and the active tab. Translucent window (desktop shows
// through). Multi-tab, shared WebKit session. AI / ad-block / vault come later.

import Cocoa
import WebKit

enum C {
    static let accent   = NSColor(srgbRed: 0.357, green: 0.486, blue: 0.980, alpha: 1) // #5b7cfa
    static let text     = NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
    static let textSoft = NSColor(white: 1, alpha: 0.55)
}

let sharedConfig: WKWebViewConfiguration = {
    let c = WKWebViewConfiguration()
    c.websiteDataStore = .default()
    c.mediaTypesRequiringUserActionForPlayback = []
    c.defaultWebpagePreferences.allowsContentJavaScript = true
    if #available(macOS 13.3, *) { c.preferences.isElementFullscreenEnabled = true }
    return c
}()

final class Tab {
    let id = UUID()
    let webView: WKWebView
    var title = "New Tab"
    init() {
        webView = WKWebView(frame: .zero, configuration: sharedConfig)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 12
        webView.layer?.masksToBounds = true
    }
}

final class TabRow: NSView {
    let tab: Tab
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    init(tab: Tab, active: Bool) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        // active row reads as a brighter glassy pill; inactive is transparent
        layer?.backgroundColor = (active ? NSColor(white: 1, alpha: 0.16)
                                          : NSColor.clear).cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (active ? C.accent : C.textSoft).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        label.textColor = active ? C.text : C.textSoft
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.font = .systemFont(ofSize: 11)
        close.contentTintColor = C.textSoft
        close.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot); addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectClicked)))
    }
    required init?(coder: NSCoder) { nil }
    @objc func selectClicked() { onSelect?() }
    @objc func closeClicked() { onClose?() }
}

final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let window: NSWindow
    var tabs: [Tab] = []
    var active = 0
    let sidebarStack = NSStackView()
    let webContainer = NSView()
    let address = NSTextField()
    let back = NSButton(), forward = NSButton(), reload = NSButton()
    var titleObs: [UUID: NSKeyValueObservation] = [:]

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 832),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Breeze"
        window.isMovableByWindowBackground = true
        window.center()
        super.init()

        // Translucent window background — the desktop shows through (Tahoe look).
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        // ---- sidebar: a Liquid Glass panel ----
        let sidebarGlass = NSGlassEffectView()
        sidebarGlass.cornerRadius = 18
        sidebarGlass.translatesAutoresizingMaskIntoConstraints = false
        let sidebarContent = NSView()
        sidebarContent.translatesAutoresizingMaskIntoConstraints = false

        let newTabBtn = NSButton(title: "  +   New Tab", target: self, action: #selector(newTabClicked))
        newTabBtn.isBordered = false
        newTabBtn.contentTintColor = C.text
        newTabBtn.font = .systemFont(ofSize: 13.5, weight: .medium)
        newTabBtn.alignment = .left
        newTabBtn.translatesAutoresizingMaskIntoConstraints = false

        sidebarStack.orientation = .vertical
        sidebarStack.spacing = 2
        sidebarStack.alignment = .leading
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        sidebarContent.addSubview(newTabBtn)
        sidebarContent.addSubview(sidebarStack)
        sidebarGlass.contentView = sidebarContent

        // ---- toolbar capsule: nav buttons + address, all in one glass pill ----
        let barGlass = NSGlassEffectView()
        barGlass.cornerRadius = 18
        barGlass.translatesAutoresizingMaskIntoConstraints = false
        let barStack = NSStackView()
        barStack.orientation = .horizontal
        barStack.spacing = 6
        barStack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        barStack.translatesAutoresizingMaskIntoConstraints = false
        func styleNav(_ b: NSButton, _ t: String, _ s: Selector) {
            b.title = t; b.isBordered = false; b.font = .systemFont(ofSize: 15)
            b.contentTintColor = C.textSoft; b.target = self; b.action = s
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        styleNav(back, "􀯶", #selector(goBack))      // SF Symbol chevrons render if available;
        styleNav(forward, "􀰂", #selector(goForward)) // fall back to text on miss
        styleNav(reload, "􀅈", #selector(doReload))
        back.title = "‹"; forward.title = "›"; reload.title = "⟳"
        back.font = .systemFont(ofSize: 20); forward.font = .systemFont(ofSize: 20)

        address.placeholderString = "Search or enter URL"
        address.delegate = self
        address.font = .systemFont(ofSize: 13.5)
        address.textColor = C.text
        address.drawsBackground = false          // glass capsule is the background
        address.isBordered = false
        address.focusRingType = .none
        if let cell = address.cell as? NSTextFieldCell { cell.usesSingleLineMode = true }

        barStack.addArrangedSubview(back)
        barStack.addArrangedSubview(forward)
        barStack.addArrangedSubview(reload)
        barStack.addArrangedSubview(address)
        barGlass.contentView = barStack

        webContainer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebarGlass)
        root.addSubview(barGlass)
        root.addSubview(webContainer)

        NSLayoutConstraint.activate([
            // sidebar floats with margins
            sidebarGlass.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            sidebarGlass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            sidebarGlass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            sidebarGlass.widthAnchor.constraint(equalToConstant: 240),

            newTabBtn.topAnchor.constraint(equalTo: sidebarContent.topAnchor, constant: 12),
            newTabBtn.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 12),
            newTabBtn.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: newTabBtn.bottomAnchor, constant: 10),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor, constant: 8),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor, constant: -8),

            // toolbar capsule
            barGlass.topAnchor.constraint(equalTo: root.topAnchor, constant: 38),
            barGlass.leadingAnchor.constraint(equalTo: sidebarGlass.trailingAnchor, constant: 10),
            barGlass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            barGlass.heightAnchor.constraint(equalToConstant: 40),

            // web content, framed by the translucent window
            webContainer.topAnchor.constraint(equalTo: barGlass.bottomAnchor, constant: 10),
            webContainer.leadingAnchor.constraint(equalTo: sidebarGlass.trailingAnchor, constant: 10),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        newTab(url: "https://www.google.com")
    }

    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    func newTab(url: String) {
        let t = Tab()
        t.webView.navigationDelegate = self
        t.webView.uiDelegate = self
        titleObs[t.id] = t.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            t.title = (wv.title?.isEmpty == false) ? wv.title! : "New Tab"
            self?.rebuildSidebar(); self?.syncChrome()
        }
        tabs.append(t)
        active = tabs.count - 1
        showActive(); rebuildSidebar()
        if let u = URL(string: url) { t.webView.load(URLRequest(url: u)) }
        window.makeFirstResponder(address)
    }

    func closeTab(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        titleObs[t.id] = nil
        t.webView.removeFromSuperview()
        tabs.remove(at: i)
        if tabs.isEmpty { newTab(url: "https://www.google.com"); return }
        active = min(active, tabs.count - 1)
        showActive(); rebuildSidebar()
    }

    func select(_ i: Int) { active = i; showActive(); rebuildSidebar() }

    func showActive() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let t = current else { return }
        webContainer.addSubview(t.webView)
        NSLayoutConstraint.activate([
            t.webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            t.webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            t.webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            t.webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
        ])
        syncChrome()
    }

    func rebuildSidebar() {
        sidebarStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in tabs.enumerated() {
            let row = TabRow(tab: t, active: i == active)
            row.onSelect = { [weak self] in self?.select(i) }
            row.onClose = { [weak self] in self?.closeTab(t) }
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }

    func syncChrome() {
        guard let wv = current?.webView else { return }
        back.isEnabled = wv.canGoBack
        forward.isEnabled = wv.canGoForward
        if window.firstResponder != address.currentEditor(), let u = wv.url?.absoluteString {
            address.stringValue = u
        }
    }

    func navigate(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let t = current else { return }
        var s = q
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { if !q.contains("://") { s = "https://" + q } }
        else {
            let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            s = "https://www.google.com/search?q=\(e)"
        }
        if let u = URL(string: s) { t.webView.load(URLRequest(url: u)) }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { navigate(address.stringValue); return true }
        return false
    }

    @objc func newTabClicked() { newTab(url: "https://www.google.com") }
    @objc func goBack() { current?.webView.goBack() }
    @objc func goForward() { current?.webView.goForward() }
    @objc func doReload() { current?.webView.reload() }
    @objc func focusAddress() { window.makeFirstResponder(address); address.currentEditor()?.selectAll(nil) }
    @objc func closeCurrentTab() { if let t = current { closeTab(t) } }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { syncChrome() }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { syncChrome() }
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { newTab(url: u.absoluteString) }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: Browser?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        browser = Browser()
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    @objc func newTab() { browser?.newTabClicked() }
    @objc func closeTab() { browser?.closeCurrentTab() }
    @objc func focusAddr() { browser?.focusAddress() }
    @objc func reload() { browser?.doReload() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

let mainMenu = NSMenu()
let appItem = NSMenuItem(); mainMenu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Breeze", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu

let fileItem = NSMenuItem(); mainMenu.addItem(fileItem)
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t")
fileMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeTab), keyEquivalent: "w")
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
