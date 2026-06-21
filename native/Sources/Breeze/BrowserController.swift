// The browser window: sidebar (pins + tabs + footer), top URL bar, web views,
// and the native new-tab page. Look ported from ui/index.html + style.css
// (urlbar-top mode, matching the screenshots).

import Cocoa
import WebKit
import UserNotifications

let SIDEBAR_W: CGFloat = 280

final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSWindowDelegate, WKScriptMessageHandler, WKDownloadDelegate, BrowserAITools {
    let window: NSWindow
    var tabs: [Tab] = []
    var active = 0
    var pins: [Pin] = []
    var pinSize: PinSize = .large      // Settings: small / medium / large
    var downloads: [DownloadItem] = []
    var downloadList: [[String: Any]] { downloads.map { $0.dict } }
    var groups: [TabGroup] = []        // session-only tab groups
    var nextGroupId = 1
    var blockedPopups: Set<UUID> = []  // tabs with "Allow Popups" turned off
    var titleObs: [UUID: NSKeyValueObservation] = [:]
    var urlObs: [UUID: NSKeyValueObservation] = [:]

    // chrome
    let root = GradientBackgroundView()
    let sidebar = HoverReportView()
    let edgeHandle = HoverReportView()   // left-edge strip to peek the sidebar
    var sidebarHidden = false
    var peeking = false
    var sidebarLeft: NSLayoutConstraint!
    var sidebarWidthC: NSLayoutConstraint!
    var sidebarWidth: CGFloat = SIDEBAR_W
    let sidebarResizer = ColumnResizeView()
    let pinsStack = NSStackView()
    let tabsStack = NSStackView()
    let webContainer = NSView()
    let newTab = NewTabView()

    // sidebar URL mode (urlBarPosition == "sidebar")
    let sidebarUrlSection = NSView()
    let sbBack = HoverButton(symbol: "chevron.left", point: 14)
    let sbForward = HoverButton(symbol: "chevron.right", point: 14)
    let sbReload = HoverButton(symbol: "arrow.clockwise", point: 13)
    let sbAddress = NSTextField()
    var sbAddrWrap: NSView?
    var pinsTopToStrip: NSLayoutConstraint!
    var pinsTopToUrl: NSLayoutConstraint!
    var webTopToTopbar: NSLayoutConstraint!
    var webTopToRoot: NSLayoutConstraint!
    let nowPlaying = NowPlayingView()
    var nowPlayingTab: Tab?
    var splitTabId: UUID?                 // secondary tab shown beside the active one
    var splitRatio: CGFloat = 0.5
    var splitLeftWidthC: NSLayoutConstraint?
    let splitDivider = ColumnResizeView()
    let leftPane = SplitPane()
    let rightPane = SplitPane()

    // assistant
    let assistant = AssistantPanel()
    var assistantOpen = false
    var assistantLeadingC: NSLayoutConstraint!
    var assistantWidthC: NSLayoutConstraint!
    var webTrailC: NSLayoutConstraint!
    var topTrailC: NSLayoutConstraint!
    lazy var llm = LocalLLM(tools: self)     // local Qwen via llama-server (fallback)
    private var fmAny: Any?                   // FoundationAI (Apple Intelligence, preferred)
    var useFM = false
    var aiExtras: [AIExtra] = []             // @-added tabs + attached images (current tab always included)
    var aiNavWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    let ASSISTANT_W: CGFloat = 360

    // top bar
    let topBar = NSView()
    let topSidebarBtn = HoverButton(symbol: "sidebar.left")   // shown in top bar when sidebar collapsed
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

        if let w = Store.shared.settings["sidebarWidth"] as? Double, w >= 200, w <= 460 { sidebarWidth = w }
        sidebarLeft = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 0)
        sidebarWidthC = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        topTrailC = topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -48)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidthC,
            sidebarLeft,

            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
            topTrailC,
            topBar.heightAnchor.constraint(equalToConstant: 40),
            // always clear the macOS traffic lights, even when the sidebar hides
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 82),
        ])
        let topLeadToSidebar = topBar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 6)
        topLeadToSidebar.priority = .defaultHigh   // yields to the >=82 clearance when sidebar hides
        topLeadToSidebar.isActive = true
        NSLayoutConstraint.activate([

            webContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 0),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        webTrailC = webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6)
        webTrailC.isActive = true
        webTopToTopbar = webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 5)
        webTopToRoot = webContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 6)
        webTopToTopbar.isActive = true   // top mode by default

        // breeze corner mark — pinned top-right of the window
        root.addSubview(breezeCorner)
        breezeCorner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            breezeCorner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            breezeCorner.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            breezeCorner.widthAnchor.constraint(equalToConstant: 30),
            breezeCorner.heightAnchor.constraint(equalToConstant: 30),
        ])

        // left-edge peek strip (on top, only live when the sidebar is hidden)
        root.addSubview(edgeHandle)
        edgeHandle.translatesAutoresizingMaskIntoConstraints = false
        edgeHandle.isHidden = true
        NSLayoutConstraint.activate([
            edgeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            edgeHandle.topAnchor.constraint(equalTo: root.topAnchor),
            edgeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edgeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        // sidebar resize handle (straddles the sidebar's right edge)
        root.addSubview(sidebarResizer)
        sidebarResizer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarResizer.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarResizer.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarResizer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarResizer.widthAnchor.constraint(equalToConstant: 8),
        ])
        let pan = NSPanGestureRecognizer(target: self, action: #selector(resizeSidebar(_:)))
        sidebarResizer.addGestureRecognizer(pan)

        // split-view divider (drag to change the ratio)
        splitDivider.wantsLayer = true
        splitDivider.addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragSplit(_:))))

        edgeHandle.onEnter = { [weak self] in
            guard let self, self.sidebarHidden else { return }
            self.setSidebarHidden(false, peek: true); self.peeking = true
        }
        sidebar.onExit = { [weak self] in
            guard let self, self.peeking else { return }
            self.setSidebarHidden(true); self.peeking = false
        }

        // assistant panel (right side; slides in)
        root.addSubview(assistant)
        assistantLeadingC = assistant.leadingAnchor.constraint(equalTo: root.trailingAnchor, constant: 0)
        assistantWidthC = assistant.widthAnchor.constraint(equalToConstant: ASSISTANT_W)
        NSLayoutConstraint.activate([
            assistant.topAnchor.constraint(equalTo: root.topAnchor),
            assistant.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            assistantWidthC,
            assistantLeadingC,
        ])
        assistant.onSend = { [weak self] t in self?.sendToAI(t) }
        assistant.onClose = { [weak self] in self?.setAssistant(false) }
        assistant.onNewChat = { [weak self] in self?.newChat() }
        assistant.onAtMention = { [weak self] in self?.aiAtMention() }
        assistant.onRemoveContext = { [weak self] i in self?.removeAIContext(i) }
        assistant.onToggleFullscreen = { [weak self] in self?.toggleAssistantFullscreen() }
        assistant.onAttach = { [weak self] in self?.aiAttachImage() }
        // Prefer Apple Foundation Models when available (on-device, no download);
        // fall back to local Qwen otherwise. Both are agentic via the SEARCH: loop.
        if #available(macOS 26.0, *), FoundationAI.available() {
            useFM = true
            fmAny = FoundationAI(tools: self)
        }
        llm.onStatus = { [weak self] s in
            guard let self else { return }
            self.assistant.setModelStatus(s)                 // empty-state line
            self.assistant.setStatus(self.llm.ready ? nil : s)   // also show progress during a chat
        }

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
        startSleepTimer()
        applyUrlBarMode()
    }

    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    // MARK: - Sidebar -------------------------------------------------------

    func buildSidebar() {
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // drag strip: traffic-light pad + sidebar toggle + new tab + downloads
        let tlPad = NSView(); tlPad.translatesAutoresizingMaskIntoConstraints = false
        tlPad.widthAnchor.constraint(equalToConstant: 58).isActive = true
        let toggle = HoverButton(symbol: "sidebar.left"); toggle.onTap = { [weak self] in self?.sidebarToggleClicked() }
        let plus = HoverButton(symbol: "plus"); plus.onTap = { [weak self] in self?.openNewTab() }
        let dl = HoverButton(symbol: "arrow.down.to.line"); dl.onTap = { [weak self] in self?.openInternal(.downloads) }
        let dragFill = NSView(); dragFill.translatesAutoresizingMaskIntoConstraints = false
        dragFill.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // toggle sits at the right end, after the download button
        let strip = NSStackView(views: [tlPad, dragFill, plus, dl, toggle])
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

        buildSidebarUrlSection()

        sidebar.addSubview(strip)
        sidebar.addSubview(sidebarUrlSection)
        sidebar.addSubview(pinsStack)
        sidebar.addSubview(tabsScroll)
        sidebar.addSubview(bottomStack)
        pinsTopToStrip = pinsStack.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 12)
        pinsTopToUrl = pinsStack.topAnchor.constraint(equalTo: sidebarUrlSection.bottomAnchor, constant: 12)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 5),
            strip.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            strip.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            sidebarUrlSection.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 10),
            sidebarUrlSection.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            sidebarUrlSection.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            pinsTopToStrip,
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

    func buildSidebarUrlSection() {
        sidebarUrlSection.translatesAutoresizingMaskIntoConstraints = false
        sidebarUrlSection.isHidden = true
        sbBack.onTap = { [weak self] in self?.current?.webView.goBack() }
        sbForward.onTap = { [weak self] in self?.current?.webView.goForward() }
        sbReload.onTap = { [weak self] in self?.current?.webView.reload() }
        let navRow = NSStackView(views: [sbBack, sbForward, sbReload]); navRow.spacing = 2
        navRow.translatesAutoresizingMaskIntoConstraints = false
        let addrWrap = NSView(); addrWrap.wantsLayer = true; addrWrap.layer?.cornerRadius = 10
        addrWrap.translatesAutoresizingMaskIntoConstraints = false
        sbAddress.placeholderString = "Search or enter URL"
        sbAddress.font = .systemFont(ofSize: 13.5)
        sbAddress.isBordered = false; sbAddress.drawsBackground = false; sbAddress.focusRingType = .none
        sbAddress.usesSingleLineMode = true; sbAddress.lineBreakMode = .byTruncatingTail
        sbAddress.cell?.truncatesLastVisibleLine = true
        sbAddress.translatesAutoresizingMaskIntoConstraints = false
        sbAddress.target = self; sbAddress.action = #selector(sidebarAddressSubmit)
        addrWrap.addSubview(sbAddress)
        NSLayoutConstraint.activate([
            sbAddress.leadingAnchor.constraint(equalTo: addrWrap.leadingAnchor, constant: 11),
            sbAddress.trailingAnchor.constraint(equalTo: addrWrap.trailingAnchor, constant: -11),
            sbAddress.centerYAnchor.constraint(equalTo: addrWrap.centerYAnchor),
        ])
        sidebarUrlSection.addSubview(navRow); sidebarUrlSection.addSubview(addrWrap)
        NSLayoutConstraint.activate([
            navRow.topAnchor.constraint(equalTo: sidebarUrlSection.topAnchor),
            navRow.leadingAnchor.constraint(equalTo: sidebarUrlSection.leadingAnchor),
            addrWrap.topAnchor.constraint(equalTo: navRow.bottomAnchor, constant: 6),
            addrWrap.leadingAnchor.constraint(equalTo: sidebarUrlSection.leadingAnchor),
            addrWrap.trailingAnchor.constraint(equalTo: sidebarUrlSection.trailingAnchor),
            addrWrap.heightAnchor.constraint(equalToConstant: 38),
            addrWrap.bottomAnchor.constraint(equalTo: sidebarUrlSection.bottomAnchor),
        ])
        self.sbAddrWrap = addrWrap
    }
    @objc func sidebarAddressSubmit() { navigate(sbAddress.stringValue) }

    /// Settings → Address bar: "top" shows the top bar; "sidebar" moves the URL
    /// bar + nav into the sidebar and the page fills up to the top.
    func applyUrlBarMode() {
        let sidebarMode = Store.shared.string("urlBarPosition") == "sidebar"
        sidebarUrlSection.isHidden = !sidebarMode
        topBar.isHidden = sidebarMode
        pinsTopToStrip.isActive = false; pinsTopToUrl.isActive = false
        webTopToTopbar.isActive = false; webTopToRoot.isActive = false
        if sidebarMode { pinsTopToUrl.isActive = true; webTopToRoot.isActive = true }
        else { pinsTopToStrip.isActive = true; webTopToTopbar.isActive = true }
        if sidebarMode { topSidebarBtn.isHidden = true }   // no top bar to host it
        syncChrome()
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
        let contentW = sidebarWidth - 14 - 10
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
            v.onSelect = { [weak self] in self?.openPin(p.url) }
            v.onUnpin = { [weak self] in self?.unpin(p.url) }
            v.menuProvider = { [weak self] in self?.pinMenu(p.url) ?? [] }
            let openTab = pinnedTab(p.url)
            v.setState(open: openTab != nil, active: openTab != nil && openTab?.id == current?.id)
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
        address.usesSingleLineMode = true; address.lineBreakMode = .byTruncatingTail
        address.cell?.truncatesLastVisibleLine = true
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

        topSidebarBtn.onTap = { [weak self] in self?.setSidebarHidden(false) }
        topSidebarBtn.isHidden = true
        let nav = NSStackView(views: [topSidebarBtn, back, forward, reload]); nav.spacing = 2
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
        newTab.onSubmit = { [weak self] t in self?.newTabSubmit(t) }
    }

    func showActive() {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        splitLeftWidthC = nil
        guard let t = current else { return }
        let primary: NSView = t.isNewTab ? newTab : t.webView
        if t.isNewTab { newTab.startClock() } else { newTab.stopClock() }

        if let sid = splitTabId, sid != t.id, let s = tabs.first(where: { $0.id == sid }) {
            topBar.isHidden = true                       // per-pane URL bars replace the global one
            leftPane.host(primary)
            rightPane.host(s.webView)
            wireSplitPane(leftPane, tab: t)
            wireSplitPane(rightPane, tab: s)
            leftPane.setURL(t.isNewTab ? "" : (t.webView.url?.absoluteString ?? ""))
            rightPane.setURL(s.webView.url?.absoluteString ?? "")
            splitDivider.layer?.backgroundColor = Theme.shared.palette.surfaceHover.cgColor
            [leftPane, splitDivider, rightPane].forEach {
                webContainer.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false
            }
            let w = max(webContainer.bounds.width, 1)
            let lw = leftPane.widthAnchor.constraint(equalToConstant: w * splitRatio - 7)
            splitLeftWidthC = lw
            NSLayoutConstraint.activate([
                leftPane.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                leftPane.topAnchor.constraint(equalTo: webContainer.topAnchor),
                leftPane.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
                lw,
                splitDivider.leadingAnchor.constraint(equalTo: leftPane.trailingAnchor),
                splitDivider.widthAnchor.constraint(equalToConstant: 8),
                splitDivider.topAnchor.constraint(equalTo: webContainer.topAnchor),
                splitDivider.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
                rightPane.leadingAnchor.constraint(equalTo: splitDivider.trailingAnchor),
                rightPane.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
                rightPane.topAnchor.constraint(equalTo: webContainer.topAnchor),
                rightPane.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            ])
        } else {
            topBar.isHidden = false
            webContainer.addSubview(primary); primary.pin(to: webContainer)
        }
        syncChrome()
    }

    func wireSplitPane(_ pane: SplitPane, tab: Tab) {
        pane.onNavigate = { [weak self, weak tab] text in if let tab { self?.navigateTab(tab, text) } }
        pane.back.onTap = { [weak tab] in tab?.webView.goBack() }
        pane.forward.onTap = { [weak tab] in tab?.webView.goForward() }
        pane.reload.onTap = { [weak tab] in tab?.webView.reload() }
    }

    func navigateTab(_ t: Tab, _ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        var s = q
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { if !q.contains("://") { s = "https://" + q } } else { s = searchURL(for: q) }
        if let u = URL(string: s) { t.isNewTab = false; t.webView.load(URLRequest(url: u)) }
    }

    // MARK: - Split view ----------------------------------------------------

    func enterSplit(_ t: Tab) {
        guard t.id != current?.id else { return }
        splitTabId = t.id; showActive()
    }
    func exitSplit() { splitTabId = nil; showActive() }

    @objc func dragSplit(_ g: NSPanGestureRecognizer) {
        let w = max(webContainer.bounds.width, 1)
        splitRatio = max(0.2, min(0.8, splitRatio + g.translation(in: webContainer).x / w))
        g.setTranslation(.zero, in: webContainer)
        splitLeftWidthC?.constant = w * splitRatio - 3
    }

    func windowDidResize(_ n: Notification) {
        splitLeftWidthC?.constant = max(webContainer.bounds.width, 1) * splitRatio - 3
        if assistantFullscreen {
            let w = assistantFSWidth()
            assistantWidthC.constant = w
            assistantLeadingC.constant = -w
            webTrailC.constant = -(w + 6)
            topTrailC.constant = -(w + 8)
        }
    }

    func makeTabRow(_ t: Tab) -> TabRowView {
        let i = tabs.firstIndex { $0.id == t.id } ?? 0
        let row = TabRowView(title: t.title, host: hostOf(t.webView.url), active: i == active,
                             perf: t.perfMode, asleep: t.sleeping)
        row.onSelect = { [weak self] in self?.select(i) }
        row.onClose = { [weak self] in self?.closeTab(t) }
        row.menuProvider = { [weak self] in self?.tabMenu(for: t) ?? [] }
        return row
    }

    /// Tab right-click menu — mirrors the Electron showTabContextMenu.
    func tabMenu(for t: Tab) -> [MenuEntry] {
        let url = t.webView.url?.absoluteString
        let isWeb = !t.isNewTab && url != nil && !(url!.hasPrefix("file://"))
        let isPinned = url != nil && pins.contains { $0.url == url }
        var e: [MenuEntry] = []
        // Pin / Unpin
        if isWeb {
            e.append(.item(isPinned ? "Unpin" : "Pin Tab", { [weak self] in
                isPinned ? self?.unpin(url!) : self?.pinTab(t)
            }))
        } else { e.append(.disabled(isPinned ? "Unpin" : "Pin Tab")) }
        // Move to Group (only when ungrouped, like Electron) / Remove from Group
        if isWeb && t.groupId == nil {
            var sub: [MenuEntry] = groups.map { g in .item(g.name, { [weak self] in self?.addToGroup(t, g.id) }) }
            if !groups.isEmpty { sub.append(.separator) }
            sub.append(.item("New Group…", { [weak self] in self?.newGroup(with: t) }))
            e.append(.submenu("Move to Group", sub))
        } else if t.groupId != nil {
            e.append(.item("Remove from Group", { [weak self] in self?.removeFromGroup(t) }))
        } else {
            e.append(.disabled("Move to Group"))
        }
        // Duplicate
        if isWeb { e.append(.item("Duplicate Tab", { [weak self] in self?.openTab(url: url!) })) }
        else { e.append(.disabled("Duplicate Tab")) }
        // Sleep Tab (Electron: web && not sleeping && not active)
        if isWeb && !t.sleeping && t.id != current?.id {
            e.append(.item("Sleep Tab", { [weak self] in self?.sleepTab(t) }))
        }
        e.append(.separator)
        // Split view
        if splitTabId != nil {
            e.append(.item("Exit Split View", { [weak self] in self?.exitSplit() }))
        } else if t.id != current?.id && tabs.count > 1 {
            e.append(.item("Open in Split View", { [weak self] in self?.enterSplit(t) }))
        } else {
            e.append(.disabled("Open in Split View"))
        }
        e.append(.separator)
        // Performance Mode (boost) + Allow Popups — checkboxes, like Electron
        if isWeb {
            e.append(.check("🚀 Performance Mode", t.perfMode, { [weak self] in self?.setPerfMode(t, !t.perfMode) }))
            e.append(.check("Allow Popups", !blockedPopups.contains(t.id), { [weak self] in self?.togglePopups(t) }))
        }
        e.append(.separator)
        e.append(.item("Close Tab", { [weak self] in self?.closeTab(t) }))
        return e
    }

    func setPerfMode(_ t: Tab, _ on: Bool) {
        t.perfMode = on
        t.webView.layer?.cornerRadius = on ? 0 : 10
        refreshSidebar()
    }
    func togglePopups(_ t: Tab) {
        if blockedPopups.contains(t.id) { blockedPopups.remove(t.id) } else { blockedPopups.insert(t.id) }
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
        // ungrouped, non-pinned tabs (pinned tabs are housed in their pin icon)
        for t in tabs where t.groupId == nil && t.pinUrl == nil { add(makeTabRow(t)) }
    }

    // MARK: - Tab groups ----------------------------------------------------

    func pinMenu(_ url: String) -> [MenuEntry] {
        let open = pinnedTab(url) != nil
        return [
            .item("Open", { [weak self] in self?.openPin(url) }),
            open ? .item("Close", { [weak self] in self?.closePin(url) }) : .disabled("Close"),
            .separator,
            .item("Unpin", { [weak self] in self?.unpin(url) }),
        ]
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
        showActive(); refreshSidebar()
        window.makeFirstResponder(newTab.field)
    }

    func openTab(url: String) {
        let t = Tab(); t.isNewTab = false
        wire(t)
        tabs.append(t); active = tabs.count - 1
        if let u = URL(string: url) { t.webView.load(URLRequest(url: u)) }
        showActive(); refreshSidebar()
    }

    func wire(_ t: Tab) {
        t.webView.navigationDelegate = self
        t.webView.uiDelegate = self
        titleObs[t.id] = t.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            t.title = (wv.title?.isEmpty == false) ? wv.title! : "New Tab"
            self?.refreshSidebar()
        }
        urlObs[t.id] = t.webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.syncChrome(); self?.refreshSidebar()
        }
    }

    func closeTab(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        titleObs[t.id] = nil; urlObs[t.id] = nil
        if nowPlayingTab?.id == t.id { nowPlayingTab = nil }
        if splitTabId == t.id { splitTabId = nil }
        t.webView.removeFromSuperview(); tabs.remove(at: i)
        if tabs.isEmpty { openNewTab(); return }
        active = min(active, tabs.count - 1); showActive(); refreshSidebar(); updateNowPlaying()
    }

    func select(_ i: Int) {
        // activating any tab leaves split view (the divider must not persist)
        if splitTabId != nil && tabs.indices.contains(i) && tabs[i].id != splitTabId { splitTabId = nil }
        active = i
        if let t = current { t.lastActive = Date(); if t.sleeping { wake(t) } }
        showActive(); refreshSidebar()
        if assistantOpen { updateAIContextPills() }
    }

    // MARK: - Tab sleeping --------------------------------------------------

    func sleepTab(_ t: Tab) {
        guard !t.sleeping, !t.isNewTab, t.id != current?.id else { return }
        t.sleptURL = t.webView.url?.absoluteString
        t.sleeping = true
        t.webView.loadHTMLString("", baseURL: nil)   // discard the page to free memory
        refreshSidebar()
    }
    func wake(_ t: Tab) {
        t.sleeping = false
        if let u = t.sleptURL, let url = URL(string: u) { t.webView.load(URLRequest(url: url)) }
        t.sleptURL = nil
    }
    func startSleepTimer() {
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.sweepIdleTabs() }
    }
    func sweepIdleTabs() {
        let hours = (Store.shared.settings["tabSleepHours"] as? NSNumber)?.doubleValue ?? 0
        guard hours > 0 else { return }                 // 0 = never
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        for t in tabs where t.id != current?.id && !t.sleeping && !t.isNewTab && t.lastActive < cutoff {
            sleepTab(t)
        }
    }

    // MARK: - Pins & context actions ---------------------------------------

    /// The open tab that represents a pin — ONLY a tab opened via the pin
    /// (pinUrl set). A coincidental same-site tab in the list must not light it.
    func pinnedTab(_ url: String) -> Tab? {
        tabs.first { $0.pinUrl == url }
    }

    /// Pin Tab — keeps the tab open and links it to the new pin (does NOT close).
    func pinTab(_ t: Tab) {
        guard let url = t.webView.url?.absoluteString else { return }
        if !pins.contains(where: { $0.url == url }) {
            pins.append(Pin(url: url, title: t.title)); persistPins()
        }
        t.pinUrl = url
        refreshSidebar()
    }

    /// Click a pin → focus its open tab, or open it in a new tab.
    func openPin(_ url: String) {
        if let t = pinnedTab(url), let i = tabs.firstIndex(where: { $0.id == t.id }) {
            t.pinUrl = url; select(i); return
        }
        openTab(url: url)
        current?.pinUrl = url
        refreshSidebar()
    }

    /// Pin "Close" — closes the tab but keeps the pin.
    func closePin(_ url: String) {
        if let t = pinnedTab(url) { closeTab(t) }
    }

    func unpin(_ url: String) {
        pins.removeAll { $0.url == url }; persistPins()
        for t in tabs where t.pinUrl == url { t.pinUrl = nil }
        refreshSidebar()
    }

    func persistPins() { Store.shared.pins = pins; Store.shared.savePins() }

    func refreshSidebar() { renderPins(); renderTabs() }

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
        if q.hasPrefix("breeze://"), let page = InternalPage(rawValue: String(q.dropFirst(9))) {
            openInternal(page); return
        }
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

    /// Friendly address for internal pages: file://…/ui/settings.html → breeze://settings
    func displayURL(_ wv: WKWebView) -> String {
        guard let u = wv.url else { return "" }
        if u.isFileURL { return "breeze://" + u.deletingPathExtension().lastPathComponent }
        return u.absoluteString
    }

    /// New-tab omnibox doubles as the chat bar: a URL navigates, anything else
    /// starts a fresh chat in the assistant.
    func newTabSubmit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { navigate(q); return }
        if !assistantOpen { setAssistant(true) }
        newChat()
        sendToAI(q)
    }

    func syncChrome() {
        applyChromeTheme()
        // re-assert URL-bar placement so the transparent top bar never lingers
        // over the page in sidebar mode
        let sidebarMode = Store.shared.string("urlBarPosition") == "sidebar"
        topBar.isHidden = sidebarMode
        sidebarUrlSection.isHidden = !sidebarMode
        guard let wv = current?.webView else { return }
        back.isEnabled = wv.canGoBack; forward.isEnabled = wv.canGoForward
        sbBack.isEnabled = wv.canGoBack; sbForward.isEnabled = wv.canGoForward
        let urlStr = (current?.isNewTab ?? false) ? "" : displayURL(wv)
        if window.firstResponder !== address.currentEditor() { address.stringValue = urlStr }
        if window.firstResponder !== sbAddress.currentEditor() { sbAddress.stringValue = urlStr }
        let bookmarked = (current?.isNewTab ?? true) ? false : Store.shared.isBookmarked(wv.url?.absoluteString ?? "")
        bookmarkBtn.symbol = bookmarked ? "bookmark.fill" : "bookmark"
        // keep split panes' address bars current
        if let sid = splitTabId, let s = tabs.first(where: { $0.id == sid }), let t = current {
            leftPane.setURL(t.isNewTab ? "" : (t.webView.url?.absoluteString ?? ""))
            rightPane.setURL(s.webView.url?.absoluteString ?? "")
        }
    }

    func toggleSidebar() { setSidebarHidden(!sidebarHidden) }

    /// The toggle button inside the sidebar: if the sidebar is only peeking
    /// (hover-revealed), clicking it DOCKS it open instead of hiding it again.
    func sidebarToggleClicked() {
        if peeking { peeking = false; edgeHandle.isHidden = true }   // dock open
        else { setSidebarHidden(true) }                             // collapse
    }

    func setSidebarHidden(_ hidden: Bool, peek: Bool = false) {
        sidebarHidden = hidden
        if !peek { peeking = false }
        edgeHandle.isHidden = !hidden          // edge strip is only live when hidden
        topSidebarBtn.isHidden = !hidden       // show the top-bar opener only when collapsed
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            sidebarLeft.constant = hidden ? -sidebarWidth : 0
            sidebar.alphaValue = hidden ? 0 : 1
            root.layoutSubtreeIfNeeded()
        }
    }

    @objc func resizeSidebar(_ g: NSPanGestureRecognizer) {
        let dx = g.translation(in: root).x
        g.setTranslation(.zero, in: root)
        sidebarWidth = max(200, min(460, sidebarWidth + dx))
        sidebarWidthC.constant = sidebarWidth
        renderPins()                                  // pin cell size depends on width
        if g.state == .ended {
            Store.shared.settings["sidebarWidth"] = Double(sidebarWidth); Store.shared.saveSettings()
        }
    }

    @objc func openAssistant() { toggleAssistant() }
    func toggleAssistant() {
        // On a blank new-tab screen you don't open an empty sidebar — you "Ask
        // Breeze" from the new-tab bar, which starts a page-disconnected chat.
        if !assistantOpen, current?.isNewTab == true {
            window.makeFirstResponder(newTab.field); return
        }
        setAssistant(!assistantOpen)
    }

    func ailog(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        let p = "/tmp/bz-ai.log"
        if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
        else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
    }

    /// Fullscreen chat fills the tab content area (right of the sidebar).
    func assistantFSWidth() -> CGFloat {
        max(400, root.bounds.width - (sidebarHidden ? 0 : sidebarWidth))
    }

    func setAssistant(_ open: Bool) {
        assistantOpen = open
        if !open { assistantFullscreen = false }      // reset so reopening is clean
        assistant.setFullscreen(assistantFullscreen, clearLights: assistantFullscreen && sidebarHidden)
        breezeCorner.isHidden = open
        let w: CGFloat = assistantFullscreen ? assistantFSWidth() : ASSISTANT_W
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            assistantWidthC.constant = w
            assistantLeadingC.constant = open ? -w : 0
            webTrailC.constant = open ? -(w + 6) : -6
            topTrailC.constant = open ? -(w + 8) : -48
            root.layoutSubtreeIfNeeded()
        }
        if open {
            assistant.setMode(history: false)   // always a normal chat; history is a button overlay
            updateAIContextPills()
            assistant.focusInput()
            prepareAIStatus()
        }
    }

    /// Set the chat input's enabled state + status based on the active backend.
    func prepareAIStatus() {
        if useFM {
            assistant.setInputEnabled(true)
            assistant.setModelStatus("Apple Intelligence — on-device. Ask anything, or summarize this page.")
        } else if llm.ready {
            assistant.setInputEnabled(true)
            assistant.setModelStatus("On-device model ready. Ask anything, or summarize this page.")
        } else {
            assistant.setInputEnabled(false, placeholder: "Preparing Qwen 7B…")
            assistant.setModelStatus("Preparing Qwen 7B — best on 16GB+ Apple Silicon…")
            llm.ensure { [weak self] ok in
                self?.assistant.setInputEnabled(ok, placeholder: ok ? nil : "Model unavailable")
                self?.assistant.setStatus(nil)
                if ok { self?.assistant.focusInput() }
            }
        }
    }

    func newChat() {
        assistant.startNewChat()
        aiExtras.removeAll { $0.imageText != nil }   // drop attachments; keep nothing stale
        updateAIContextPills()
        if useFM, #available(macOS 26.0, *) { fmAny = FoundationAI(tools: self) }
        else { llm.resetChat() }
    }

    var assistantFullscreen = false
    func toggleAssistantFullscreen() {
        assistantFullscreen.toggle()
        assistant.setFullscreen(assistantFullscreen, clearLights: assistantFullscreen && sidebarHidden)
        breezeCorner.isHidden = true
        let w: CGFloat = assistantFullscreen ? assistantFSWidth() : ASSISTANT_W
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            assistantWidthC.constant = w
            assistantLeadingC.constant = -w
            webTrailC.constant = -(w + 6)
            topTrailC.constant = -(w + 8)
            root.layoutSubtreeIfNeeded()
        }
    }

    func sendToAI(_ text: String) {
        ailog("sendToAI (\(useFM ? "FM" : "Qwen")): \(text)")
        assistant.addUser(text)
        let preparing = !useFM && !llm.ready
        assistant.setInputEnabled(false, placeholder: preparing ? "Preparing model…" : "Thinking…")
        assistant.setStatus(preparing ? "Preparing the model, then sending…" : "Thinking…")

        Task { [weak self] in
            guard let self else { return }
            let contexts = await self.gatherContexts()
            let labels = contexts.map { $0.label }
            let done: (Result<(String, [String]), Error>) -> Void = { [weak self] r in
                guard let self else { return }
                self.ailog("model returned")
                self.assistant.setStatus(nil); self.assistant.setInputEnabled(true); self.assistant.focusInput()
                switch r {
                case .success(let (answer, toolChips)):
                    let chips = labels + toolChips
                    let text = answer.isEmpty ? "…" : answer
                    self.assistant.addAI(text, chips: chips)
                case .failure(let e):
                    self.assistant.addAI("Sorry — \(e.localizedDescription)", chips: [])
                }
            }
            if self.useFM, #available(macOS 26.0, *), let fm = self.fmAny as? FoundationAI {
                fm.send(text, contexts: contexts, completion: done)
            } else {
                self.llm.send(text, contexts: contexts, completion: done)
            }
        }
    }

    func ctxLabel(_ t: Tab) -> String {
        let s = t.title.isEmpty ? hostOf(t.webView.url) : t.title
        return "📄 " + String(s.prefix(22))
    }

    @MainActor func gatherContexts() async -> [AIContext] {
        var out: [AIContext] = []
        if let t = current, !t.isNewTab {
            out.append(AIContext(label: ctxLabel(t), text: await readText(of: t)))
        }
        for e in aiExtras {
            if let t = e.tab, tabs.contains(where: { $0.id == t.id }), t.id != current?.id {
                out.append(AIContext(label: e.label, text: await readText(of: t)))
            } else if let txt = e.imageText {
                out.append(AIContext(label: e.label, text: txt))
            }
        }
        return out
    }

    func aiAtMention() {
        var entries: [MenuEntry] = []
        for t in tabs where !t.isNewTab && t.id != current?.id && !aiExtras.contains(where: { $0.tab?.id == t.id }) {
            entries.append(.item(ctxLabel(t), { [weak self] in self?.addAIContextTab(t) }))
        }
        if entries.isEmpty { entries = [.disabled("No other tabs to add")] }
        assistant.popMenuAtInput(buildMenu(entries))
    }
    func addAIContextTab(_ t: Tab) {
        if !aiExtras.contains(where: { $0.tab?.id == t.id }) { aiExtras.append(AIExtra(label: ctxLabel(t), tab: t, imageText: nil)) }
        updateAIContextPills()
    }
    func updateAIContextPills() {
        let cur = (current?.isNewTab == false) ? ctxLabel(current!) : nil
        aiExtras = aiExtras.filter { e in e.tab == nil || tabs.contains(where: { $0.id == e.tab!.id }) }
        assistant.setContextPills(current: cur, extras: aiExtras.map { $0.label })
    }
    func removeAIContext(_ index: Int) {
        if aiExtras.indices.contains(index) { aiExtras.remove(at: index) }
        updateAIContextPills()
    }

    // MARK: - Image attachments (Apple Vision OCR + labels) ----------------

    func aiAttachImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif, .bmp, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] resp in
            guard resp == .OK, let self else { return }
            for url in panel.urls {
                let name = url.lastPathComponent
                self.assistant.setStatus("Reading \(name)…")
                DispatchQueue.global(qos: .userInitiated).async {
                    let desc = VisionOCR.describe(url)
                    DispatchQueue.main.async {
                        self.aiExtras.append(AIExtra(label: "🖼 " + String(name.prefix(20)),
                                                     tab: nil, imageText: "Attached image \"\(name)\":\n\(desc)"))
                        self.assistant.setStatus(nil)
                        self.updateAIContextPills()
                    }
                }
            }
        }
    }

    // MARK: - AI tool callbacks (BrowserAITools) ----------------------------

    func readText(of t: Tab) async -> String {
        await withCheckedContinuation { cont in
            let js = "document.title + '\\n\\n' + (document.body ? document.body.innerText : '')"
            t.webView.evaluateJavaScript(js) { result, _ in
                var s = (result as? String) ?? ""
                if s.count > 6000 { s = String(s.prefix(6000)) }
                cont.resume(returning: s)
            }
        }
    }

    func waitForLoad(_ t: Tab) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            aiNavWaiters[t.id] = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                if let c = self?.aiNavWaiters.removeValue(forKey: t.id) { c.resume() }
            }
        }
    }

    @MainActor func aiReadCurrentPage() async -> String {
        guard let t = current, !t.isNewTab else { return "The user is on a blank new-tab page (no web content)." }
        let text = await readText(of: t)
        return "Current page (\(t.webView.url?.absoluteString ?? "")):\n\n" + text
    }

    /// Open a site in the browser (the user's current tab, so they see it) and
    /// return its title + text so the model can summarize / answer about it.
    @MainActor func aiOpenURL(_ url: String) async -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), u.host != nil else { return "Couldn't open \"\(url)\" — that doesn't look like a valid web address." }
        let t: Tab
        if let cur = current { cur.isNewTab = false; t = cur }
        else { let nt = Tab(); nt.isNewTab = false; wire(nt); tabs.append(nt); active = tabs.count - 1; t = nt }
        showActive(); refreshSidebar()
        assistant.setStatus("Opening \(hostOf(u))…")
        t.webView.load(URLRequest(url: u))
        await waitForLoad(t)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let the page settle
        let text = await readText(of: t)
        syncChrome(); refreshSidebar()
        assistant.setStatus("Thinking…")
        return "Opened \(u.absoluteString) in the browser. Title: \(t.webView.title ?? "")\n\nPage text:\n" + String(text.prefix(2500))
    }

    @MainActor func aiSearchWeb(_ query: String) async -> String {
        let t = Tab(); t.isNewTab = false
        wire(t); tabs.append(t); active = tabs.count - 1
        showActive(); refreshSidebar()
        assistant.setStatus("Searching the web…")
        if let u = URL(string: searchURL(for: query)) { t.webView.load(URLRequest(url: u)) }
        await waitForLoad(t)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let results render
        let text = await readText(of: t)
        assistant.setStatus("Thinking…")
        return "Web search results for \"\(query)\":\n\n" + text
    }

    @MainActor func aiSetReminder(_ text: String, minutes: Int) async -> String {
        let center = UNUserNotificationCenter.current()
        let secs = max(1, Double(minutes) * 60)
        return await withCheckedContinuation { cont in
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { cont.resume(returning: "I couldn't set the reminder — notifications are off for Breeze."); return }
                let content = UNMutableNotificationContent()
                content.title = "Breeze reminder"; content.body = text; content.sound = .default
                let trig = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trig)) { _ in
                    cont.resume(returning: "Reminder set: \"\(text)\" in \(minutes) minute\(minutes == 1 ? "" : "s").")
                }
            }
        }
    }

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

    /// On the first launch after an update, auto-open What's New (gated on the
    /// stored lastSeenVersion, like the Electron build). Fresh installs don't pop
    /// it. `BREEZE_WHATSNEW_FROM=<ver>` forces it for testing.
    func showWhatsNewIfUpdated() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let lastSeen = Store.shared.string("lastSeenVersion")
        let forced = ProcessInfo.processInfo.environment["BREEZE_WHATSNEW_FROM"] != nil
        Store.shared.settings["lastSeenVersion"] = current; Store.shared.saveSettings()
        guard forced || (!lastSeen.isEmpty && lastSeen != current) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.openInternal(.updates) }
    }

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

    /// The accent the HTML pages should use: the custom hex, or the mono default
    /// (near-black in light, near-white in dark) so pages match the chrome.
    func effectiveAccentHex() -> String {
        if isCustomAccentSetting() { return Store.shared.string("accent") }
        return effectiveTheme() == "dark" ? "#f5f5f7" : "#1c1c20"
    }
    func isCustomAccentSetting() -> Bool {
        let a = Store.shared.string("accent").lowercased()
        return !a.isEmpty && a != Theme.defaultAccent
    }
    /// Black or white text for legible text ON the accent color.
    func onAccentTextHex() -> String {
        guard let c = Theme.hex(effectiveAccentHex())?.usingColorSpace(.sRGB) else { return "#ffffff" }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? "#16161a" : "#ffffff"
    }

    private func bridgeStateJS() -> String {
        let theme = effectiveTheme()
        var settings = Store.shared.settings
        settings["accent"] = effectiveAccentHex()      // HTML follows the chrome accent
        let settingsJSON = Store.json(settings)
        let onText = onAccentTextHex()
        return """
        window.__bzTheme = '\(theme)';
        window.__bzSettings = \(settingsJSON);
        if (window.__bzOnTheme) window.__bzOnTheme('\(theme)');
        if (window.__bzOnSettings) window.__bzOnSettings(window.__bzSettings);
        (function(){var s=document.getElementById('bz-accent-fix')||document.createElement('style');
          s.id='bz-accent-fix';
          s.textContent='#settings-nav button.on,.seg button.on,.dz-btn:hover,#make-default,.tag,.badge{color:\(onText) !important;}';
          if(!s.parentNode)document.head.appendChild(s);})();
        """
    }

    /// Bake theme + settings into a freshly-loaded internal page.
    func injectBridgeState(into wv: WKWebView) { wv.evaluateJavaScript(bridgeStateJS()) }

    /// Push theme/settings changes to every open internal page.
    func broadcastToInternalPages() {
        let js = bridgeStateJS()
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
        case "getChats":
            resolve(Store.json(Store.shared.chats.map { ["id": $0["id"] ?? 0, "title": $0["title"] ?? "Chat"] }))
        case "openChat":
            if let id = chatId(from: args["id"]) {
                if !assistantOpen { setAssistant(true) }
                assistant.openChat(id: id)
            }
        case "deleteChat":
            if let id = chatId(from: args["id"]) { Store.shared.deleteChat(id: id) }
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

    /// Chat ids are JS numbers (a Double timestamp); accept Double/Int/String.
    private func chatId(from v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    func applySettingsChange() {
        applyThemeFromSettings()                  // posts Theme.didChange → chrome restyles
        pinSize = PinSize(rawValue: Store.shared.string("pinSize")) ?? .large
        renderPins()
        applyUrlBarMode()                         // top vs sidebar URL bar
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
        sbAddrWrap?.layer?.backgroundColor = p.surface.cgColor
        sbAddress.textColor = p.text
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
        // wake any AI agentic-search waiter for this tab
        if let tab = tabs.first(where: { $0.webView === w }), let c = aiNavWaiters.removeValue(forKey: tab.id) {
            c.resume()
        }
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        w.magnification = 1.0                 // every page loads at 100% — no stray pinch/smart-zoom carryover
        syncChrome()
        if isInternal(w) { injectBridgeState(into: w) }
    }
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let t = tabs.first(where: { $0.webView === w }), blockedPopups.contains(t.id) { return nil }
        if let u = a.request.url { openTab(url: u.absoluteString) }
        return nil
    }
}
