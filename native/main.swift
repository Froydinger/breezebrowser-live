// Breeze Native — M1.5: Dynamic Liquid-Glass URL bar + glass polish.
// AppKit + WKWebView on macOS 26 (Liquid Glass / NSGlassEffectView).
// Thin top strip with Back/Fwd · centered host chip · Reload/Clear. The chip is
// a glass pill that springs open IN PLACE into a full URL bar floating over the
// page on hover/focus, then shrinks back. ⌘S toggles the sidebar. Translucent
// window, merged glass, soft borders.

import Cocoa
import WebKit

enum C {
    static let accent   = NSColor(srgbRed: 0.357, green: 0.486, blue: 0.980, alpha: 1)
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

func hostOf(_ url: URL?) -> String {
    guard let h = url?.host else { return "" }
    return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
}

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
        webView.layer?.cornerRadius = 11
        webView.layer?.masksToBounds = true
    }
}

final class TabRow: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    init(title: String, active: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = (active ? NSColor(white: 1, alpha: 0.08) : .clear).cgColor
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = (active ? C.accent : C.textSoft).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        label.textColor = active ? C.text : C.textSoft
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let close = NSButton(title: "✕", target: self, action: #selector(closeClicked))
        close.isBordered = false; close.font = .systemFont(ofSize: 10)
        close.contentTintColor = C.textSoft
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(label); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectClicked)))
    }
    required init?(coder: NSCoder) { nil }
    @objc func selectClicked() { onSelect?() }
    @objc func closeClicked() { onClose?() }
}

// Glass pill that reports hover + click so it can morph between chip ↔ URL bar.
final class ChipGlass: NSGlassEffectView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    private var trk: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trk { removeTrackingArea(trk) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trk = t
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func mouseExited(with e: NSEvent)  { onExit?() }
    override func mouseDown(with e: NSEvent)    { onClick?() }
}

