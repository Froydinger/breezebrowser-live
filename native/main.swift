// Breeze Native — M1: the browser shell.
// Native macOS (AppKit + WKWebView/WebKit) rebuild of Breeze. This milestone:
// multiple tabs in a left sidebar, shared WebKit session, top nav + address bar,
// dark "Breeze" styling. AI / ad-block / vault come in later milestones.

import Cocoa
import WebKit

// ---- Breeze palette ----
enum C {
    static let bg      = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.102, alpha: 1) // #16161a
    static let sidebar = NSColor(srgbRed: 0.110, green: 0.110, blue: 0.129, alpha: 1) // #1c1c21
    static let surface = NSColor(white: 1, alpha: 0.06)
    static let surfaceHi = NSColor(white: 1, alpha: 0.10)
    static let accent  = NSColor(srgbRed: 0.357, green: 0.486, blue: 0.980, alpha: 1) // #5b7cfa
    static let text    = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.941, alpha: 1)
    static let textSoft = NSColor(white: 1, alpha: 0.45)
}

// One shared session so cookies/logins are consistent across tabs.
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
    }
}

// A single sidebar row (favicon dot + title + close button).
final class TabRow: NSView {
    let tab: Tab
    let titleLabel = NSTextField(labelWithString: "")
    let close = NSButton()
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    private let bg = NSView()

    init(tab: Tab, active: Bool) {
        self.tab = tab
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        bg.wantsLayer = true
        bg.layer?.cornerRadius = 9
        bg.layer?.backgroundColor = (active ? C.surfaceHi : NSColor.clear).cgColor
        bg.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bg)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (active ? C.accent : C.textSoft).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = tab.title
        titleLabel.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        titleLabel.textColor = active ? C.text : C.textSoft
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        close.title = "✕"
        close.isBordered = false
        close.font = .systemFont(ofSize: 11)
        close.contentTintColor = C.textSoft
        close.target = self
        close.action = #selector(closeClicked)
        close.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot); addSubview(titleLabel); addSubview(close)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bg.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            bg.leadingAnchor.constraint(equalTo: leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 34),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 18),
        ])
        let clickGR = NSClickGestureRecognizer(target: self, action: #selector(selectClicked))
        addGestureRecognizer(clickGR)
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
        window.backgroundColor = C.bg
        window.center()
        super.init()

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = C.bg.cgColor

        // ---- sidebar ----
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = C.sidebar.cgColor
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let newTabBtn = NSButton(title: "  +  New Tab", target: self, action: #selector(newTabClicked))
        newTabBtn.isBordered = false
        newTabBtn.contentTintColor = C.text
        newTabBtn.font = .systemFont(ofSize: 13, weight: .medium)
        newTabBtn.alignment = .left
        newTabBtn.translatesAutoresizingMaskIntoConstraints = false

        sidebarStack.orientation = .vertical
        sidebarStack.spacing = 2
        sidebarStack.alignment = .leading
        sidebarStack.distribution = .fill
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        sidebar.addSubview(newTabBtn)
        sidebar.addSubview(sidebarStack)

        // ---- top bar (nav + address) ----
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.translatesAutoresizingMaskIntoConstraints = false
        func styleNav(_ b: NSButton, _ t: String, _ s: Selector) {
            b.title = t; b.isBordered = false; b.font = .systemFont(ofSize: 15)
            b.contentTintColor = C.textSoft; b.target = self; b.action = s
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        styleNav(back, "◀", #selector(goBack))
        styleNav(forward, "▶", #selector(goForward))
        styleNav(reload, "⟳", #selector(doReload))
        address.placeholderString = "Search or enter URL"
        address.delegate = self
        address.font = .systemFont(ofSize: 13.5)
        address.textColor = C.text
        address.drawsBackground = true
        address.backgroundColor = C.surface
        address.isBordered = false
        address.focusRingType = .none
        address.wantsLayer = true
        address.layer?.cornerRadius = 9
        if let cell = address.cell as? NSTextFieldCell { cell.usesSingleLineMode = true }
        bar.addArrangedSubview(back); bar.addArrangedSubview(forward); bar.addArrangedSubview(reload)
        bar.addArrangedSubview(address)

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true
        webContainer.layer?.backgroundColor = C.bg.cgColor

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(bar); main.addSubview(webContainer)

        root.addSubview(sidebar); root.addSubview(main)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 250),

            newTabBtn.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 40),
            newTabBtn.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            newTabBtn.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            sidebarStack.topAnchor.constraint(equalTo: newTabBtn.bottomAnchor, constant: 10),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            bar.topAnchor.constraint(equalTo: main.topAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -12),
            address.heightAnchor.constraint(equalToConstant: 34),

            webContainer.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            webContainer.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: main.bottomAnchor),
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
        showActive()
        rebuildSidebar()
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Menu with the expected browser shortcuts.
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
app.mainMenu = mainMenu

// Edit menu so copy/paste/select-all work in the address bar + web pages.
let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu

extension AppDelegate {
    @objc func newTab() { browser?.newTabClicked() }
    @objc func closeTab() { browser?.closeCurrentTab() }
    @objc func focusAddr() { browser?.focusAddress() }
    @objc func reload() { browser?.doReload() }
}

app.run()
