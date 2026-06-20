// The browser window: sidebar (pins + tabs + footer), top URL bar, web views,
// and the native new-tab page. Look ported from ui/index.html + style.css
// (urlbar-top mode, matching the screenshots).

import Cocoa
import WebKit

let SIDEBAR_W: CGFloat = 280

final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSWindowDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    let window: NSWindow
    var tabs: [Tab] = []
    var active = 0
    var pins: [Pin] = []
    var pinSize: PinSize = .large      // Settings: small / medium / large
    var downloads: [DownloadItem] = []
    var downloadList: [[String: Any]] { downloads.map { $0.dict } }
    var groups: [TabGroup] = []        // session-only tab groups
    var nextGroupId = 1
    var titleObs: [UUID: NSKeyValueObservation] = [:]
    var urlObs: [UUID: NSKeyValueObservation] = [:]

    // chrome
    let root = GradientBackgroundView()
    let sidebar = NSView()
    var sidebarHidden = false
    var sidebarLeft: NSLayoutConstraint!
    let pinsStack = NSStackView()
    let tabsStack = NSStackView()
    let webContainer = NSView()
    let newTab = NewTabView()
    let nowPlaying = NowPlayingView()
    var nowPlayingTab: Tab?

    // top bar
    let topBar = NSView()
    let back = HoverButton(symbol: "chevron.left", point: 14)
    let forward = HoverButton(symbol: "chevron.right", point: 14)
    let reload = HoverButton(symbol: "arrow.clockwise", point: 13)
    let addressWrap = NSView()
    let address = NSTextField()
    let bookmarkBtn = HoverButton(symbol: "bookmark", size: 22, point: 12)
    let breezeCorner = NSButton()

    // footer
    let adblockPill = NSView()
    let adblockCount = NSTextField(labelWithString: "0")

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
        window.isMovableByWindowBackground = true

        root.wantsLayer = true
        buildSidebar()
        buildTopBar()
        buildWebArea()

        root.addSubview(webContainer)
        root.addSubview(sidebar)
        root.addSubview(topBar)

        sidebarLeft = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 0)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SIDEBAR_W),
            sidebarLeft,

            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -54),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            // always clear the macOS traffic lights, even when the sidebar hides
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 82),
        ])
        let topLeadToSidebar = topBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 6)
        topLeadToSidebar.priority = .defaultHigh   // yields to the >=82 clearance when sidebar hides
        topLeadToSidebar.isActive = true
        NSLayoutConstraint.activate([

            webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            webContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 2),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])

        // breeze corner mark — pinned top-right of the window
        root.addSubview(breezeCorner)
        breezeCorner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            breezeCorner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            breezeCorner.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            breezeCorner.widthAnchor.constraint(equalToConstant: 30),
            breezeCorner.heightAnchor.constraint(equalToConstant: 30),
        ])

        window.contentView = root
        window.makeKeyAndOrderFront(nil)

        // load persisted state + apply settings
        pins = Store.shared.pins
        pinSize = PinSize(rawValue: Store.shared.string("pinSize")) ?? .large
        applyThemeFromSettings()
        sharedConfig.userContentController.add(self, name: "breezeMsg")
        sharedConfig.userContentController.add(self, name: "breezeMedia")

        renderPins()
        openNewTab()
    }

    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    // MARK: - Sidebar -------------------------------------------------------

    func buildSidebar() {
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // drag strip: traffic-light pad + sidebar toggle + new tab + downloads
        let tlPad = NSView(); tlPad.translatesAutoresizingMaskIntoConstraints = false
        tlPad.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let toggle = HoverButton(symbol: "sidebar.left"); toggle.onTap = { [weak self] in self?.toggleSidebar() }
        let plus = HoverButton(symbol: "plus"); plus.onTap = { [weak self] in self?.openNewTab() }
        let dl = HoverButton(symbol: "arrow.down.to.line"); dl.onTap = { [weak self] in self?.openInternal(.downloads) }
        let dragFill = NSView(); dragFill.translatesAutoresizingMaskIntoConstraints = false
        dragFill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let strip = NSStackView(views: [tlPad, toggle, dragFill, plus, dl])
        strip.spacing = 3; strip.alignment = .centerY
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.heightAnchor.constraint(equalToConstant: 40).isActive = true

        // pins grid (4-wide rows)
        pinsStack.orientation = .vertical; pinsStack.spacing = 7; pinsStack.alignment = .leading
        pinsStack.translatesAutoresizingMaskIntoConstraints = false

        // tabs
        tabsStack.orientation = .vertical; tabsStack.spacing = 3; tabsStack.alignment = .leading
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        let tabsDoc = FlippedView()
        tabsDoc.translatesAutoresizingMaskIntoConstraints = false
        tabsDoc.addSubview(tabsStack)
        let tabsScroll = NSScrollView()
        tabsScroll.drawsBackground = false
        tabsScroll.hasVerticalScroller = false
        tabsScroll.translatesAutoresizingMaskIntoConstraints = false
        tabsScroll.documentView = tabsDoc

        // footer + now-playing card live in a bottom stack so the card can
        // collapse the layout when hidden.
        let footer = buildFooter()
        nowPlaying.isHidden = true
        nowPlaying.playBtn.onTap = { [weak self] in self?.toggleNowPlaying() }
        nowPlaying.pipBtn.onTap = { [weak self] in self?.nowPlayingPip() }
        nowPlaying.backBtn.onTap = { [weak self] in self?.backToNowPlaying() }
        let bottomStack = NSStackView(views: [nowPlaying, footer])
        bottomStack.orientation = .vertical; bottomStack.spacing = 8; bottomStack.alignment = .leading
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        nowPlaying.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true

        sidebar.addSubview(strip)
        sidebar.addSubview(pinsStack)
        sidebar.addSubview(tabsScroll)
        sidebar.addSubview(bottomStack)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12),
            strip.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            strip.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            pinsStack.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12),
            pinsStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            pinsStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            tabsScroll.topAnchor.constraint(equalTo: pinsStack.bottomAnchor, constant: 14),
            tabsScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            tabsScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            tabsScroll.bottomAnchor.constraint(equalTo: bottomStack.topAnchor, constant: -10),
            tabsDoc.widthAnchor.constraint(equalTo: tabsScroll.contentView.widthAnchor),
            tabsStack.topAnchor.constraint(equalTo: tabsDoc.topAnchor),
            tabsStack.leadingAnchor.constraint(equalTo: tabsDoc.leadingAnchor),
            tabsStack.trailingAnchor.constraint(equalTo: tabsDoc.trailingAnchor),
            tabsStack.bottomAnchor.constraint(equalTo: tabsDoc.bottomAnchor),

            bottomStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            bottomStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            bottomStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])
    }

    func buildFooter() -> NSView {
        let footer = NSView(); footer.translatesAutoresizingMaskIntoConstraints = false

        adblockPill.wantsLayer = true; adblockPill.layer?.cornerRadius = 12
        adblockPill.translatesAutoresizingMaskIntoConstraints = false
        let shield = NSImageView()
        shield.image = NSImage(systemSymbolName: "shield", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        shield.translatesAutoresizingMaskIntoConstraints = false
        adblockCount.font = .systemFont(ofSize: 11.5)
        adblockCount.translatesAutoresizingMaskIntoConstraints = false
        adblockPill.addSubview(shield); adblockPill.addSubview(adblockCount)
        NSLayoutConstraint.activate([
            adblockPill.heightAnchor.constraint(equalToConstant: 24),
            shield.leadingAnchor.constraint(equalTo: adblockPill.leadingAnchor, constant: 10),
            shield.centerYAnchor.constraint(equalTo: adblockPill.centerYAnchor),
            adblockCount.leadingAnchor.constraint(equalTo: shield.trailingAnchor, constant: 6),
            adblockCount.centerYAnchor.constraint(equalTo: adblockPill.centerYAnchor),
            adblockCount.trailingAnchor.constraint(equalTo: adblockPill.trailingAnchor, constant: -10),
        ])

        let settings = HoverButton(symbol: "gearshape")
        settings.onTap = { [weak self] in self?.openInternal(.settings) }
        let bookmarks = HoverButton(symbol: "bookmark")
        bookmarks.onTap = { [weak self] in self?.openInternal(.bookmarks) }
        let history = HoverButton(symbol: "clock")
        history.onTap = { [weak self] in self?.openInternal(.history) }
        let theme = HoverButton(symbol: "sun.max"); theme.onTap = { [weak self] in
            self?.cycleThemeSetting(); self?.refreshThemeIcon(theme)
        }
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [adblockPill, spacer, settings, bookmarks, history, theme])
        row.spacing = 4; row.alignment = .centerY
        footer.addSubview(row)
        row.pin(to: footer)
        refreshThemeIcon(theme)
        return footer
    }

    func cycleThemeSetting() {   // Light → Dark → System, persisted
        let next: String
        switch Store.shared.string("theme") {
        case "light": next = "dark"
        case "dark":  next = "system"
        default:      next = "light"
        }
        Store.shared.settings["theme"] = next; Store.shared.saveSettings()
        applySettingsChange()
    }

    func refreshThemeIcon(_ b: HoverButton) {
        switch Theme.shared.mode {
        case .light:  b.symbol = "sun.max"
        case .dark:   b.symbol = "moon"
        case .system: b.symbol = "desktopcomputer"
        }
    }

    func renderPins() {
        pinsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !pins.isEmpty else { return }
        let gap: CGFloat = 7
        let contentW = SIDEBAR_W - 14 - 10
        // auto-fill columns at the chosen min size, cells stretch to fill (1fr).
        let cols = max(1, Int((contentW + gap) / (pinSize.minPt + gap)))
        let cell = floor((contentW - CGFloat(cols - 1) * gap) / CGFloat(cols))
        var row: NSStackView? = nil
        var inRow = 0
        for (i, p) in pins.enumerated() {
            if i % cols == 0 {
                let r = NSStackView(); r.spacing = gap; r.distribution = .fillEqually; r.alignment = .centerY
                r.translatesAutoresizingMaskIntoConstraints = false
                r.widthAnchor.constraint(equalToConstant: contentW).isActive = true
                pinsStack.addArrangedSubview(r); row = r; inRow = 0
            }
            let v = PinView(pin: p)
            v.heightAnchor.constraint(equalToConstant: cell).isActive = true   // square (width = cell via fillEqually)
            v.onSelect = { [weak self] in self?.openTab(url: p.url) }
            v.onUnpin = { [weak self] in self?.unpin(p.url) }
            row?.addArrangedSubview(v); inRow += 1
        }
        // pad the last row so fillEqually keeps real pins at one cell width.
        if let r = row, inRow < cols {
            for _ in inRow..<cols {
                let ph = NSView(); ph.translatesAutoresizingMaskIntoConstraints = false
                r.addArrangedSubview(ph)
            }
        }
    }

    // MARK: - Top bar -------------------------------------------------------

    func buildTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        back.onTap = { [weak self] in self?.current?.webView.goBack() }
        forward.onTap = { [weak self] in self?.current?.webView.goForward() }
        reload.onTap = { [weak self] in self?.current?.webView.reload() }

        addressWrap.wantsLayer = true; addressWrap.layer?.cornerRadius = 10
        addressWrap.translatesAutoresizingMaskIntoConstraints = false
        let copylink = HoverButton(symbol: "link", size: 22, point: 12)
        copylink.onTap = { [weak self] in if let t = self?.current { self?.copyLink(t) } }
        address.placeholderString = "Search or enter URL"
        address.font = .systemFont(ofSize: 13.5)
        address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.translatesAutoresizingMaskIntoConstraints = false
        address.delegate = self
        address.target = self; address.action = #selector(addressSubmit)
        let clearc = HoverButton(symbol: "trash", size: 22, point: 11)
        clearc.onTap = { [weak self] in self?.clearCache() }
        bookmarkBtn.onTap = { [weak self] in self?.toggleBookmark() }
        let share = HoverButton(symbol: "square.and.arrow.up", size: 22, point: 12)
        addressWrap.addSubview(copylink); addressWrap.addSubview(address)
        addressWrap.addSubview(clearc); addressWrap.addSubview(bookmarkBtn); addressWrap.addSubview(share)
        let actions = NSStackView(views: [clearc, bookmarkBtn, share]); actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        addressWrap.addSubview(actions)
        NSLayoutConstraint.activate([
            copylink.leadingAnchor.constraint(equalTo: addressWrap.leadingAnchor, constant: 6),
            copylink.centerYAnchor.constraint(equalTo: addressWrap.centerYAnchor),
            address.leadingAnchor.constraint(equalTo: copylink.trailingAnchor, constant: 6),
            address.centerYAnchor.constraint(equalTo: addressWrap.centerYAnchor),
            address.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -6),
            actions.trailingAnchor.constraint(equalTo: addressWrap.trailingAnchor, constant: -6),
            actions.centerYAnchor.constraint(equalTo: addressWrap.centerYAnchor),
        ])

        let nav = NSStackView(views: [back, forward, reload]); nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(nav); topBar.addSubview(addressWrap)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 2),
            nav.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addressWrap.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 8),
            addressWrap.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            addressWrap.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addressWrap.heightAnchor.constraint(equalToConstant: 38),
        ])

        breezeCorner.isBordered = false
        breezeCorner.image = breezeLogo()
        breezeCorner.imageScaling = .scaleProportionallyDown
        breezeCorner.target = self; breezeCorner.action = #selector(openAssistant)
    }

    // MARK: - Web area ------------------------------------------------------

    func buildWebArea() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true
        newTab.translatesAutoresizingMaskIntoConstraints = false
        newTab.onSubmit = { [weak self] t in self?.navigate(t) }
    }

    func showActive() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let t = current else { return }
        let view: NSView = t.isNewTab ? newTab : t.webView
        webContainer.addSubview(view)
        view.pin(to: webContainer)
        if t.isNewTab { newTab.startClock() } else { newTab.stopClock() }
        syncChrome()
    }

    func makeTabRow(_ t: Tab) -> TabRowView {
        let i = tabs.firstIndex { $0.id == t.id } ?? 0
        let row = TabRowView(title: t.title, host: hostOf(t.webView.url), active: i == active)
        row.canPin = !t.isNewTab && t.webView.url != nil
        row.onSelect = { [weak self] in self?.select(i) }
        row.onClose = { [weak self] in self?.closeTab(t) }
        row.onPin = { [weak self] in self?.pinTab(t) }
        row.onCloseOthers = { [weak self] in self?.closeOthers(keep: t) }
        row.onCopyLink = { [weak self] in self?.copyLink(t) }
        row.extraMenu = groupEntries(for: t)
        return row
    }

    func renderTabs() {
        tabsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        func add(_ v: NSView) {
            tabsStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: tabsStack.widthAnchor).isActive = true
        }
        // grouped tabs first, under collapsible headers
        for g in groups {
            let members = tabs.filter { $0.groupId == g.id }
            if members.isEmpty { continue }
            let header = GroupHeaderView(name: g.name, count: members.count, collapsed: g.collapsed)
            header.onToggle = { [weak self] in
                guard let self, let gi = self.groups.firstIndex(where: { $0.id == g.id }) else { return }
                self.groups[gi].collapsed.toggle(); self.renderTabs()
            }
            add(header)
            if !g.collapsed { for t in members { add(makeTabRow(t)) } }
        }
        // ungrouped tabs
        for t in tabs where t.groupId == nil { add(makeTabRow(t)) }
    }

    // MARK: - Tab groups ----------------------------------------------------

    func groupEntries(for t: Tab) -> [MenuEntry] {
        var e: [MenuEntry] = [.item("New Group from Tab", { [weak self] in self?.newGroup(with: t) })]
        for g in groups where g.id != t.groupId {
            e.append(.item("Add to “\(g.name)”", { [weak self] in self?.addToGroup(t, g.id) }))
        }
        if t.groupId != nil { e.append(.item("Remove from Group", { [weak self] in self?.removeFromGroup(t) })) }
        return e
    }
    func newGroup(with t: Tab) {
        let g = TabGroup(id: nextGroupId, name: "Group \(nextGroupId)"); nextGroupId += 1
        groups.append(g); t.groupId = g.id; renderTabs()
    }
    func addToGroup(_ t: Tab, _ id: Int) { t.groupId = id; renderTabs() }
    func removeFromGroup(_ t: Tab) {
        let gid = t.groupId; t.groupId = nil
        if let gid, !tabs.contains(where: { $0.groupId == gid }) { groups.removeAll { $0.id == gid } }
        renderTabs()
    }

    // MARK: - Tab ops -------------------------------------------------------

    func openNewTab() {
        let t = Tab()
        wire(t)
        tabs.append(t); active = tabs.count - 1
        showActive(); renderTabs()
        window.makeFirstResponder(newTab.field)
    }

    func openTab(url: String) {
        let t = Tab(); t.isNewTab = false
        wire(t)
        tabs.append(t); active = tabs.count - 1
        if let u = URL(string: url) { t.webView.load(URLRequest(url: u)) }
        showActive(); renderTabs()
    }

    func wire(_ t: Tab) {
        t.webView.navigationDelegate = self
        t.webView.uiDelegate = self
        titleObs[t.id] = t.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            t.title = (wv.title?.isEmpty == false) ? wv.title! : "New Tab"
            self?.renderTabs()
        }
        urlObs[t.id] = t.webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.syncChrome(); self?.renderTabs()
        }
    }

    func closeTab(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        titleObs[t.id] = nil; urlObs[t.id] = nil
        t.webView.removeFromSuperview(); tabs.remove(at: i)
        if tabs.isEmpty { openNewTab(); return }
        active = min(active, tabs.count - 1); showActive(); renderTabs()
    }

    func select(_ i: Int) { active = i; showActive(); renderTabs() }

    // MARK: - Pins & context actions ---------------------------------------

    func pinTab(_ t: Tab) {
        guard let url = t.webView.url?.absoluteString else { return }
        if !pins.contains(where: { $0.url == url }) {
            pins.append(Pin(url: url, title: t.title)); persistPins(); renderPins()
        }
        closeTab(t)
    }

    func unpin(_ url: String) {
        pins.removeAll { $0.url == url }; persistPins(); renderPins()
    }

    func persistPins() { Store.shared.pins = pins; Store.shared.savePins() }

    func closeOthers(keep t: Tab) {
        for other in tabs where other.id != t.id {
            titleObs[other.id] = nil; urlObs[other.id] = nil
            other.webView.removeFromSuperview()
        }
        tabs = [t]; active = 0; showActive(); renderTabs()
    }

    func copyLink(_ t: Tab) {
        guard let url = t.webView.url?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    func toggleBookmark() {
        guard let t = current, !t.isNewTab, let url = t.webView.url?.absoluteString else { return }
        Store.shared.toggleBookmark(url: url, title: t.title)
        syncChrome()
    }

    func navigate(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let t = current else { return }
        var s = q
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { if !q.contains("://") { s = "https://" + q } }
        else { s = searchURL(for: q) }
        guard let u = URL(string: s) else { return }
        t.isNewTab = false
        showActive()
        t.webView.load(URLRequest(url: u))
        window.makeFirstResponder(nil)
    }

    @objc func addressSubmit() { navigate(address.stringValue) }

    func syncChrome() {
        applyChromeTheme()
        guard let wv = current?.webView else { return }
        back.isEnabled = wv.canGoBack; forward.isEnabled = wv.canGoForward
        if window.firstResponder !== address.currentEditor() {
            address.stringValue = (current?.isNewTab ?? false) ? "" : (wv.url?.absoluteString ?? "")
        }
        let bookmarked = (current?.isNewTab ?? true) ? false : Store.shared.isBookmarked(wv.url?.absoluteString ?? "")
        bookmarkBtn.symbol = bookmarked ? "bookmark.fill" : "bookmark"
    }

    func toggleSidebar() {
        sidebarHidden.toggle()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24; ctx.allowsImplicitAnimation = true
            sidebarLeft.constant = sidebarHidden ? -SIDEBAR_W : 0
            sidebar.alphaValue = sidebarHidden ? 0 : 1
            root.layoutSubtreeIfNeeded()
        }
    }

    @objc func openAssistant() { /* Phase C */ NSSound.beep() }

    func clearCache() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                self?.current?.webView.reload()
            }
        }
    }

    // MARK: - Now playing ---------------------------------------------------

    func handleMedia(_ message: WKScriptMessage) {
        guard let wv = message.webView,
              let t = tabs.first(where: { $0.webView === wv }),
              let body = message.body as? [String: Any] else { return }
        let playing = body["playing"] as? Bool ?? false
        t.isPlaying = playing
        if let title = body["title"] as? String, !title.isEmpty { t.mediaTitle = title }
        if playing { nowPlayingTab = t }
        updateNowPlaying()
    }

    func updateNowPlaying() {
        // prefer the tab we last saw play; fall back to any playing tab
        let t = (nowPlayingTab?.isPlaying == true) ? nowPlayingTab : tabs.first(where: { $0.isPlaying })
        guard let t else { nowPlaying.isHidden = true; nowPlayingTab = nil; return }
        nowPlayingTab = t
        nowPlaying.isHidden = false
        nowPlaying.configure(host: hostOf(t.webView.url),
                             title: t.mediaTitle.isEmpty ? t.title : t.mediaTitle,
                             playing: t.isPlaying)
    }

    func toggleNowPlaying() {
        guard let t = nowPlayingTab else { return }
        t.webView.evaluateJavaScript("(function(){var m=document.querySelector('video,audio');if(!m)return;m.paused?m.play():m.pause();})()")
    }
    func nowPlayingPip() {
        nowPlayingTab?.webView.evaluateJavaScript("(function(){var v=document.querySelector('video');if(v&&v.requestPictureInPicture)v.requestPictureInPicture();})()")
    }
    func backToNowPlaying() {
        if let t = nowPlayingTab, let i = tabs.firstIndex(where: { $0.id == t.id }) { select(i) }
    }

    // MARK: - Downloads -----------------------------------------------------

    func broadcastDownloads() {
        let js = "if(window.__bzOnDownloads)window.__bzOnDownloads(\(Store.json(downloadList)));"
        for t in tabs where isInternal(t.webView) { t.webView.evaluateJavaScript(js) }
    }

    func item(for d: WKDownload) -> DownloadItem? { downloads.first { $0.wk === d } }

    func cancelDownload(_ id: String) {
        guard let it = downloads.first(where: { $0.id == id }) else { return }
        it.wk?.cancel(); it.state = .cancelled; broadcastDownloads()
    }
    func openDownload(_ id: String) {
        if let u = downloads.first(where: { $0.id == id })?.localURL { NSWorkspace.shared.open(u) }
    }
    func showDownload(_ id: String) {
        if let u = downloads.first(where: { $0.id == id })?.localURL {
            NSWorkspace.shared.activateFileViewerSelecting([u])
        }
    }

    // route undisplayable responses to a download
    func webView(_ w: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = dir.appendingPathComponent(suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let ext = (suggestedFilename as NSString).pathExtension
            let base = (suggestedFilename as NSString).deletingPathExtension
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        let it = DownloadItem(filename: dest.lastPathComponent, url: download.originalRequest?.url?.absoluteString ?? "")
        it.wk = download; it.localURL = dest
        it.total = response.expectedContentLength
        it.obs = download.progress.observe(\.completedUnitCount) { [weak self, weak it] p, _ in
            guard let it else { return }
            it.received = p.completedUnitCount; it.total = p.totalUnitCount
            DispatchQueue.main.async { self?.broadcastDownloads() }
        }
        downloads.insert(it, at: 0)
        broadcastDownloads()
        completionHandler(dest)
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let it = item(for: download) { it.state = .completed; it.received = it.total }
        broadcastDownloads()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let it = item(for: download) { it.state = .failed }
        broadcastDownloads()
    }

    // MARK: - Internal pages ------------------------------------------------

    func openInternal(_ page: InternalPage) {
        guard let url = page.fileURL() else { NSSound.beep(); return }
        // reuse an already-open internal tab for this page, else open a new one
        if let i = tabs.firstIndex(where: { $0.webView.url?.lastPathComponent == page.file }) {
            select(i); return
        }
        let t = Tab(); t.isNewTab = false; t.title = page.title
        wire(t)
        tabs.append(t); active = tabs.count - 1
        showActive(); renderTabs()
        t.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func isInternal(_ wv: WKWebView) -> Bool { wv.url?.isFileURL ?? false }

    /// 'system' resolves to the actual effective light/dark for the HTML pages.
    func effectiveTheme() -> String {
        let m = Store.shared.string("theme")
        if m == "light" || m == "dark" { return m }
        return Theme.shared.palette.isDark ? "dark" : "light"
    }

    func applyThemeFromSettings() {
        switch Store.shared.string("theme") {
        case "light": Theme.shared.set(.light)
        case "dark":  Theme.shared.set(.dark)
        default:      Theme.shared.set(.system)
        }
    }

    /// Bake theme + settings into a freshly-loaded internal page.
    func injectBridgeState(into wv: WKWebView) {
        let theme = effectiveTheme()
        let js = """
        window.__bzTheme = '\(theme)';
        window.__bzSettings = \(Store.shared.settingsJSON());
        if (window.__bzOnTheme) window.__bzOnTheme('\(theme)');
        if (window.__bzOnSettings) window.__bzOnSettings(window.__bzSettings);
        """
        wv.evaluateJavaScript(js)
    }

    /// Push theme/settings changes to every open internal page.
    func broadcastToInternalPages() {
        let theme = effectiveTheme()
        let js = """
        window.__bzTheme = '\(theme)';
        window.__bzSettings = \(Store.shared.settingsJSON());
        if (window.__bzOnTheme) window.__bzOnTheme('\(theme)');
        if (window.__bzOnSettings) window.__bzOnSettings(window.__bzSettings);
        """
        for t in tabs where isInternal(t.webView) { t.webView.evaluateJavaScript(js) }
    }

    // MARK: - Bridge message handler ---------------------------------------

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "breezeMedia" {
            handleMedia(message); return
        }
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else { return }
        let args = body["args"] as? [String: Any] ?? [:]
        let id = body["id"] as? Int
        let wv = message.webView

        func resolve(_ jsonValue: String) {
            guard let id, let wv else { return }
            wv.evaluateJavaScript("window.__bzResolve(\(id), \(jsonValue.debugDescription))")
        }

        switch method {
        case "setSetting":
            if let key = args["key"] as? String { Store.shared.settings[key] = args["value"]; Store.shared.saveSettings() }
            applySettingsChange()
        case "getHistory":
            resolve(Store.json(Store.shared.history))
        case "clearHistory":
            Store.shared.history = []; Store.shared.saveHistory()
        case "deleteHistoryItem":
            if let url = args["url"] as? String {
                let ts = args["ts"] as? Double
                Store.shared.history.removeAll { ($0["url"] as? String == url) && (ts == nil || ($0["ts"] as? Double == ts)) }
                Store.shared.saveHistory()
            }
        case "getBookmarks":
            resolve(Store.json(Store.shared.bookmarks))
        case "removeBookmark":
            if let url = args["url"] as? String { Store.shared.bookmarks.removeAll { $0["url"] as? String == url }; Store.shared.saveBookmarks(); syncChrome() }
        case "getDownloads":
            resolve(Store.json(downloadList))
        case "cancelDownload":
            if let id = args["id"] as? String { cancelDownload(id) }
        case "openDownload":
            if let id = args["id"] as? String { openDownload(id) }
        case "showDownload":
            if let id = args["id"] as? String { showDownload(id) }
        case "clearDownloads":
            downloads.removeAll { $0.state != .progressing }; broadcastDownloads()
        case "getReminders", "vaultList":
            resolve("[]")
        case "switchToTab":
            if let id = args["id"] as? String, let i = tabs.firstIndex(where: { $0.id.uuidString == id }) { select(i) }
        case "clearBrowsingData":
            clearCache(); resolve("{}")
        case "resetBrowser":
            Store.shared.settings = Store.defaults; Store.shared.pins = []
            Store.shared.history = []; Store.shared.bookmarks = []
            Store.shared.saveSettings(); Store.shared.savePins(); Store.shared.saveHistory(); Store.shared.saveBookmarks()
            pins = []; renderPins(); applySettingsChange(); resolve("{}")
        default:
            break
        }
    }

    func applySettingsChange() {
        applyThemeFromSettings()                  // posts Theme.didChange → chrome restyles
        pinSize = PinSize(rawValue: Store.shared.string("pinSize")) ?? .large
        renderPins()
        applyChromeTheme()
        broadcastToInternalPages()
        newTab.applyTheme(); newTab.tick()
    }

    func searchURL(for query: String) -> String {
        let e = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch Store.shared.string("searchEngine") {
        case "duckduckgo": return "https://duckduckgo.com/?q=\(e)"
        case "bing":       return "https://www.bing.com/search?q=\(e)"
        default:           return "https://www.google.com/search?q=\(e)"
        }
    }

    // MARK: - Theme ---------------------------------------------------------

    func applyChromeTheme() {
        let p = Theme.shared.palette
        addressWrap.layer?.backgroundColor = p.surface.cgColor
        address.textColor = p.text
        adblockPill.layer?.backgroundColor = p.surface.cgColor
        adblockCount.textColor = p.textSoft
        root.needsDisplay = true
    }

    // MARK: - WK delegates --------------------------------------------------

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        syncChrome()
        if isInternal(w) { injectBridgeState(into: w) }
        else if let u = w.url?.absoluteString {
            Store.shared.addHistory(url: u, title: (w.title?.isEmpty == false ? w.title! : u))
        }
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        syncChrome()
        if isInternal(w) { injectBridgeState(into: w) }
    }
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = a.request.url { openTab(url: u.absoluteString) }
        return nil
    }
}