final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let window: NSWindow
    var tabs: [Tab] = []
    var active = 0
    var titleObs: [UUID: NSKeyValueObservation] = [:]

    // chrome
    let sidebarGlass = NSGlassEffectView()
    var sidebarWidth: NSLayoutConstraint!
    let sidebarStack = NSStackView()
    let stripGlass = NSGlassEffectView()
    let back = NSButton(), forward = NSButton(), reload = NSButton(), clearBtn = NSButton()
    let webContainer = NSView()
    let overlay = NSView()        // hosts the floating url glass (bottom-left coords)

    // morphing url bar
    let urlGlass = ChipGlass()
    let favicon = NSImageView()
    let hostLabel = NSTextField(labelWithString: "")
    let address = NSTextField()
    var expanded = false
    var sidebarHidden = false
    var faviconCache: [String: NSImage] = [:]

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 832),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Breeze"
        window.center()
        super.init()
        window.delegate = self

        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        // glass container so sidebar + strip rims merge (softer borders)
        let glassContainer = NSGlassEffectContainerView()
        glassContainer.spacing = 22
        glassContainer.translatesAutoresizingMaskIntoConstraints = false
        let glassContent = NSView()
        glassContent.translatesAutoresizingMaskIntoConstraints = false
        glassContainer.contentView = glassContent

        // sidebar
        sidebarGlass.cornerRadius = 16
        sidebarGlass.translatesAutoresizingMaskIntoConstraints = false
        let sideInner = NSView(); sideInner.translatesAutoresizingMaskIntoConstraints = false
        let newTabBtn = NSButton(title: "  +   New Tab", target: self, action: #selector(newTabClicked))
        newTabBtn.isBordered = false; newTabBtn.contentTintColor = C.text
        newTabBtn.font = .systemFont(ofSize: 13.5, weight: .medium); newTabBtn.alignment = .left
        newTabBtn.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.orientation = .vertical; sidebarStack.spacing = 2; sidebarStack.alignment = .leading
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sideInner.addSubview(newTabBtn); sideInner.addSubview(sidebarStack)
        sidebarGlass.contentView = sideInner

        // strip (thin, holds buttons; chip floats centered over it)
        stripGlass.cornerRadius = 16
        stripGlass.translatesAutoresizingMaskIntoConstraints = false
        let stripInner = NSView(); stripInner.translatesAutoresizingMaskIntoConstraints = false
        func nav(_ b: NSButton, _ t: String, _ s: Selector, _ size: CGFloat) {
            b.title = t; b.isBordered = false; b.font = .systemFont(ofSize: size)
            b.contentTintColor = C.textSoft; b.target = self; b.action = s
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        nav(back, "‹", #selector(goBack), 22)
        nav(forward, "›", #selector(goForward), 22)
        nav(reload, "⟳", #selector(doReload), 15)
        nav(clearBtn, "⌫", #selector(clearCache), 14)
        let leftCluster = NSStackView(views: [back, forward]); leftCluster.spacing = 2
        leftCluster.translatesAutoresizingMaskIntoConstraints = false
        let rightCluster = NSStackView(views: [reload, clearBtn]); rightCluster.spacing = 6
        rightCluster.translatesAutoresizingMaskIntoConstraints = false
        stripInner.addSubview(leftCluster); stripInner.addSubview(rightCluster)
        stripGlass.contentView = stripInner

        glassContent.addSubview(sidebarGlass)
        glassContent.addSubview(stripGlass)

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(glassContainer)
        root.addSubview(webContainer)
        root.addSubview(overlay)          // floats above the page

        // ---- url glass content (chip + editable address overlaid, cross-faded)
        urlGlass.cornerRadius = 14
        favicon.translatesAutoresizingMaskIntoConstraints = false
        favicon.imageScaling = .scaleProportionallyDown
        hostLabel.font = .systemFont(ofSize: 13, weight: .medium)
        hostLabel.textColor = C.text
        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        let chipRow = NSStackView(views: [favicon, hostLabel]); chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        address.placeholderString = "Search or enter URL"
        address.delegate = self
        address.font = .systemFont(ofSize: 13.5); address.textColor = C.text
        address.drawsBackground = false; address.isBordered = false; address.focusRingType = .none
        address.alphaValue = 0
        address.translatesAutoresizingMaskIntoConstraints = false
        if let cell = address.cell as? NSTextFieldCell { cell.usesSingleLineMode = true }
        let body = NSView()
        body.addSubview(chipRow); body.addSubview(address)
        NSLayoutConstraint.activate([
            chipRow.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            chipRow.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            favicon.widthAnchor.constraint(equalToConstant: 15), favicon.heightAnchor.constraint(equalToConstant: 15),
            address.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14),
            address.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
            address.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
        urlGlass.contentView = body
        overlay.addSubview(urlGlass)

        urlGlass.onEnter = { [weak self] in self?.setExpanded(true) }
        urlGlass.onExit  = { [weak self] in self?.scheduleCollapse() }
        urlGlass.onClick = { [weak self] in self?.setExpanded(true); self?.focusAddress() }

        sidebarWidth = sidebarGlass.widthAnchor.constraint(equalToConstant: 240)
        NSLayoutConstraint.activate([
            glassContainer.topAnchor.constraint(equalTo: root.topAnchor),
            glassContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            glassContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            glassContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            sidebarGlass.topAnchor.constraint(equalTo: glassContent.topAnchor, constant: 38),
            sidebarGlass.leadingAnchor.constraint(equalTo: glassContent.leadingAnchor, constant: 10),
            sidebarGlass.bottomAnchor.constraint(equalTo: glassContent.bottomAnchor, constant: -10),
            sidebarWidth,

            newTabBtn.topAnchor.constraint(equalTo: sideInner.topAnchor, constant: 12),
            newTabBtn.leadingAnchor.constraint(equalTo: sideInner.leadingAnchor, constant: 12),
            newTabBtn.trailingAnchor.constraint(equalTo: sideInner.trailingAnchor, constant: -12),
            sidebarStack.topAnchor.constraint(equalTo: newTabBtn.bottomAnchor, constant: 10),
            sidebarStack.leadingAnchor.constraint(equalTo: sideInner.leadingAnchor, constant: 8),
            sidebarStack.trailingAnchor.constraint(equalTo: sideInner.trailingAnchor, constant: -8),

            stripGlass.topAnchor.constraint(equalTo: glassContent.topAnchor, constant: 38),
            stripGlass.leadingAnchor.constraint(equalTo: sidebarGlass.trailingAnchor, constant: 10),
            stripGlass.trailingAnchor.constraint(equalTo: glassContent.trailingAnchor, constant: -10),
            stripGlass.heightAnchor.constraint(equalToConstant: 44),
            leftCluster.leadingAnchor.constraint(equalTo: stripInner.leadingAnchor, constant: 10),
            leftCluster.centerYAnchor.constraint(equalTo: stripInner.centerYAnchor),
            rightCluster.trailingAnchor.constraint(equalTo: stripInner.trailingAnchor, constant: -12),
            rightCluster.centerYAnchor.constraint(equalTo: stripInner.centerYAnchor),

            webContainer.topAnchor.constraint(equalTo: stripGlass.bottomAnchor, constant: 8),
            webContainer.leadingAnchor.constraint(equalTo: sidebarGlass.trailingAnchor, constant: 10),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            overlay.topAnchor.constraint(equalTo: root.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        newTab(url: "https://www.google.com")
    }

    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    // ---- geometry for the morphing chip (bottom-left coords in `overlay`) ----
    var mainLeft: CGFloat { sidebarHidden ? 16 : 260 }
    func chipFrame() -> NSRect {
        let h = overlay.bounds.height, w = overlay.bounds.width
        let host = hostLabel.stringValue.isEmpty ? "New Tab" : hostLabel.stringValue
        let tw = (host as NSString).size(withAttributes: [.font: hostLabel.font as Any]).width
        let cw = min(max(tw + 58, 120), 360), ch: CGFloat = 30
        let cx = mainLeft + (w - 10 - mainLeft) / 2
        let topY: CGFloat = 38 + (44 - ch) / 2          // centered in the 44pt strip
        return NSRect(x: cx - cw / 2, y: h - topY - ch, width: cw, height: ch)
    }
    func expandedFrame() -> NSRect {
        let h = overlay.bounds.height, w = overlay.bounds.width
        let ew = min(720, w - 10 - mainLeft - 24), eh: CGFloat = 42
        let cx = mainLeft + (w - 10 - mainLeft) / 2
        let topY: CGFloat = 38 + 44 + 6                 // floats just below the strip
        return NSRect(x: cx - ew / 2, y: h - topY - eh, width: ew, height: eh)
    }

    func setExpanded(_ on: Bool, animated: Bool = true) {
        if expanded == on, urlGlass.frame != .zero { return }
        expanded = on
        let target = on ? expandedFrame() : chipFrame()
        let oldCenter = NSPoint(x: urlGlass.frame.midX, y: urlGlass.frame.midY)
        let oldSize = urlGlass.frame.size
        urlGlass.frame = target
        urlGlass.cornerRadius = on ? 12 : 14
        if animated, let layer = urlGlass.layer, oldSize.width > 0 {
            let pos = CASpringAnimation(keyPath: "position")
            pos.fromValue = NSValue(point: oldCenter)
            pos.toValue = NSValue(point: NSPoint(x: target.midX, y: target.midY))
            let bnd = CASpringAnimation(keyPath: "bounds.size")
            bnd.fromValue = NSValue(size: oldSize)
            bnd.toValue = NSValue(size: target.size)
            for a in [pos, bnd] { a.mass = 1; a.stiffness = 240; a.damping = 22; a.duration = a.settlingDuration }
            layer.add(pos, forKey: "morphPos"); layer.add(bnd, forKey: "morphSize")
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            address.animator().alphaValue = on ? 1 : 0
            (favicon.superview ?? favicon).animator().alphaValue = on ? 0 : 1
        }
        if !on { restoreHost() }
    }

    func scheduleCollapse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            if self.window.firstResponder === self.address.currentEditor() { return }
            let p = self.overlay.convert(self.window.mouseLocationOutsideOfEventStream, from: nil)
            if self.urlGlass.frame.insetBy(dx: -4, dy: -4).contains(p) { return }
            self.setExpanded(false)
        }
    }

    func restoreHost() { address.stringValue = hostOf(current?.webView.url) }

    func newTab(url: String) {
        let t = Tab()
        t.webView.navigationDelegate = self
        t.webView.uiDelegate = self
        titleObs[t.id] = t.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            t.title = (wv.title?.isEmpty == false) ? wv.title! : "New Tab"
            self?.rebuildSidebar(); self?.syncChrome()
        }
        tabs.append(t); active = tabs.count - 1
        showActive(); rebuildSidebar()
        if let u = URL(string: url) { t.webView.load(URLRequest(url: u)) }
        setExpanded(true); focusAddress()
    }
    func closeTab(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        titleObs[t.id] = nil; t.webView.removeFromSuperview(); tabs.remove(at: i)
        if tabs.isEmpty { newTab(url: "https://www.google.com"); return }
        active = min(active, tabs.count - 1); showActive(); rebuildSidebar()
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
            let row = TabRow(title: t.title, active: i == active)
            row.onSelect = { [weak self] in self?.select(i) }
            row.onClose = { [weak self] in self?.closeTab(t) }
            sidebarStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor).isActive = true
        }
    }
    func syncChrome() {
        guard let wv = current?.webView else { return }
        back.isEnabled = wv.canGoBack; forward.isEnabled = wv.canGoForward
        let host = hostOf(wv.url)
        hostLabel.stringValue = host.isEmpty ? "New Tab" : host
        if !expanded { address.stringValue = host }
        loadFavicon(for: host)
        if !expanded { urlGlass.frame = chipFrame() }   // re-hug width to new host
    }

    func loadFavicon(for host: String) {
        guard !host.isEmpty else { favicon.image = nil; return }
        if let img = faviconCache[host] { favicon.image = img; return }
        guard let u = URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=64") else { return }
        URLSession.shared.dataTask(with: u) { [weak self] d, _, _ in
            guard let d, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async { self?.faviconCache[host] = img
                if self?.hostLabel.stringValue == host || hostOf(self?.current?.webView.url) == host { self?.favicon.image = img } }
        }.resume()
    }

    func navigate(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let t = current else { return }
        var s = q
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { if !q.contains("://") { s = "https://" + q } }
        else { let e = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
               s = "https://www.google.com/search?q=\(e)" }
        if let u = URL(string: s) { t.webView.load(URLRequest(url: u)) }
    }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            navigate(address.stringValue); window.makeFirstResponder(nil); setExpanded(false); return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            window.makeFirstResponder(nil); setExpanded(false); return true
        }
        return false
    }
    func controlTextDidEndEditing(_ obj: Notification) { scheduleCollapse() }

    @objc func newTabClicked() { newTab(url: "https://www.google.com") }
    @objc func goBack() { current?.webView.goBack() }
    @objc func goForward() { current?.webView.goForward() }
    @objc func doReload() { current?.webView.reload() }
    @objc func focusAddress() {
        address.stringValue = current?.webView.url?.absoluteString ?? ""
        window.makeFirstResponder(address); address.currentEditor()?.selectAll(nil)
    }
    @objc func closeCurrentTab() { if let t = current { closeTab(t) } }
    @objc func clearCache() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { [weak self] in
                self?.current?.webView.reload()
            }
        }
    }
    @objc func toggleSidebar() {
        sidebarHidden.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28; ctx.allowsImplicitAnimation = true
            sidebarWidth.constant = sidebarHidden ? 0 : 240
            sidebarGlass.alphaValue = sidebarHidden ? 0 : 1
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if !expanded { urlGlass.frame = chipFrame() }
    }

    func windowDidResize(_ n: Notification) {
        urlGlass.frame = expanded ? expandedFrame() : chipFrame()
    }

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
        NSApp.setActivationPolicy(.regular); browser = Browser(); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    @objc func newTab() { browser?.newTabClicked() }
    @objc func closeTab() { browser?.closeCurrentTab() }
    @objc func focusAddr() { browser?.setExpanded(true); browser?.focusAddress() }
    @objc func reload() { browser?.doReload() }
    @objc func toggleSidebar() { browser?.toggleSidebar() }
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

let viewItem = NSMenuItem(); mainMenu.addItem(viewItem)
let viewMenu = NSMenu(title: "View")
viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebar), keyEquivalent: "s")
viewItem.submenu = viewMenu

let editItem = NSMenuItem(); mainMenu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = mainMenu

app.run()
