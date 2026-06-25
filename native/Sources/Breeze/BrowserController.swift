// The browser window: sidebar (pins + tabs + footer), top URL bar, web views,
// and the native new-tab page. Look ported from ui/index.html + style.css
// (urlbar-top mode, matching the screenshots).

import Cocoa
import WebKit
import UserNotifications
import CoreImage
import QuartzCore

let SIDEBAR_W: CGFloat = 286

enum BrowserInitialContent {
    case restoredSession, newTab, empty
}

final class BrowserController: NSObject, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate, WKScriptMessageHandler, WKDownloadDelegate, BrowserAITools {
    static let didUpdateState = Notification.Name("BrowserControllerDidUpdateState")
    static var sharedTabs: [Tab] = []
    static var sharedPins: [Pin] = []
    static var sharedGroups: [TabGroup] = []
    static var sharedNextGroupId = 1

    var tabs: [Tab] {
        get { BrowserController.sharedTabs }
        set { BrowserController.sharedTabs = newValue }
    }
    var pins: [Pin] {
        get { BrowserController.sharedPins }
        set { BrowserController.sharedPins = newValue }
    }
    var groups: [TabGroup] {
        get { BrowserController.sharedGroups }
        set { BrowserController.sharedGroups = newValue }
    }
    var nextGroupId: Int {
        get { BrowserController.sharedNextGroupId }
        set { BrowserController.sharedNextGroupId = newValue }
    }

    let window: NSWindow
    var active = 0 {
        willSet {
            if newValue != active {
                if window.firstResponder === address.currentEditor() {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }
    var pinSize: PinSize = .large      // Settings: small / medium / large
    lazy var placeholderView = TabPlaceholderView()
    var downloads: [DownloadItem] = []
    var activeDownloads: [ObjectIdentifier: WKDownload] = [:]
    var contextLinkURL: URL?
    var contextImageURL: URL?
    var contextPageURL: URL?
    var contextPageTitle = ""
    var contextSelectedText = ""
    var contextEditable = false
    var downloadList: [[String: Any]] { downloads.map { $0.dict } }
    var blockedPopups: Set<UUID> = []  // tabs with "Allow Popups" turned off
    var titleObs: [UUID: NSKeyValueObservation] = [:]
    var urlObs: [UUID: NSKeyValueObservation] = [:]
    var popupWindows: [UUID: NSWindow] = [:]
    var trafficLightBaseFrames: [NSWindow.ButtonType: NSRect] = [:]

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


    let nowPlaying = NowPlayingView()
    var nowPlayingTab: Tab?
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
    var assistantTopC: NSLayoutConstraint!
    var assistantBottomC: NSLayoutConstraint!
    var webTrailC: NSLayoutConstraint!
    var topTrailC: NSLayoutConstraint!
    var sidebarTopC: NSLayoutConstraint!
    var webContainerTopC: NSLayoutConstraint!
    var pinsTopC: NSLayoutConstraint!
    lazy var llm = OpenAILLM(tools: self)    // Breeze Cloud backend: OpenAI via the Cloudflare Worker
    var navLeadingC: NSLayoutConstraint!      // top-bar nav inset; shrinks in fullscreen (traffic lights hide until hover)
    let remindersView = RemindersView()
    var aiExtras: [AIExtra] = []             // @-added tabs + attached images (current tab always included)
    var aiNavWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    let ASSISTANT_W: CGFloat = 360

    // Rainbow glow border layer (shown during AI agentic work)
    private var glowPanel: NSPanel?
    private var rainbowContainer: CALayer?
    private var rainbowLayer: CAGradientLayer?
    private var rainbowMask: CAShapeLayer?

    // top bar
    let topBar = NSView()
    let topSidebarBtn = HoverButton(symbol: "sidebar.left")   // shown in top bar when sidebar collapsed
    let back = HoverButton(symbol: "chevron.left", point: 14)
    let forward = HoverButton(symbol: "chevron.right", point: 14)
    let reload = HoverButton(symbol: "arrow.clockwise", point: 13)
    let addressWrap = NSView()
    let address = NSTextField()
    let suggestionsPopover = AddressSuggestionsPopover()
    let bookmarkBtn = HoverButton(symbol: "bookmark", size: 22, point: 12)
    let adblockModeBtn = HoverButton(symbol: "shield.slash", size: 22, point: 11)
    let breezeCorner = NSButton()
    let findBar = NSView()
    let findField = NSSearchField()
    let findStatus = NSTextField(labelWithString: "")
    let findPrev = HoverButton(symbol: "chevron.up", size: 24, point: 11)
    let findNext = HoverButton(symbol: "chevron.down", size: 24, point: 11)
    let findClose = HoverButton(symbol: "xmark", size: 24, point: 10)

    // footer
    let adblockPill = NSView()
    let adblockCount = NSTextField(labelWithString: "0")

    var isPrivateWindow = false

    init(isPrivateWindow: Bool = false, initialContent: BrowserInitialContent = .restoredSession) {
        self.isPrivateWindow = isPrivateWindow
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 832),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = isPrivateWindow ? "Breeze (Private)" : "Breeze"
        window.tabbingMode = .disallowed
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
        buildFindBar()

        if Store.shared.string("sidebarWidthDefaultVersion") != "3.8.6" {
            sidebarWidth = SIDEBAR_W
            Store.shared.settings["sidebarWidth"] = Double(sidebarWidth)
            Store.shared.settings["sidebarWidthDefaultVersion"] = "3.8.6"
            Store.shared.saveSettings()
        } else if let w = Store.shared.settings["sidebarWidth"] as? Double, w >= 200, w <= 460 {
            sidebarWidth = w
        }
        sidebarLeft = sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 0)
        sidebarWidthC = sidebar.widthAnchor.constraint(equalToConstant: sidebarWidth)
        topTrailC = addressWrap.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -54)
        topTrailC.isActive = true

        sidebarTopC = sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        sidebarTopC.isActive = true

        NSLayoutConstraint.activate([
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarWidthC,
            sidebarLeft,

            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 54),
        ])
        NSLayoutConstraint.activate([
            webContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 6),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        webTrailC = webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6)
        webTrailC.isActive = true

        webContainerTopC = webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6)
        webContainerTopC.isActive = true

        // breeze corner mark — pinned top-right of the window
        root.addSubview(breezeCorner)
        breezeCorner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            breezeCorner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            breezeCorner.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            breezeCorner.widthAnchor.constraint(equalToConstant: 30),
            breezeCorner.heightAnchor.constraint(equalToConstant: 30),
        ])

        // left-edge peek strip (on top, only live when the sidebar is hidden)
        root.addSubview(edgeHandle)
        edgeHandle.translatesAutoresizingMaskIntoConstraints = false
        edgeHandle.isHidden = true
        NSLayoutConstraint.activate([
            edgeHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            edgeHandle.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            edgeHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            edgeHandle.widthAnchor.constraint(equalToConstant: 8),
        ])
        // sidebar resize handle (straddles the sidebar's right edge)
        root.addSubview(sidebarResizer)
        sidebarResizer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarResizer.centerXAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarResizer.topAnchor.constraint(equalTo: topBar.bottomAnchor),
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
        assistant.isHidden = true
        assistantLeadingC = assistant.leadingAnchor.constraint(equalTo: root.trailingAnchor, constant: 0)
        assistantWidthC = assistant.widthAnchor.constraint(equalToConstant: ASSISTANT_W)
        assistantTopC = assistant.topAnchor.constraint(equalTo: root.topAnchor)
        assistantBottomC = assistant.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        NSLayoutConstraint.activate([
            assistantTopC,
            assistantBottomC,
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
        assistant.onDownloadImagePath = { [weak self] path in self?.downloadAIImage(path: path) }
        remindersView.onCancelReminder = { [weak self] id in
            self?.deleteReminderById(id)
        }
        llm.onStatus = { [weak self] s in
            guard let self else { return }
            self.assistant.setModelStatus(s)                 // empty-state line
            self.assistant.setStatus(self.llm.ready ? nil : s)   // also show progress during a chat
            self.broadcastToInternalPages()
        }

        window.contentView = root
        
        window.makeKeyAndOrderFront(nil)
        alignTrafficLights()

        // load persisted state + apply settings
        pins = Store.shared.pins
        pinSize = PinSize(rawValue: Store.shared.string("pinSize")) ?? .large
        applyThemeFromSettings()
        renderPins()
        
        if initialContent == .empty {
            refreshSidebar()
        } else if isPrivateWindow {
            openNewTab(isPrivate: true)
        } else if initialContent == .newTab {
            openNewTab()
        } else if BrowserController.sharedTabs.isEmpty {
            let restoreMode = Store.shared.settings["restoreTabs"] as? String ?? "ask"
            if restoreMode == "always" && !Store.shared.openTabs.isEmpty {
                for url in Store.shared.openTabs { openTab(url: url) }
            } else if restoreMode == "ask" && !Store.shared.openTabs.isEmpty {
                openNewTab()
                let alert = NSAlert()
                alert.messageText = "Restore Previous Session?"
                alert.informativeText = "You had \(Store.shared.openTabs.count) tabs open. Would you like to restore them?"
                alert.addButton(withTitle: "Restore")
                alert.addButton(withTitle: "Start Fresh")
                if alert.runModal() == .alertFirstButtonReturn {
                    for url in Store.shared.openTabs { openTab(url: url) }
                    closeTab(tabs[0]) // close the initial new tab
                } else {
                    Store.shared.openTabs = []; Store.shared.saveOpenTabs()
                }
            } else {
                openNewTab()
            }
        } else {
            active = 0
            showActive()
        }
        startSleepTimer()
        initReminders()
        suggestionsPopover.delegate = self
        address.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(stateDidUpdate), name: BrowserController.didUpdateState, object: nil)
        
        NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: window, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            if Store.shared.settings["autoPip"] as? Bool != false, let t = self.current, t.isPlaying {
                self.pip(for: t.webView, toggle: false)
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: nil) { [weak self] _ in
            // Traffic lights hide until hover in fullscreen — reclaim the space we
            // normally reserve for them next to the sidebar/nav buttons.
            self?.navLeadingC?.constant = 12
            if Store.shared.settings["flattenFullscreenCorners"] as? Bool != false {
                self?.window.titlebarAppearsTransparent = false
                self?.window.backgroundColor = .black
            }
        }

        NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: nil) { [weak self] _ in
            self?.navLeadingC?.constant = 92   // restore the traffic-light gap when windowed
            self?.window.titlebarAppearsTransparent = true
            self?.window.backgroundColor = .windowBackgroundColor
        }
    }

    var current: Tab? { tabs.indices.contains(active) ? tabs[active] : nil }

    // MARK: - Sidebar -------------------------------------------------------

    func buildSidebar() {
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        // pins grid (4-wide rows)
        pinsStack.orientation = .vertical; pinsStack.spacing = 7; pinsStack.alignment = .leading
        pinsStack.translatesAutoresizingMaskIntoConstraints = false

        // tabs
        tabsStack.orientation = .vertical; tabsStack.spacing = 3; tabsStack.alignment = .leading
        tabsStack.translatesAutoresizingMaskIntoConstraints = false
        let tabsDoc = FlippedView()
        tabsDoc.translatesAutoresizingMaskIntoConstraints = false
        tabsDoc.addSubview(tabsStack)

        let newTabBtn = LinePlusButton()
        newTabBtn.onTap = { [weak self] in self?.openNewTab() }
        newTabBtn.translatesAutoresizingMaskIntoConstraints = false
        tabsDoc.addSubview(newTabBtn)

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
        nowPlaying.dismissBtn.onTap = { [weak self] in self?.dismissNowPlaying() }
        let bottomStack = NSStackView(views: [remindersView, nowPlaying, footer])
        bottomStack.orientation = .vertical; bottomStack.spacing = 8; bottomStack.alignment = .leading
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        remindersView.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
        nowPlaying.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: bottomStack.widthAnchor).isActive = true

        sidebar.addSubview(pinsStack)
        sidebar.addSubview(tabsScroll)
        sidebar.addSubview(bottomStack)
        pinsTopC = pinsStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 12)
        NSLayoutConstraint.activate([
            pinsTopC,
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

            newTabBtn.topAnchor.constraint(equalTo: tabsStack.bottomAnchor, constant: 10),
            newTabBtn.leadingAnchor.constraint(equalTo: tabsDoc.leadingAnchor),
            newTabBtn.trailingAnchor.constraint(equalTo: tabsDoc.trailingAnchor),
            newTabBtn.centerXAnchor.constraint(equalTo: tabsDoc.centerXAnchor),
            newTabBtn.heightAnchor.constraint(equalToConstant: 24),
            newTabBtn.bottomAnchor.constraint(equalTo: tabsDoc.bottomAnchor, constant: -10),

            bottomStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            bottomStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            bottomStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -12),
        ])
    }



    func buildFooter() -> NSView {
        let footer = NSView(); footer.translatesAutoresizingMaskIntoConstraints = false

        let settings = HoverButton(symbol: "gearshape")
        settings.onTap = { [weak self] in self?.openInternal(.settings) }
        let dl = HoverButton(symbol: "arrow.down.to.line")
        dl.onTap = { [weak self] in self?.openInternal(.downloads) }
        let bookmarks = HoverButton(symbol: "bookmark")
        bookmarks.onTap = { [weak self] in self?.openInternal(.bookmarks) }
        let history = HoverButton(symbol: "clock")
        history.onTap = { [weak self] in self?.openInternal(.history) }
        let theme = HoverButton(symbol: "sun.max"); theme.onTap = { [weak self] in
            self?.cycleThemeSetting(); self?.refreshThemeIcon(theme)
        }
        let row = NSStackView(views: [settings, theme, history, bookmarks, dl])
        row.spacing = 8; row.alignment = .centerY
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
            v.dragPayload = SidebarDragPayload(kind: .pin, id: p.url)
            v.onDropPayload = { [weak self] payload, placement in self?.dropSidebarPayload(payload, onPin: p.url, placement: placement) ?? false }
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
        reload.onTap = { [weak self] in self?.reloadCurrentTab() }

        addressWrap.wantsLayer = true; addressWrap.layer?.cornerRadius = 19
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
        clearc.onTap = { [weak self] in self?.clearCurrentSiteCache() }
        bookmarkBtn.onTap = { [weak self] in self?.toggleBookmark() }
        adblockModeBtn.toolTip = "Turn off Extreme blocking for this site"
        adblockModeBtn.onTap = { [weak self] in self?.allowCurrentSiteInExtremeAdblock() }
        let share = HoverButton(symbol: "square.and.arrow.up", size: 22, point: 12)
        share.onTap = { [weak self, weak share] in self?.shareCurrentPage(from: share) }
        addressWrap.addSubview(copylink); addressWrap.addSubview(address)
        addressWrap.addSubview(clearc); addressWrap.addSubview(bookmarkBtn); addressWrap.addSubview(adblockModeBtn); addressWrap.addSubview(share)
        let actions = NSStackView(views: [clearc, bookmarkBtn, adblockModeBtn, share]); actions.spacing = 2
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

        topSidebarBtn.onTap = { [weak self] in self?.toggleSidebar() }
        topSidebarBtn.isHidden = false
        let nav = NSStackView(views: [topSidebarBtn, back, forward, reload]); nav.spacing = 2
        nav.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(nav); topBar.addSubview(addressWrap)
        navLeadingC = nav.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 92)
        NSLayoutConstraint.activate([
            navLeadingC,
            nav.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addressWrap.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 8),
            addressWrap.centerYAnchor.constraint(equalTo: topBar.centerYAnchor, constant: 2),
            addressWrap.heightAnchor.constraint(equalToConstant: 38),
        ])

        breezeCorner.isBordered = false
        breezeCorner.image = navLogo()
        breezeCorner.imageScaling = .scaleProportionallyDown
        breezeCorner.target = self; breezeCorner.action = #selector(openAssistant)
    }

    func buildFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.wantsLayer = true
        findBar.layer?.cornerRadius = 21
        findBar.layer?.masksToBounds = false
        findBar.layer?.backgroundColor = findBarBackgroundColor().cgColor
        findBar.layer?.shadowColor = NSColor.black.cgColor
        findBar.layer?.shadowOpacity = 0.18
        findBar.layer?.shadowRadius = 18
        findBar.layer?.shadowOffset = NSSize(width: 0, height: -8)
        findBar.layer?.borderWidth = 1
        findBar.layer?.borderColor = Theme.shared.palette.textSoft.withAlphaComponent(0.18).cgColor
        findBar.layer?.zPosition = 1000
        findBar.isHidden = true

        findField.translatesAutoresizingMaskIntoConstraints = false
        findField.placeholderString = "Find in page"
        findField.font = .systemFont(ofSize: 13)
        findField.isBordered = false
        findField.drawsBackground = true
        findField.backgroundColor = .clear
        findField.focusRingType = .none
        findField.textColor = Theme.shared.palette.text
        findField.delegate = self
        findField.target = self
        findField.action = #selector(findFieldSubmit)

        findStatus.translatesAutoresizingMaskIntoConstraints = false
        findStatus.font = .systemFont(ofSize: 11)
        findStatus.textColor = Theme.shared.palette.textSoft
        findStatus.alignment = .right

        findPrev.onTap = { [weak self] in self?.findPrevious() }
        findNext.onTap = { [weak self] in self?.findNextMatch() }
        findClose.onTap = { [weak self] in self?.closeFindBar() }

        let controls = NSStackView(views: [findStatus, findPrev, findNext, findClose])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 2

        findBar.addSubview(findField)
        findBar.addSubview(controls)
        root.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            findBar.widthAnchor.constraint(equalToConstant: 360),
            findBar.heightAnchor.constraint(equalToConstant: 42),

            findField.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 14),
            findField.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findField.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -8),

            controls.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findStatus.widthAnchor.constraint(equalToConstant: 62),
        ])
    }

    @objc func openFindBar() {
        guard current?.isNewTab == false, current?.isChatTab == false else { return }
        findBar.isHidden = false
        updateFindBarAppearance()
        root.addSubview(findBar, positioned: .above, relativeTo: nil)
        if findField.stringValue.isEmpty {
            current?.webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
                guard let self else { return }
                if let s = result as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.findField.stringValue = s
                }
                self.window.makeFirstResponder(self.findField)
                self.findField.currentEditor()?.selectAll(nil)
            }
        } else {
            window.makeFirstResponder(findField)
            findField.currentEditor()?.selectAll(nil)
        }
    }

    @objc func closeFindBar() {
        findBar.isHidden = true
        findStatus.stringValue = ""
        if current?.isNewTab == false, let webView = current?.webView {
            window.makeFirstResponder(webView)
        }
    }

    @objc func findFieldSubmit() { findNextMatch() }
    @objc func findNextMatch() { performFind(backwards: false) }
    @objc func findPrevious() { performFind(backwards: true) }

    func performFind(backwards: Bool) {
        guard current?.isNewTab == false, current?.isChatTab == false, let webView = current?.webView else { return }
        let term = findField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            findStatus.stringValue = ""
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(term, configuration: config) { [weak self] result in
            DispatchQueue.main.async {
                self?.findStatus.stringValue = result.matchFound ? "" : "No match"
            }
        }
    }

    // MARK: - Web area ------------------------------------------------------

    func buildWebArea() {
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.wantsLayer = true
        // Rounded web area lives on the container, NOT the web view's own layer —
        // clipping the web view itself turns fullscreen video into a black screen.
        webContainer.layer?.cornerRadius = 10
        webContainer.layer?.masksToBounds = true
        newTab.translatesAutoresizingMaskIntoConstraints = false
        newTab.onSubmit = { [weak self] t, cmd in self?.submitQuery(t, isCmdEnter: cmd) }
        newTab.field.delegate = self
    }

    // Rounded corners on the web area clip WebKit's hardware video overlay to a
    // black rectangle once a video goes fullscreen (same root cause as the old
    // Electron "flatten corners in fullscreen" fix). Flatten while fullscreen,
    // restore the 10pt radius on exit. Driven by breezeFullscreenJS.
    var webFullscreen = false
    func setWebFullscreen(_ on: Bool) {
        guard on != webFullscreen else { return }
        webFullscreen = on
        webContainer.layer?.masksToBounds = !on
        webContainer.layer?.cornerRadius = on ? 0 : 10
    }

    func showActive() {
        // Detach assistant from webContainer before clearing (it's a shared instance)
        let assistantWasInChatTab = assistant.superview == webContainer
        if assistantWasInChatTab {
            // Keep its fullscreen-width children from drawing past the right edge
            // while the panel is moved back under the root view.
            assistant.isHidden = true
            assistant.removeFromSuperview()
        }
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        splitLeftWidthC = nil
        guard let t = current else { return }

        // Chat tabs embed the assistant panel directly in the web container
        if t.isChatTab {
            newTab.stopClock()
            topBar.isHidden = false
            setSidebarHidden(true)
            
            sidebarTopC.isActive = false
            sidebarTopC = sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor)
            sidebarTopC.isActive = true

            webContainerTopC.isActive = false
            webContainerTopC = webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6)
            webContainerTopC.isActive = true

            pinsTopC.constant = 12
            
            // Deactivate sidebar constraints so it can stretch to fill the container
            assistantLeadingC.isActive = false
            assistantWidthC.isActive = false
            assistantTopC.isActive = false
            assistantBottomC.isActive = false
            
            // Collapse the right-side assistant panel space completely
            assistantOpen = false
            breezeCorner.isHidden = false
            webTrailC.constant = -6
            topTrailC.constant = -54
            root.layoutSubtreeIfNeeded()
            
            assistant.isHidden = false
            assistant.setFullscreen(true, clearLights: false)
            webContainer.addSubview(assistant); assistant.pin(to: webContainer)
            assistant.focusInput()
            syncChrome()
            scheduleReflow()
            return
        }

        let primary: NSView = t.isNewTab ? newTab : t.webView
        if t.isNewTab { newTab.startClock() } else { newTab.stopClock() }

        // If assistant was in a chat tab, re-attach it to root and restore sidebar constraints
        if assistant.superview == nil || assistant.superview == webContainer {
            assistant.removeFromSuperview()
            root.addSubview(assistant)
            assistantLeadingC.isActive = true
            assistantWidthC.isActive = true
            assistantTopC.isActive = true
            assistantBottomC.isActive = true
            let w = ASSISTANT_W
            assistantWidthC.constant = w
            if assistantWasInChatTab {
                // Leaving a fullscreen chat tab: COLLAPSE the docked panel instead of
                // force-opening it as a clipped right-side strip (the bug). The chat
                // stays in its own chat tab (still in the tab list); the user re-opens
                // the assistant when they want it.
                // Collapse instantly without animation to prevent UI bleeding/clipping
                assistantOpen = false
                assistant.setFullscreen(false, clearLights: false)
                breezeCorner.isHidden = false
                assistantLeadingC.constant = 0
                webTrailC.constant = -6
                topTrailC.constant = -54
                root.layoutSubtreeIfNeeded()
                scheduleReflow()
                assistant.isHidden = true // Hide instantly!
            } else {
                assistantLeadingC.constant = assistantOpen ? -w : 0
                assistant.isHidden = !assistantOpen
            }
        }

        if let partnerId = t.splitPartnerId, let s = tabs.first(where: { $0.id == partnerId }) {
            topBar.isHidden = true                       // per-pane URL bars replace the global one
            
            sidebarTopC.isActive = false
            sidebarTopC = sidebar.topAnchor.constraint(equalTo: root.topAnchor)
            sidebarTopC.isActive = true

            webContainerTopC.isActive = false
            webContainerTopC = webContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 6)
            webContainerTopC.isActive = true

            pinsTopC.constant = 54

            let isCurrentOnRight = t.splitIsRight
            let leftTab = isCurrentOnRight ? s : t
            let rightTab = isCurrentOnRight ? t : s
            
            leftPane.host(leftTab.isNewTab ? newTab : leftTab.webView)
            rightPane.host(rightTab.isNewTab ? newTab : rightTab.webView)
            wireSplitPane(leftPane, tab: leftTab)
            wireSplitPane(rightPane, tab: rightTab)
            leftPane.setURL(leftTab.isNewTab ? "" : (leftTab.webView.url?.absoluteString ?? ""))
            rightPane.setURL(rightTab.isNewTab ? "" : (rightTab.webView.url?.absoluteString ?? ""))
            leftPane.showsSidebarToggle = true
            rightPane.showsSidebarToggle = false
            leftPane.setLeftSpacingForTrafficLights(sidebarHidden)
            rightPane.setLeftSpacingForTrafficLights(false)

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
            // Clean up partner if it was set but partner is no longer in tabs list
            if t.splitPartnerId != nil {
                t.splitPartnerId = nil
                t.splitIsRight = false
            }
            topBar.isHidden = false
            
            sidebarTopC.isActive = false
            sidebarTopC = sidebar.topAnchor.constraint(equalTo: topBar.bottomAnchor)
            sidebarTopC.isActive = true

            webContainerTopC.isActive = false
            webContainerTopC = webContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 6)
            webContainerTopC.isActive = true

            pinsTopC.constant = 12

            primary.removeFromSuperview()
            webContainer.addSubview(primary); primary.pin(to: webContainer)
        }
        updateWebViewDisplay()
        syncChrome()
        scheduleReflow()      // a re-shown web view may have a stale layout width
    }

    func updateWebViewDisplay() {
        guard let t = current else { return }
        if t.isNewTab || t.isChatTab || t.splitPartnerId != nil {
            placeholderView.removeFromSuperview()
            t.webView.isHidden = false
            return
        }
        if t.webView.superview == webContainer {
            placeholderView.removeFromSuperview()
            t.webView.isHidden = false
        } else {
            t.webView.isHidden = true
            if placeholderView.superview != webContainer {
                webContainer.addSubview(placeholderView)
                placeholderView.pin(to: webContainer)
                placeholderView.onPull = { [weak self] in
                    self?.pullActiveTab()
                }
            }
        }
    }

    func pullActiveTab() {
        guard let t = current else { return }
        t.webView.removeFromSuperview()
        webContainer.addSubview(t.webView)
        t.webView.pin(to: webContainer)
        t.webView.isHidden = false
        placeholderView.removeFromSuperview()
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
    }

    @objc private func stateDidUpdate() {
        refreshSidebar()
        syncChrome()
        updateWebViewDisplay()
    }

    func wireSplitPane(_ pane: SplitPane, tab: Tab) {
        pane.onNavigate = { [weak self, weak tab] text in if let tab { self?.navigateTab(tab, text) } }
        pane.back.onTap = { [weak tab] in tab?.webView.goBack() }
        pane.forward.onTap = { [weak tab] in tab?.webView.goForward() }
        pane.reload.onTap = { [weak self, weak pane, weak tab] in
            if let pane { self?.spinReloadButton(pane.reload) }
            tab?.webView.reload()
        }
        pane.onSidebarToggle = { [weak self] in self?.toggleSidebar() }
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
        guard let current = current, t.id != current.id else { return }
        // Ensure both are fully populated
        guard !current.isNewTab && !current.isChatTab && !t.isNewTab && !t.isChatTab else { return }
        
        current.splitPartnerId = t.id
        current.splitIsRight = false
        
        t.splitPartnerId = current.id
        t.splitIsRight = true
        
        showActive()
        refreshSidebar()
    }
    func exitSplit(_ t: Tab) {
        if let partnerId = t.splitPartnerId, let partner = tabs.first(where: { $0.id == partnerId }) {
            partner.splitPartnerId = nil
            partner.splitIsRight = false
        }
        t.splitPartnerId = nil
        t.splitIsRight = false
        showActive()
        refreshSidebar()
    }

    @objc func dragSplit(_ g: NSPanGestureRecognizer) {
        let w = max(webContainer.bounds.width, 1)
        splitRatio = max(0.2, min(0.8, splitRatio + g.translation(in: webContainer).x / w))
        g.setTranslation(.zero, in: webContainer)
        splitLeftWidthC?.constant = w * splitRatio - 3
        if g.state == .ended { scheduleReflow() }
    }

    func windowDidResize(_ n: Notification) {
        splitLeftWidthC?.constant = max(webContainer.bounds.width, 1) * splitRatio - 3
        updateRainbowFrame()
        alignTrafficLights()
        scheduleReflow()
    }

    func windowDidMove(_ n: Notification) {
        alignTrafficLights()
        updateRainbowFrame()
    }

    func alignTrafficLights() {
        let offsetX: CGFloat = 10
        let offsetY: CGFloat = -11
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            if trafficLightBaseFrames[type] == nil {
                trafficLightBaseFrames[type] = button.frame
            }
            guard var frame = trafficLightBaseFrames[type] else { continue }
            frame.origin.x += offsetX
            frame.origin.y += offsetY
            button.setFrameOrigin(frame.origin)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            if win === window {
                for (_, w) in popupWindows {
                    w.close()
                }
                popupWindows.removeAll()
            } else {
                for (id, w) in popupWindows {
                    if w === win {
                        popupWindows.removeValue(forKey: id)
                        break
                    }
                }
            }
        }
    }

    func makeTabRow(_ t: Tab) -> TabRowView {
        let i = tabs.firstIndex { $0.id == t.id } ?? 0
        let title = t.isChatTab ? "Nav Chat" : t.title
        let host = t.isChatTab ? "nav" : hostOf(t.webView.url)
        let inSplit = (t.splitPartnerId != nil)
        let row = TabRowView(title: title, host: host, active: i == active,
                             perf: t.perfMode, asleep: t.sleeping, inSplit: inSplit, isPrivate: t.isPrivate)
        row.onSelect = { [weak self] in self?.select(i) }
        row.onClose = { [weak self] in self?.closeTab(t) }
        row.menuProvider = { [weak self] in self?.tabMenu(for: t) ?? [] }
        row.dragPayload = SidebarDragPayload(kind: .tab, id: t.id.uuidString)
        row.onDropPayload = { [weak self] payload, placement in self?.dropSidebarPayload(payload, onTab: t.id, placement: placement) ?? false }
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
        if canSleepTab(t) {
            e.append(.item("Sleep Tab", { [weak self] in self?.sleepTab(t) }))
        }
        e.append(.separator)
        // Split view
        if t.splitPartnerId != nil {
            e.append(.item("Exit Split View", { [weak self] in self?.exitSplit(t) }))
        } else {
            let canSplit = !t.isNewTab && !t.isChatTab && t.id != current?.id && tabs.count > 1 &&
                           (current != nil && !current!.isNewTab && !current!.isChatTab)
            if canSplit {
                e.append(.item("Open in Split View", { [weak self] in self?.enterSplit(t) }))
            } else {
                e.append(.disabled("Open in Split View"))
            }
        }
        e.append(.separator)
        // Performance Mode (boost) + Allow Popups — checkboxes, like Electron
        if isWeb {
            e.append(.check("🚀 Performance Mode", t.perfMode, { [weak self] in self?.setPerfMode(t, !t.perfMode) }))
            e.append(.check("Allow Popups", !blockedPopups.contains(t.id), { [weak self] in self?.togglePopups(t) }))
        }
        e.append(.separator)
        if tabs.count > 1 {
            e.append(.item("Close Other Tabs", { [weak self] in self?.closeOtherTabs(keeping: t) }))
        } else {
            e.append(.disabled("Close Other Tabs"))
        }
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
            header.menuProvider = { [weak self] in self?.groupMenu(for: g) ?? [] }
            header.dragPayload = SidebarDragPayload(kind: .group, id: "\(g.id)")
            header.onDropPayload = { [weak self] payload, placement in self?.dropSidebarPayload(payload, onGroup: g.id, placement: placement) ?? false }
            add(header)
            if !g.collapsed { for t in members { add(makeTabRow(t)) } }
        }
        // ungrouped, non-pinned tabs (pinned tabs are housed in their pin icon)
        for t in tabs where t.groupId == nil && t.pinUrl == nil { add(makeTabRow(t)) }
    }

    func dropSidebarPayload(_ payload: SidebarDragPayload, onPin targetURL: String, placement: SidebarDropPlacement) -> Bool {
        guard payload.kind == .pin, payload.id != targetURL,
              let from = pins.firstIndex(where: { $0.url == payload.id }),
              let to = pins.firstIndex(where: { $0.url == targetURL }) else { return false }
        let pin = pins.remove(at: from)
        var target = to
        if from < to { target -= 1 }
        if placement == .after { target += 1 }
        pins.insert(pin, at: max(0, min(target, pins.count)))
        persistPins()
        renderPins()
        return true
    }

    func dropSidebarPayload(_ payload: SidebarDragPayload, onTab targetID: UUID, placement: SidebarDropPlacement) -> Bool {
        guard payload.kind == .tab,
              let sourceID = UUID(uuidString: payload.id),
              sourceID != targetID,
              let from = tabs.firstIndex(where: { $0.id == sourceID }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return false }
        let currentID = current?.id
        let targetGroup = tabs[to].groupId
        let tab = tabs.remove(at: from)
        tab.groupId = targetGroup
        var target = to
        if from < to { target -= 1 }
        if placement == .after { target += 1 }
        tabs.insert(tab, at: max(0, min(target, tabs.count)))
        if let currentID, let idx = tabs.firstIndex(where: { $0.id == currentID }) { active = idx }
        renderTabs()
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
        return true
    }

    func dropSidebarPayload(_ payload: SidebarDragPayload, onGroup targetID: Int, placement: SidebarDropPlacement) -> Bool {
        switch payload.kind {
        case .tab:
            guard let sourceID = UUID(uuidString: payload.id),
                  let idx = tabs.firstIndex(where: { $0.id == sourceID }) else { return false }
            let currentID = current?.id
            tabs[idx].groupId = targetID
            if let lastMember = tabs.lastIndex(where: { $0.groupId == targetID && $0.id != sourceID }) {
                let tab = tabs.remove(at: idx)
                let insertAt = idx < lastMember ? lastMember : min(lastMember + 1, tabs.count)
                tabs.insert(tab, at: insertAt)
            }
            if let currentID, let activeIndex = tabs.firstIndex(where: { $0.id == currentID }) { active = activeIndex }
            renderTabs()
            NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
            return true
        case .group:
            guard let sourceID = Int(payload.id), sourceID != targetID,
                  let from = groups.firstIndex(where: { $0.id == sourceID }),
                  let to = groups.firstIndex(where: { $0.id == targetID }) else { return false }
            let group = groups.remove(at: from)
            var target = to
            if from < to { target -= 1 }
            if placement == .after { target += 1 }
            groups.insert(group, at: max(0, min(target, groups.count)))
            renderTabs()
            return true
        case .pin:
            return false
        }
    }

    // MARK: - Tab groups ----------------------------------------------------

    func pinMenu(_ url: String) -> [MenuEntry] {
        if let tab = pinnedTab(url) {
            var entries: [MenuEntry] = [
                .item(tab.id == current?.id ? "Open" : "Switch to Pin", { [weak self] in self?.openPin(url) }),
                .separator,
            ]
            entries.append(contentsOf: tabMenu(for: tab))
            return entries
        }
        return [
            .item("Open", { [weak self] in self?.openPin(url) }),
            .disabled("Close Tab"),
            .separator,
            .item("Unpin", { [weak self] in self?.unpin(url) }),
        ]
    }
    func newGroup(with t: Tab) {
        let g = TabGroup(id: nextGroupId, name: suggestedGroupName(for: t)); nextGroupId += 1
        groups.append(g); t.groupId = g.id; renderTabs()
    }
    func addToGroup(_ t: Tab, _ id: Int) { t.groupId = id; renderTabs() }
    func removeFromGroup(_ t: Tab) {
        let gid = t.groupId; t.groupId = nil
        if let gid, !tabs.contains(where: { $0.groupId == gid }) { groups.removeAll { $0.id == gid } }
        renderTabs()
    }
    func groupMenu(for g: TabGroup) -> [MenuEntry] {
        [
            .item("Rename Group…", { [weak self] in self?.renameGroup(g.id) }),
            .item("Disband Group", { [weak self] in self?.disbandGroup(g.id) }),
            .separator,
            .item("Delete Group Tabs", { [weak self] in self?.deleteGroup(g.id) }),
        ]
    }
    func suggestedGroupName(for t: Tab) -> String {
        let host = hostOf(t.webView.url)
        return host.isEmpty ? "Group \(nextGroupId)" : host
    }
    func renameGroup(_ id: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.informativeText = "Choose a short name for this tab group."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = groups[idx].name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        groups[idx].name = name.isEmpty ? "Group \(id)" : name
        renderTabs()
    }
    func disbandGroup(_ id: Int) {
        for t in tabs where t.groupId == id { t.groupId = nil }
        groups.removeAll { $0.id == id }
        renderTabs()
    }
    func deleteGroup(_ id: Int) {
        let members = tabs.filter { $0.groupId == id }
        guard !members.isEmpty else { groups.removeAll { $0.id == id }; renderTabs(); return }
        let alert = NSAlert()
        alert.messageText = "Delete Group Tabs?"
        alert.informativeText = "This closes \(members.count) tab\(members.count == 1 ? "" : "s") in this group."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for t in members { closeTab(t) }
        groups.removeAll { $0.id == id }
        renderTabs()
    }

    // MARK: - Tab ops -------------------------------------------------------

    func openNewTab(isPrivate: Bool = false) {
        autoPipLeavingTab()                       // keep a playing video alive via PiP
        let p = isPrivate || isPrivateWindow
        let t = Tab(isPrivate: p)
        wire(t)
        tabs.append(t); active = tabs.count - 1
        showActive(); refreshSidebar()
        window.makeFirstResponder(newTab.field)
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
    }

    @discardableResult
    func openTab(url: String, isPrivate: Bool = false) -> Tab {
        let p = isPrivate || isPrivateWindow
        let t = Tab(isPrivate: p); t.isNewTab = false
        wire(t)
        tabs.append(t); active = tabs.count - 1
        
        var targetURL: URL?
        if url.hasPrefix("file://") {
            let path = String(url.dropFirst(7)).removingPercentEncoding ?? String(url.dropFirst(7))
            targetURL = URL(fileURLWithPath: path)
        } else if url.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: url)
        } else if let u = URL(string: url) {
            targetURL = u
        } else if let escaped = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            targetURL = URL(string: escaped)
        }
        
        if let u = targetURL {
            t.webView.load(URLRequest(url: u))
        }
        
        showActive(); refreshSidebar()
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
        return t
    }

    @discardableResult
    func openTab(url: URL, from source: Tab? = nil, autoGroupSameSite: Bool = false) -> Tab {
        let t = openTab(url: url.absoluteString, isPrivate: source?.isPrivate ?? false)
        if autoGroupSameSite, let source, sameSite(source.webView.url, url) {
            if let gid = source.groupId {
                t.groupId = gid
            } else {
                let g = TabGroup(id: nextGroupId, name: suggestedGroupName(for: source))
                nextGroupId += 1
                groups.append(g)
                source.groupId = g.id
                t.groupId = g.id
            }
            renderTabs()
        }
        return t
    }

    func sameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let ah = normalizedSiteHost(a), let bh = normalizedSiteHost(b) else { return false }
        return ah == bh
    }

    func normalizedSiteHost(_ url: URL?) -> String? {
        guard var h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    func reloadCurrentTab() {
        spinReloadButton(reload)
        current?.webView.reload()
    }

    func zoomPage(by delta: CGFloat) {
        guard let t = current, !t.isNewTab, !t.isChatTab else { return }
        let next = min(3.0, max(0.5, t.pageZoom + delta))
        t.pageZoom = next
        t.webView.magnification = next
    }

    func resetPageZoom() {
        guard let t = current, !t.isNewTab, !t.isChatTab else { return }
        t.pageZoom = 1.0
        t.webView.magnification = 1.0
    }

    func spinReloadButton(_ button: NSView) {
        if let button = button as? HoverButton {
            button.spinGlyph()
            return
        }
    }

    func wire(_ t: Tab) {
        t.webView.navigationDelegate = self
        t.webView.uiDelegate = self
        titleObs[t.id] = t.webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            t.title = (wv.title?.isEmpty == false) ? wv.title! : "New Tab"
            self?.refreshSidebar()
            NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
        }
        urlObs[t.id] = t.webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            self?.syncChrome(); self?.refreshSidebar()
            NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
        }
    }

    func closeTab(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        titleObs[t.id] = nil; urlObs[t.id] = nil
        if nowPlayingTab?.id == t.id { nowPlayingTab = nil }
        if let partnerId = t.splitPartnerId, let partner = tabs.first(where: { $0.id == partnerId }) {
            partner.splitPartnerId = nil
            partner.splitIsRight = false
        }
        t.webView.removeFromSuperview(); tabs.remove(at: i)
        if tabs.isEmpty { openNewTab(); return }
        active = min(active, tabs.count - 1); showActive(); refreshSidebar(); updateNowPlaying()
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
    }

    func closeOtherTabs(keeping keeper: Tab) {
        guard tabs.contains(where: { $0.id == keeper.id }) else { return }
        let victims = tabs.filter { $0.id != keeper.id }
        guard !victims.isEmpty else { return }
        for tab in victims { closeTab(tab) }
        if let idx = tabs.firstIndex(where: { $0.id == keeper.id }) {
            select(idx)
        }
    }

    /// When leaving a tab that's playing a video, pop it into Picture-in-Picture so
    /// it keeps playing (otherwise WebKit pauses it once the web view leaves the
    /// window). Gated by the autoPip setting. Must be called BEFORE the active tab
    /// changes — the video has to still be on screen/ready for the request to take.
    func autoPipLeavingTab() {
        guard Store.shared.settings["autoPip"] as? Bool != false,
              let t = current, t.isPlaying else { return }
        pip(for: t.webView, toggle: false)
    }

    func select(_ i: Int) {
        if active != i { autoPipLeavingTab() }

        active = i
        if let t = current { t.lastActive = Date(); if t.sleeping { wake(t) } }
        showActive(); refreshSidebar()
        if assistantOpen { updateAIContextPills() }
    }

    // MARK: - Tab sleeping --------------------------------------------------

    func canSleepTab(_ t: Tab) -> Bool {
        if t.sleeping || t.isNewTab || t.id == current?.id { return false }
        if t.pinUrl != nil && Store.shared.settings["keepPinnedAppsAwake"] as? Bool != false { return false }
        return true
    }

    func sleepTab(_ t: Tab) {
        guard canSleepTab(t) else { return }
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
        for t in tabs where canSleepTab(t) && t.lastActive < cutoff {
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
            t.pinUrl = url
            select(i)
            reloadPinnedTabIfBlank(t, url: url)
            return
        }
        openTab(url: url)
        current?.pinUrl = url
        if let t = current { reloadPinnedTabIfBlank(t, url: url) }
        refreshSidebar()
    }

    /// Pinned tabs should never strand the user on a blank WKWebView. If WebKit
    /// dropped the provisional load or the tab was resurrected in a URL-less state,
    /// kick the saved pin URL again instead of just focusing an empty shell.
    func reloadPinnedTabIfBlank(_ t: Tab, url: String) {
        guard !t.sleeping else { return }
        let currentURL = t.webView.url?.absoluteString
        guard currentURL == nil || currentURL == "about:blank" else { return }
        if let u = URL(string: url) {
            t.isNewTab = false
            t.isChatTab = false
            t.webView.load(URLRequest(url: u))
        }
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
        suggestionsPopover.hide()
        if q.hasPrefix("breeze://"), let page = InternalPage(rawValue: String(q.dropFirst(9))) {
            t.isChatTab = false
            openInternal(page)
            if let activeTab = current {
                window.makeFirstResponder(activeTab.webView)
            }
            return
        }
        var s = q
        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL { if !q.contains("://") { s = "https://" + q } }
        else { s = searchURL(for: q) }
        guard let u = URL(string: s) else { return }
        t.isNewTab = false
        t.isChatTab = false
        showActive()
        t.webView.load(URLRequest(url: u))
        window.makeFirstResponder(t.webView)
    }

    @objc func addressSubmit() {
        let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        submitQuery(address.stringValue, isCmdEnter: isCmd)
    }

    /// Friendly address for internal pages: file://…/ui/settings.html → breeze://settings
    func displayURL(_ wv: WKWebView) -> String {
        if let t = tabs.first(where: { $0.webView === wv }), t.isChatTab {
            return "breeze://chat"
        }
        guard let u = wv.url else { return "" }
        if u.isFileURL { return "breeze://" + u.deletingPathExtension().lastPathComponent }
        return u.absoluteString
    }

    /// Address text with the path/slug dimmed to 50% opacity so the domain stands
    /// out. Applied only when the field isn't being edited (full opacity returns on
    /// focus — see controlTextDidBeginEditing). breeze:// pages have no slug → full.
    func styledAddress(_ s: String) -> NSAttributedString {
        let p = Theme.shared.palette
        let font = address.font ?? .systemFont(ofSize: 13.5)
        let attr = NSMutableAttributedString(string: s, attributes: [.foregroundColor: p.text, .font: font])
        let ns = s as NSString
        let scheme = ns.range(of: "://")
        if scheme.location != NSNotFound {
            let afterScheme = scheme.location + scheme.length
            let slash = ns.range(of: "/", options: [], range: NSRange(location: afterScheme, length: ns.length - afterScheme))
            if slash.location != NSNotFound {
                attr.addAttribute(.foregroundColor, value: p.text.withAlphaComponent(0.5),
                                  range: NSRange(location: slash.location, length: ns.length - slash.location))
            }
        }
        return attr
    }

    func submitQuery(_ text: String, isCmdEnter: Bool) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        let isURL = q.contains("://") || (q.contains(".") && !q.contains(" "))
        if isURL {
            var s = q
            if !q.contains("://") { s = "https://" + q }
            navigate(s)
            return
        }

        if isCmdEnter {
            let s = searchURL(for: q)
            navigate(s)
            return
        }

        let fromNewTab = (current?.isNewTab == true)

        // The new-tab "Ask Breeze, or type a URL" bar is a chat starter: anything
        // that isn't a URL (handled above) opens the full-window chat, which decides
        // whether to answer directly or act agentically — and can search the web
        // itself. The address bar on a page keeps normal browser behavior: a bare,
        // search-term-looking query goes straight to Google. ⌘-Enter always searches.
        if !fromNewTab, looksLikeSearchTerm(q) {
            navigate(searchURL(for: q))
            return
        }

        // Conversational / task input → AI. From the new-tab page, turn the current
        // tab into a full-window chat tab. From a web page's address bar, open the
        // side assistant so the page stays visible.
        if fromNewTab, let t = current {
            t.isNewTab = false
            t.isChatTab = true
            t.title = "Nav Chat"
            if assistantOpen { setAssistant(false) }
            prepareAIStatus()
            newChat()
            showActive()
            refreshSidebar()
            sendToAI(q)
        } else {
            // AI gate alongside the current page.
            if !assistantOpen { setAssistant(true) }
            newChat()
            sendToAI(q)
        }
    }

    /// True when the query reads like something you'd type into Google (bare
    /// keywords) rather than a question to answer or a task to perform. Routes
    /// Ask-bar input: search terms → Google directly; everything else → the AI.
    func looksLikeSearchTerm(_ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return false }
        if q.hasSuffix("?") { return false }                         // a question → let the AI answer
        // Explicit "search/google/look up X" → just search for it.
        if q.hasPrefix("search ") || q.hasPrefix("google ") || q.hasPrefix("look up ") { return true }
        let words = q.split(separator: " ")
        // Conversational / question / command openers → AI.
        let aiOpeners: Set<String> = [
            "what","what's","whats","who","who's","whos","whose","whom","when","where",
            "why","how","how's","hows","is","are","am","was","were","do","does","did",
            "can","could","should","would","will","may","might","which","tell","explain",
            "define","summarize","summarise","write","translate","calculate","convert",
            "help","give","make","create","compare","suggest","recommend","please",
            "hey","hi","hello","yo","sup","thanks","thank","sorry","bye","ok","okay",
            "yeah","yes","no","nah","sure","haha","lol","wow","nice","cool"]
        if let first = words.first, aiOpeners.contains(String(first)) { return false }
        // Task / browser-action phrasing → AI (it needs to click, type, or navigate).
        let taskPhrases = ["go to","take me to","open ","click","log in","sign in","add to cart",
                           "fill ","book ","order ","buy ","play ","post ","comment","reply ",
                           "navigate","download","sign up"]
        for p in taskPhrases where q.contains(p) { return false }
        // A short keyword phrase with none of the above reads like a search term.
        // Longer, sentence-like input is ambiguous → fall back to the AI.
        return words.count <= 6
    }

    func syncChrome() {
        // Chat tabs have no address bar or nav buttons — skip chrome sync to
        // avoid accessing views that may be detached during the tab transition.
        if current?.isChatTab == true { return }
        applyChromeTheme()
        guard let wv = current?.webView else { return }
        back.isEnabled = wv.canGoBack; forward.isEnabled = wv.canGoForward
        let urlStr = (current?.isNewTab ?? false) ? "" : displayURL(wv)
        if window.firstResponder !== address.currentEditor() { address.attributedStringValue = styledAddress(urlStr) }
        let bookmarked = (current?.isNewTab ?? true) ? false : Store.shared.isBookmarked(wv.url?.absoluteString ?? "")
        bookmarkBtn.symbol = bookmarked ? "bookmark.fill" : "bookmark"
        updateAdblockModeButton()
        // keep split panes' address bars and nav buttons current
        if let t = current, let partnerId = t.splitPartnerId, let s = tabs.first(where: { $0.id == partnerId }) {
            let isCurrentOnRight = t.splitIsRight
            let leftTab = isCurrentOnRight ? s : t
            let rightTab = isCurrentOnRight ? t : s
            leftPane.setURL(leftTab.isNewTab ? "" : (leftTab.webView.url?.absoluteString ?? ""))
            rightPane.setURL(rightTab.isNewTab ? "" : (rightTab.webView.url?.absoluteString ?? ""))
            leftPane.back.isEnabled = leftTab.webView.canGoBack
            leftPane.forward.isEnabled = leftTab.webView.canGoForward
            rightPane.back.isEnabled = rightTab.webView.canGoBack
            rightPane.forward.isEnabled = rightTab.webView.canGoForward
        }
    }

    /// After the web area is resized by a *discrete* chrome change (sidebar /
    /// assistant toggle, split drag, window snap, tab switch) WebKit doesn't
    /// always re-anchor position:fixed / sticky elements to the new edge — so a
    /// page can render with a few elements pinned to the old width. Telling the
    /// page its viewport changed forces those elements to re-layout. Fired after
    /// the chrome animation settles.
    func scheduleReflow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in self?.reflowWebViews() }
    }
    func reflowWebViews() {
        let js = "window.dispatchEvent(new Event('resize'));"
        for t in tabs where !t.isNewTab && !isInternal(t.webView) {
            t.webView.evaluateJavaScript(js, completionHandler: nil)
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
        if let current = current, current.splitPartnerId != nil {
            leftPane.setLeftSpacingForTrafficLights(hidden)
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            sidebarLeft.constant = hidden ? -sidebarWidth : 0
            sidebar.alphaValue = hidden ? 0 : 1
            root.layoutSubtreeIfNeeded()
        }
        scheduleReflow()
    }

    @objc func resizeSidebar(_ g: NSPanGestureRecognizer) {
        let dx = g.translation(in: root).x
        g.setTranslation(.zero, in: root)
        sidebarWidth = max(200, min(460, sidebarWidth + dx))
        sidebarWidthC.constant = sidebarWidth
        renderPins()                                  // pin cell size depends on width
        if g.state == .ended {
            Store.shared.settings["sidebarWidth"] = Double(sidebarWidth); Store.shared.saveSettings()
            scheduleReflow()
        }
    }

    @objc func openAssistant() { toggleAssistant() }
    func toggleAssistant() {
        if current?.isChatTab == true { return }
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

    func setAssistant(_ open: Bool) {
        assistantOpen = open
        // If assistant is currently embedded in a chat tab, don't animate the sidebar panel
        if current?.isChatTab == true && !open { return }
        
        if open { assistant.isHidden = false }
        assistant.setFullscreen(false, clearLights: false)
        breezeCorner.isHidden = open
        let w: CGFloat = ASSISTANT_W
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22; ctx.allowsImplicitAnimation = true
            assistantWidthC.constant = w
            assistantLeadingC.constant = open ? -w : 0
            webTrailC.constant = open ? -(w + 6) : -6
            topTrailC.constant = open ? -(w + 12) : -54
            self.root.layoutSubtreeIfNeeded()
        }, completionHandler: {
            if !open { self.assistant.isHidden = true }
        })
        if open {
            assistant.setMode(history: false)   // always a normal chat; history is a button overlay
            updateAIContextPills()
            assistant.focusInput()
            prepareAIStatus()
        }
        scheduleReflow()
    }

    /// Set the chat input's enabled state + status based on whether Breeze Cloud is configured.
    func prepareAIStatus() {
        if llm.ready {
            assistant.setInputEnabled(true)
            assistant.setModelStatus("Nav · GPT-5.4-mini. Ask anything, summarize pages, or make images.")
        } else {
            assistant.setInputEnabled(true, placeholder: "Nav is not configured in this build…")
            assistant.setModelStatus("Nav is not configured in this build.")
        }
    }

    func newChat() {
        assistant.startNewChat()
        aiExtras.removeAll { $0.imageText != nil }   // drop attachments; keep nothing stale
        updateAIContextPills()
        llm.resetChat()
    }

    /// Open or switch to the dedicated chat tab.
    func toggleAssistantFullscreen() {
        // If there's already a chat tab, switch to it
        if let i = tabs.firstIndex(where: { $0.isChatTab }) {
            select(i)
            return
        }
        // Create a new chat tab
        let t = Tab(); t.isNewTab = false; t.isChatTab = true; t.title = "Nav Chat"
        wire(t)
        tabs.append(t); active = tabs.count - 1
        // Close the sidebar assistant panel
        if assistantOpen { setAssistant(false) }
        prepareAIStatus()
        updateAIContextPills()
        showActive(); refreshSidebar()
    }

    /// ⇧⌘T — jump straight to a fresh, blank full-window chat ready for a typed
    /// request. Unlike the new-tab Ask bar (which routes between search/navigate/
    /// AI), this always starts an independent full-window chat conversation. Any
    /// previous chat is preserved in History → Breeze AI chats.
    func newFullscreenChat() {
        if let i = tabs.firstIndex(where: { $0.isChatTab }) {
            active = i
        } else {
            let t = Tab(); t.isNewTab = false; t.isChatTab = true; t.title = "Nav Chat"
            wire(t)
            tabs.append(t); active = tabs.count - 1
        }
        if assistantOpen { setAssistant(false) }
        prepareAIStatus()
        newChat()                       // fresh, blank conversation
        updateAIContextPills()
        showActive(); refreshSidebar()  // chat-tab showActive() focuses the input
    }

    func sendToAI(_ text: String) {
        if assistant.wantsImageMode {
            sendToAIImage(text)
            return
        }

        // Cloud not configured → warn instead of firing a doomed request.
        if !llm.ready {
            assistant.addUser(text)
            assistant.addAI("Nav is not configured in this build yet. Use the BreezeTest build with the Worker URL embedded.", chips: [])
            prepareAIStatus()
            return
        }
        ailog("sendToAI (gpt-5.4-mini): \(text)")
        assistant.addUser(text)
        assistant.setInputEnabled(false, placeholder: "Thinking…")
        assistant.setStatus("Thinking…")
        showRainbowGlow()

        Task { [weak self] in
            guard let self else { return }
            let contexts = await self.gatherContexts()
            let labels = contexts.map { $0.label }
            let history = Store.shared.settings["aiUseChatHistory"] as? Bool != false ? self.assistant.messages : []
            let done: (Result<(String, [String]), Error>) -> Void = { [weak self] r in
                guard let self else { return }
                self.ailog("model returned")
                self.hideRainbowGlow()
                self.assistant.setStatus(nil); self.assistant.setInputEnabled(true); self.assistant.focusInput()
                switch r {
                case .success(let (answer, toolChips)):
                    let chips = labels + toolChips
                    let textAns = answer.isEmpty ? "…" : answer
                    let openedSummary = self.openResearchSummaryIfNeeded(query: text, answer: textAns, chips: toolChips)
                    if openedSummary {
                        self.assistant.addAI("I opened your research summary. It has the main takeaways and sources from what I found.", chips: chips)
                    } else {
                        self.assistant.addAI(textAns, chips: chips)
                    }
                    self.broadcastToInternalPages()   // refresh the usage/cost readout on any open Settings page
                    self.saveAgentSnapshotAndWalkthrough(query: text, answer: textAns)
                case .failure(let e):
                    self.assistant.addAI("Sorry — \(e.localizedDescription)", chips: [])
                }
            }
            self.llm.send(text, history: history, contexts: contexts, completion: done)
        }
    }

    @discardableResult
    func openResearchSummaryIfNeeded(query: String, answer: String, chips: [String]) -> Bool {
        let q = query.lowercased()
        let researchy = chips.contains { $0.lowercased().contains("web search") || $0.lowercased().contains("http") } ||
            q.contains("research") || q.contains("find ") || q.contains("list ") || q.contains("best ") ||
            q.contains("recommend") || q.contains("compare") || q.contains("options")
        let transactional = q.contains("fill ") || q.contains("type ") || q.contains("click ") ||
            q.contains("email ") || q.contains("log in") || q.contains("sign in") || q.contains("submit")
        guard researchy && !transactional && answer.count > 180 else { return false }
        guard let url = writeResearchSummaryPage(query: query, answer: answer) else { return false }
        let tab: Tab
        if let cur = current, !cur.isChatTab {
            tab = cur
        } else {
            tab = Tab()
            wire(tab)
            tabs.append(tab)
            active = tabs.count - 1
        }
        tab.isNewTab = false
        tab.isChatTab = false
        tab.title = "Research Summary"
        showActive()
        tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        refreshSidebar()
        return true
    }

    func writeResearchSummaryPage(query: String, answer: String) -> URL? {
        let dir = Store.shared.supportDirectory.appendingPathComponent("Research Summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("research-\(Int(Date().timeIntervalSince1970)).html")
        let html = researchSummaryHTML(query: query, answer: answer, links: extractLinks(from: answer))
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Breeze research summary write failed: \(error.localizedDescription)")
            return nil
        }
    }

    func extractLinks(from markdown: String) -> [(String, String)] {
        let pattern = #"(?:(?:\[(.*?)\]\((https?://[^\s)]+)\))|(https?://[^\s)]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = markdown as NSString
        var out: [(String, String)] = []
        for m in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let title = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            let rawURL = m.range(at: 2).location == NSNotFound ? ns.substring(with: m.range(at: 3)) : ns.substring(with: m.range(at: 2))
            let cleanURL = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
            let label = title.isEmpty ? (URL(string: cleanURL)?.host ?? cleanURL) : title
            if !out.contains(where: { $0.1 == cleanURL }) { out.append((label, cleanURL)) }
            if out.count >= 12 { break }
        }
        return out
    }

    func markdownToResearchHTML(_ text: String) -> String {
        var html = text.htmlEscaped
        if let regex = try? NSRegularExpression(pattern: #"\*\*(.*?)\*\*"#) {
            html = regex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "<strong>$1</strong>")
        }
        if let regex = try? NSRegularExpression(pattern: #"\[(.*?)\]\((https?://[^\s)]+)\)"#) {
            html = regex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "<a href=\"$2\">$1</a>")
        }
        if let regex = try? NSRegularExpression(pattern: #"(?<!["=])(https?://[^\s<]+)"#) {
            html = regex.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: (html as NSString).length), withTemplate: "<a href=\"$1\">$1</a>")
        }
        let lines = html.components(separatedBy: .newlines)
        var out: [String] = []
        var inList = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inList { out.append("</ul>"); inList = false }
                out.append("<h2>\(String(line.dropFirst(3)))</h2>")
            } else if line.hasPrefix("# ") {
                if inList { out.append("</ul>"); inList = false }
                out.append("<h1>\(String(line.dropFirst(2)))</h1>")
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                if !inList { out.append("<ul>"); inList = true }
                out.append("<li>\(String(line.dropFirst(2)))</li>")
            } else if line.isEmpty {
                if inList { out.append("</ul>"); inList = false }
            } else {
                if inList { out.append("</ul>"); inList = false }
                out.append("<p>\(line)</p>")
            }
        }
        if inList { out.append("</ul>") }
        return out.joined(separator: "\n")
    }

    func researchSummaryHTML(query: String, answer: String, links: [(String, String)]) -> String {
        let body = markdownToResearchHTML(answer)
        let linkCards = links.map { label, url in
            "<a class=\"source\" href=\"\(url.htmlEscaped)\"><span>\(label.htmlEscaped)</span><small>\((URL(string: url)?.host ?? url).htmlEscaped)</small></a>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Research Summary — Breeze</title>
        <style>
        :root{color-scheme:light dark;--bg:#f2f0ed;--card:rgba(255,255,255,.72);--text:#23232a;--soft:rgba(35,35,42,.58);--accent:#3aa6b9;--line:rgba(0,0,0,.08);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
        @media(prefers-color-scheme:dark){:root{--bg:#16161a;--card:rgba(255,255,255,.055);--text:#ececf0;--soft:rgba(236,236,240,.55);--line:rgba(255,255,255,.11)}}
        *{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 18% 6%,color-mix(in srgb,var(--accent) 28%,transparent),transparent 28%),linear-gradient(160deg,var(--bg),color-mix(in srgb,var(--accent) 7%,var(--bg)));color:var(--text);padding:56px 24px 84px}.wrap{max-width:860px;margin:0 auto}
        header{text-align:center;margin-bottom:34px;animation:rise .45s cubic-bezier(.22,1,.36,1)}.mark{width:62px;height:62px;border-radius:18px;margin:0 auto 16px;display:grid;place-items:center;background:linear-gradient(135deg,var(--accent),#7c5bfa);box-shadow:0 22px 55px color-mix(in srgb,var(--accent) 35%,transparent)}.mark svg{width:34px;height:34px;stroke:white;fill:none;stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round}
        .pill{display:inline-block;color:var(--accent);background:color-mix(in srgb,var(--accent) 13%,transparent);font-size:12px;font-weight:750;padding:6px 12px;border-radius:999px;margin-bottom:12px}h1{font-size:44px;line-height:1.02;margin:0;font-weight:800;letter-spacing:-.8px}header p{color:var(--soft);font-size:16px;line-height:1.5;margin:14px auto 0;max-width:720px}
        .panel{background:var(--card);border:1px solid var(--line);border-radius:24px;padding:30px;box-shadow:0 24px 70px rgba(0,0,0,.14);backdrop-filter:blur(18px);animation:rise .55s cubic-bezier(.22,1,.36,1)}
        .summary h1{font-size:30px}.summary h2{font-size:20px;margin:28px 0 10px}.summary p,.summary li{font-size:15.5px;line-height:1.62;color:var(--text)}.summary ul{padding-left:20px}.summary a{color:var(--accent);font-weight:700}
        .sources{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:10px;margin-top:26px}.source{display:flex;flex-direction:column;gap:3px;padding:13px 14px;border-radius:16px;background:color-mix(in srgb,var(--accent) 9%,transparent);text-decoration:none;border:1px solid color-mix(in srgb,var(--accent) 18%,transparent)}.source span{color:var(--text);font-weight:750}.source small{color:var(--soft);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        @keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
        </style></head><body><div class="wrap"><header><div class="mark"><svg viewBox="0 0 24 24"><path d="M4 19.5V5a2 2 0 0 1 2-2h9l5 5v11.5a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 19.5Z"/><path d="M14 3v6h6"/><path d="M8 14h8M8 17h6"/></svg></div><div class="pill">Nav Research Summary</div><h1>Research, wrapped.</h1><p>\(query.htmlEscaped)</p></header><main class="panel summary">\(body)\(links.isEmpty ? "" : "<h2>Sources</h2><div class=\"sources\">\(linkCards)</div>")</main></div></body></html>
        """
    }

    func sendToAIImage(_ text: String) {
        if !llm.ready {
            assistant.addUser(text)
            assistant.addAI("Nav is not configured in this build yet. Use the BreezeTest build with the Worker URL embedded.", chips: [])
            prepareAIStatus()
            return
        }
        ailog("sendToAIImage (gpt-image-2 low): \(text)")
        assistant.addUser(text)
        let bubble = assistant.addImageLoading()
        assistant.setInputEnabled(false, placeholder: "Making image…")
        assistant.setStatus("Making image…")
        showRainbowGlow()

        Task { [weak self] in
            guard let self else { return }
            let contexts = await self.gatherContexts()
            let attachments = self.aiExtras.compactMap { extra -> AIImageAttachment? in
                guard let data = extra.imageData else { return nil }
                return AIImageAttachment(data: data, filename: extra.imageFilename ?? "breeze-image.png")
            }
            self.llm.generateImage(prompt: text, contexts: contexts, attachments: attachments) { [weak self] result in
                guard let self else { return }
                self.hideRainbowGlow()
                self.assistant.setStatus(nil)
                self.assistant.setInputEnabled(true)
                self.assistant.focusInput()
                switch result {
                case .success(let image):
                    let url = self.saveGeneratedImage(image, prompt: text)
                    self.assistant.finishImage(bubble, image: image, prompt: text, path: url?.path)
                case .failure(let error):
                    self.assistant.failImage(bubble, message: error.localizedDescription)
                }
            }
        }
    }

    func saveGeneratedImage(_ image: NSImage, prompt: String) -> URL? {
        let dir = Store.shared.supportDirectory.appendingPathComponent("ai-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).png")
        guard let data = pngData(from: image) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            Store.shared.addAIImage(prompt: prompt, path: url.path)
            return url
        } catch {
            return nil
        }
    }

    func downloadAIImage(path: String) {
        let source = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "Nav Image \(stamp.string(from: Date()))"
        var dest = dir.appendingPathComponent("\(base).png")
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) \(i).png")
            i += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch {
            NSSound.beep()
        }
    }

    func saveAgentSnapshotAndWalkthrough(query: String, answer: String) {
        guard let current = current, !current.isNewTab, !current.isPrivate else { return }
        let config = WKSnapshotConfiguration()
        current.webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let _ = self, let img = image else { return }
            
            // Was a hardcoded Antigravity dev path that doesn't exist on user machines
            // (3.1.0 leak); write to the app's own Application Support folder instead.
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let baseDir = appSupport.appendingPathComponent("Breeze/agent").path
            try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
            let imgURL = URL(fileURLWithPath: baseDir).appendingPathComponent("agent_snapshot.png")
            
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: imgURL)
            }
            
            let walkthroughURL = URL(fileURLWithPath: baseDir).appendingPathComponent("walkthrough.md")
            var content = ""
            if let existingData = try? Data(contentsOf: walkthroughURL),
               let existingStr = String(data: existingData, encoding: .utf8) {
                content = existingStr
            }
            
            let summarySection = """
            ## Last Agent Action Summary
            * **User Query:** "\(query)"
            * **AI Answer / Outcome:**
              \(answer.replacingOccurrences(of: "\n", with: "\n  "))
            
            ![Agent Stop State](file://\(imgURL.path))
            
            ---
            
            """
            
            let lines = content.components(separatedBy: "\n")
            var newLines: [String] = []
            var inserted = false
            
            for line in lines {
                newLines.append(line)
                if !inserted && line.hasPrefix("# ") {
                    newLines.append("")
                    newLines.append(summarySection)
                    inserted = true
                }
            }
            
            let finalContent: String
            if !inserted {
                finalContent = summarySection + content
            } else {
                finalContent = newLines.joined(separator: "\n")
            }
            
            try? finalContent.data(using: .utf8)?.write(to: walkthroughURL)
        }
    }

    // MARK: - Rainbow glow border --------------------------------------------

    private func createGlowPath(bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let outer = CGPath(roundedRect: bounds.insetBy(dx: 12, dy: 12), cornerWidth: 32, cornerHeight: 32, transform: nil)
        let inner = CGPath(roundedRect: bounds.insetBy(dx: 36, dy: 36), cornerWidth: 20, cornerHeight: 20, transform: nil)
        path.addPath(outer)
        path.addPath(inner)
        return path
    }

    func showRainbowGlow() {
        guard glowPanel == nil else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
        let screenFrame = screen.frame

        let panel = NSPanel(contentRect: screenFrame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()

        let contentView = NSView(frame: NSRect(origin: .zero, size: screenFrame.size))
        contentView.wantsLayer = true
        panel.contentView = contentView

        guard let rootLayer = contentView.layer else { return }

        let container = CALayer()
        container.frame = rootLayer.bounds
        container.name = "rainbowGlowContainer"

        let maskedLayer = CALayer()
        maskedLayer.frame = container.bounds
        maskedLayer.name = "rainbowGlowMasked"

        // Mask: only show a 24pt border around the edge
        let mask = CAShapeLayer()
        mask.path = createGlowPath(bounds: container.bounds)
        mask.fillRule = .evenOdd
        maskedLayer.mask = mask

        // Add a Gaussian blur filter to the container to soften the masked border (Siri style bloom)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "glowBlur"
            blur.setValue(20.0, forKey: "inputRadius")
            container.filters = [blur]
        }

        // Conic gradient layer (square, larger than window, centered)
        let size = max(container.bounds.width, container.bounds.height) * 1.5
        let gl = CAGradientLayer()
        gl.type = .conic
        gl.startPoint = CGPoint(x: 0.5, y: 0.5)
        gl.endPoint = CGPoint(x: 0.5, y: 0)
        gl.colors = [
            NSColor(red: 1.0, green: 0.2, blue: 0.3, alpha: 0.9).cgColor,   // red
            NSColor(red: 1.0, green: 0.6, blue: 0.1, alpha: 0.9).cgColor,   // orange
            NSColor(red: 1.0, green: 0.9, blue: 0.2, alpha: 0.9).cgColor,   // yellow
            NSColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 0.9).cgColor,   // green
            NSColor(red: 0.2, green: 0.7, blue: 1.0, alpha: 0.9).cgColor,   // blue
            NSColor(red: 0.6, green: 0.3, blue: 1.0, alpha: 0.9).cgColor,   // purple
            NSColor(red: 1.0, green: 0.2, blue: 0.6, alpha: 0.9).cgColor,   // pink
            NSColor(red: 1.0, green: 0.2, blue: 0.3, alpha: 0.9).cgColor,   // back to red
        ]
        gl.frame = CGRect(x: (container.bounds.width - size)/2, y: (container.bounds.height - size)/2, width: size, height: size)
        gl.name = "rainbowGlow"

        maskedLayer.addSublayer(gl)
        container.addSublayer(maskedLayer)
        rootLayer.addSublayer(container)

        glowPanel = panel
        rainbowContainer = container
        rainbowLayer = gl
        rainbowMask = mask

        // Spin the gradient continuously
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 2.5
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gl.add(spin, forKey: "rainbowSpin")

        // Subtle pulse
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.7
        pulse.toValue = 1.0
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        container.add(pulse, forKey: "rainbowPulse")
    }

    func hideRainbowGlow() {
        guard let panel = glowPanel, let container = rainbowContainer else { return }
        // Fade out then remove panel
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            panel.close()
            self?.glowPanel = nil
            self?.rainbowContainer = nil
            self?.rainbowLayer = nil
            self?.rainbowMask = nil
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = container.presentation()?.opacity ?? 1.0
        fade.toValue = 0
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        container.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    func updateRainbowFrame() {
        guard let panel = glowPanel, let container = rainbowContainer, let gl = rainbowLayer else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
        let screenFrame = screen.frame
        if panel.frame != screenFrame {
            panel.setFrame(screenFrame, display: true)
        }
        container.frame = CGRect(origin: .zero, size: screenFrame.size)
        if let maskedLayer = container.sublayers?.first(where: { $0.name == "rainbowGlowMasked" }) {
            maskedLayer.frame = container.bounds
        }
        if let mask = rainbowMask {
            mask.path = createGlowPath(bounds: container.bounds)
        }
        let size = max(container.bounds.width, container.bounds.height) * 1.5
        gl.frame = CGRect(x: (container.bounds.width - size)/2, y: (container.bounds.height - size)/2, width: size, height: size)
    }


    func ctxLabel(_ t: Tab) -> String {
        let s = t.title.isEmpty ? hostOf(t.webView.url) : t.title
        return String(s.prefix(34))
    }

    @MainActor func gatherContexts() async -> [AIContext] {
        var out: [AIContext] = []
        if let t = current, !t.isNewTab, !t.isChatTab {
            out.append(AIContext(label: ctxLabel(t), text: await readPageText(of: t), isCurrent: true))
        }
        for e in aiExtras {
            if let t = e.tab, tabs.contains(where: { $0.id == t.id }), t.id != current?.id {
                out.append(AIContext(label: e.label, text: await readPageText(of: t)))
            } else if let txt = e.imageText {
                out.append(AIContext(label: e.label, text: txt))
            }
        }
        // Broader context is opt-in. Current page and explicit @-mentions are always
        // available; history/bookmarks/other tabs only go out when enabled in Settings.
        let recentHistory = Store.shared.history.prefix(15)
        if Store.shared.bool("aiIncludeHistory"), !recentHistory.isEmpty {
            let lines = recentHistory.compactMap { h -> String? in
                guard let url = h["url"] as? String, let title = h["title"] as? String else { return nil }
                return "• \(title) (\(url))"
            }
            out.append(AIContext(label: "Recent history", text: "Recent browsing history:\n" + lines.joined(separator: "\n")))
        }
        let bookmarks = Store.shared.bookmarks.prefix(20)
        if Store.shared.bool("aiIncludeBookmarks"), !bookmarks.isEmpty {
            let lines = bookmarks.compactMap { b -> String? in
                guard let url = b["url"] as? String, let title = b["title"] as? String else { return nil }
                return "• \(title) (\(url))"
            }
            out.append(AIContext(label: "Bookmarks", text: "User's bookmarks:\n" + lines.joined(separator: "\n")))
        }
        let openTabs = tabs.filter { !$0.isNewTab && !$0.isChatTab && $0.id != current?.id }
        if Store.shared.bool("aiIncludeOpenTabs"), !openTabs.isEmpty {
            let lines = openTabs.map { "• \($0.title) (\(hostOf($0.webView.url)))" }
            out.append(AIContext(label: "Open tabs", text: "Other open tabs:\n" + lines.joined(separator: "\n")))
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
                    let imageData = self.pngData(fromFile: url)
                    DispatchQueue.main.async {
                        self.aiExtras.append(AIExtra(label: String(name.prefix(28)),
                                                     tab: nil,
                                                     imageText: "Attached image \"\(name)\":\n\(desc)",
                                                     imageData: imageData,
                                                     imageFilename: self.pngFilename(for: name)))
                        self.assistant.setStatus(nil)
                        self.updateAIContextPills()
                    }
                }
            }
        }
    }

    func pngFilename(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "breeze-image" : base) + ".png"
    }

    func pngData(fromFile url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return pngData(from: image)
    }

    func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - AI tool callbacks (BrowserAITools) ----------------------------

    /// Lightweight page read for the passive per-message AI context: just the
    /// title, URL, and a short innerText snippet. Unlike `readText`, it does NOT
    /// walk every DOM node (getBoundingClientRect/getComputedStyle on thousands of
    /// elements forces synchronous layout+style recalc — seconds on a heavy page
    /// like YouTube) and does NOT mutate the DOM. This is what made every chat
    /// message, even "hi", take ~10s with a page open. The full `readText` scrape
    /// is reserved for the agentic tools (READ / CLICK / TYPE) that actually need
    /// the interactive-element map.
    func readPageText(of t: Tab, limit: Int = 4000) async -> String {
        await withCheckedContinuation { cont in
            let js = """
            (function(){
              var title = document.title || '';
              var text = (document.body ? document.body.innerText : '') || '';
              text = text.trim().replace(/\\s+/g, ' ');
              if (text.length > \(limit)) text = text.substring(0, \(limit)) + '…';
              return JSON.stringify({ title: title, url: location.href, text: text });
            })()
            """
            t.webView.evaluateJavaScript(js) { result, _ in
                guard let s = result as? String,
                      let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    cont.resume(returning: "")
                    return
                }
                let title = o["title"] as? String ?? ""
                let url = o["url"] as? String ?? ""
                let text = o["text"] as? String ?? ""
                cont.resume(returning: "URL: \(url)\nPage Title: \(title)\n\nPage text:\n\(text)")
            }
        }
    }

    func readText(of t: Tab) async -> String {
        await withCheckedContinuation { cont in
            let js = #"""
            (function() {
                // Remove old badges
                var oldBadges = document.querySelectorAll('.breeze-agent-badge');
                oldBadges.forEach(function(b) { b.remove(); });
                
                function isVisible(el) {
                    var rect = el.getBoundingClientRect();
                    if (rect.width === 0 || rect.height === 0) return false;
                    var style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                    return true;
                }
                
                function isInteractive(el) {
                    var tag = el.tagName.toLowerCase();
                    if (tag === 'a' || tag === 'button' || tag === 'input' || tag === 'textarea' || tag === 'select') return true;
                    if (el.hasAttribute('onclick')) return true;
                    if (el.isContentEditable) return true;
                    var role = el.getAttribute('role');
                    if (role && ['button', 'link', 'checkbox', 'radio', 'textbox', 'tab', 'menuitem'].indexOf(role.toLowerCase()) !== -1) return true;
                    
                    var style = window.getComputedStyle(el);
                    if (style && style.cursor === 'pointer') {
                        var rect = el.getBoundingClientRect();
                        if (rect.width > 600 && rect.height > 600) return false;
                        return true;
                    }
                    return false;
                }
                
                function hasInteractiveAncestor(el, list) {
                    var p = el.parentElement;
                    while (p && p !== document.body) {
                        if (list.indexOf(p) !== -1) {
                            var pTag = p.tagName.toLowerCase();
                            var pRole = p.getAttribute('role');
                            if (pTag === 'button' || pTag === 'a' || pTag === 'input' || pTag === 'textarea' || pTag === 'select' ||
                                (pRole && ['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem'].indexOf(pRole.toLowerCase()) !== -1)) {
                                return true;
                            }
                        }
                        p = p.parentElement;
                    }
                    return false;
                }
                
                var selectors = 'a, button, input, textarea, select, [role], [onclick], div, span, p, li, img';
                var all = Array.from(document.querySelectorAll(selectors));
                var interactiveList = [];
                for (var i = 0; i < all.length; i++) {
                    var el = all[i];
                    if (isVisible(el) && isInteractive(el)) {
                        if (!hasInteractiveAncestor(el, interactiveList)) {
                            interactiveList.push(el);
                        }
                    }
                }
                
                var elementStrings = [];
                var id = 1;
                for (var i = 0; i < interactiveList.length; i++) {
                    var el = interactiveList[i];
                    el.setAttribute('data-breeze-id', id);
                    
                    // No visible badge is drawn: data-breeze-id (above) is enough for
                    // 100% reliable CLICK/TYPE. The numbered overlays cluttered the
                    // user's view and lingered after the agent finished (3.1.0 regression).
                    
                    function labelFor(el) {
                        var parts = [];
                        if (el.getAttribute('aria-label')) parts.push('aria="' + el.getAttribute('aria-label') + '"');
                        if (el.getAttribute('title')) parts.push('title="' + el.getAttribute('title') + '"');
                        if (el.getAttribute('data-placeholder')) parts.push('placeholder="' + el.getAttribute('data-placeholder') + '"');
                        if (el.id) {
                            var lblEl = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
                            if (lblEl && lblEl.innerText.trim()) parts.push('label="' + lblEl.innerText.trim().replace(/\s+/g, ' ') + '"');
                        }
                        return parts.join(' ');
                    }
                    var desc = "";
                    var tag = el.tagName.toLowerCase();
                    var role = (el.getAttribute('role') || '').toLowerCase();
                    if (tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable || role === 'textbox') {
                        var type = el.getAttribute('type') || 'text';
                        var placeholder = el.getAttribute('placeholder') || '';
                        var name = el.getAttribute('name') || '';
                        var value = el.value || '';
                        desc = '(Input/' + tag + (role ? ' role=' + role : '') + (el.isContentEditable ? ' contenteditable' : '') + ')';
                        if (placeholder) desc += ' placeholder="' + placeholder + '"';
                        if (name) desc += ' name="' + name + '"';
                        if (value) desc += ' value="' + value + '"';
                        var extraLabel = labelFor(el);
                        if (extraLabel) desc += ' ' + extraLabel;
                    } else {
                        var text = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
                        if (text.length > 80) text = text.substring(0, 77) + '...';
                        desc = '(' + tag + ')';
                        if (text) desc += ' "' + text + '"';
                        var href = el.getAttribute('href');
                        if (href) desc += ' href="' + href + '"';
                    }
                    elementStrings.push('[' + id + '] ' + desc);
                    id++;
                    if (id > 80) break;
                }
                
                var title = document.title || 'No Title';
                var pageText = (document.body ? document.body.innerText : '').trim().replace(/\s+/g, ' ');
                if (pageText.length > 12000) {
                    pageText = pageText.substring(0, 12000) + '...';
                }
                
                return JSON.stringify({
                    title: title,
                    url: window.location.href,
                    elements: elementStrings,
                    text: pageText
                });
            })()
            """#
            t.webView.evaluateJavaScript(js) { result, _ in
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    cont.resume(returning: "Failed to read page content.")
                    return
                }
                
                let title = obj["title"] as? String ?? "No Title"
                let url = obj["url"] as? String ?? ""
                let elements = obj["elements"] as? [String] ?? []
                let text = obj["text"] as? String ?? ""
                
                var formatted = "URL: \(url)\nPage Title: \(title)\n\n"
                formatted += "Interactive Elements (use CLICK: <ID> or TYPE: <ID> | <value>):\n"
                if elements.isEmpty {
                    formatted += "(No interactive elements found on the page)\n"
                } else {
                    for el in elements {
                        formatted += "\(el)\n"
                    }
                }
                formatted += "\nPage text content:\n\(text)"
                
                cont.resume(returning: formatted)
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
        if let cur = current {
            cur.isNewTab = false
            cur.isChatTab = false
            t = cur
        }
        else { let nt = Tab(); nt.isNewTab = false; wire(nt); tabs.append(nt); active = tabs.count - 1; t = nt }
        showActive(); refreshSidebar()
        if !assistantOpen { setAssistant(true) }   // dock the chat so the user sees the answer as the page opens
        assistant.setStatus("Opening \(hostOf(u))…")
        t.webView.load(URLRequest(url: u))
        await waitForLoad(t)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let the page settle
        let text = await readText(of: t)
        syncChrome(); refreshSidebar()
        assistant.setStatus("Thinking…")
        return "Opened \(u.absoluteString) in the browser. Title: \(t.webView.title ?? "")\n\nPage text:\n" + String(text.prefix(8000))
    }

    @MainActor func aiSearchWeb(_ query: String) async -> String {
        let t = Tab(); t.isNewTab = false
        wire(t); tabs.append(t); active = tabs.count - 1
        showActive(); refreshSidebar()
        if !assistantOpen { setAssistant(true) }   // dock the chat so the user sees results as they come in
        assistant.setStatus("Searching the web…")
        if let u = URL(string: searchURL(for: query)) { t.webView.load(URLRequest(url: u)) }
        await waitForLoad(t)
        try? await Task.sleep(nanoseconds: 700_000_000)   // let results render
        let text = await readText(of: t)
        assistant.setStatus("Thinking…")
        return "Web search results for \"\(query)\":\n\n" + text
    }

    @MainActor func aiClick(_ target: String) async -> String {
        guard let t = current, !t.isNewTab else { return "No web page open to click on." }
        let escapedTarget = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var target = '\(escapedTarget)'.trim().toLowerCase();
            
            function clickElement(el) {
                var rect = el.getBoundingClientRect();
                var opts = { bubbles: true, cancelable: true, view: window,
                             clientX: rect.left + Math.max(1, rect.width / 2),
                             clientY: rect.top + Math.max(1, rect.height / 2) };
                el.focus();
                el.dispatchEvent(new MouseEvent('mouseover', opts));
                el.dispatchEvent(new MouseEvent('mousedown', opts));
                el.dispatchEvent(new MouseEvent('mouseup', opts));
                el.dispatchEvent(new MouseEvent('click', opts));
                if (el.tagName === 'INPUT' && (el.type === 'checkbox' || el.type === 'radio')) {
                    el.checked = !el.checked;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                }
                return true;
            }

            // 1. Try numeric ID matching
            var id = target.replace(/[\\[\\]]/g, '').trim();
            if (/^\\d+$/.test(id)) {
                var el = document.querySelector('[data-breeze-id="' + id + '"]');
                if (el) {
                    clickElement(el);
                    return "Clicked element [" + id + "]";
                }
            }
            
            // 2. Try selector if it looks like one
            try {
                var el = document.querySelector(target);
                if (el) { clickElement(el); return "Clicked element matching selector '" + target + "'"; }
            } catch(e) {}
            
            // 3. Try finding by text content in clickable elements
            var candidates = Array.from(document.querySelectorAll('a, button, input, [role="button"], textarea, div, span, p'));
            for (var el of candidates) {
                var txt = (el.innerText || el.value || el.placeholder || "").trim().toLowerCase();
                if (txt === target || txt.includes(target)) {
                    clickElement(el);
                    return "Clicked element containing text '" + target + "'";
                }
            }
            return "Could not find any element matching '" + target + "' to click.";
        })()
        """
        assistant.setStatus("Clicking \(target)…")
        let clickResult: String = await withCheckedContinuation { cont in
            t.webView.evaluateJavaScript(js) { result, _ in
                let s = (result as? String) ?? "Failed to execute click."
                cont.resume(returning: s)
            }
        }
        
        try? await Task.sleep(nanoseconds: 700_000_000)
        let updatedPage = await readText(of: t)
        assistant.setStatus("Thinking…")
        return "\(clickResult)\n\nUpdated Page State:\n\(updatedPage)"
    }

    @MainActor func aiType(_ target: String, text: String) async -> String {
        guard let t = current, !t.isNewTab else { return "No web page open to type in." }
        let escapedTarget = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function() {
            var target = '\(escapedTarget)'.trim().toLowerCase();
            var val = '\(escapedText)';
            
            function fire(el, name, extra) {
                var event;
                try {
                    if (name === 'beforeinput' || name === 'input') {
                        event = new InputEvent(name, Object.assign({ bubbles: true, cancelable: true, inputType: 'insertText', data: val }, extra || {}));
                    } else {
                        event = new Event(name, { bubbles: true, cancelable: true });
                    }
                } catch (e) {
                    event = new Event(name, { bubbles: true, cancelable: true });
                }
                el.dispatchEvent(event);
            }

            function nativeSet(el, v) {
                var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype :
                            el instanceof HTMLInputElement ? HTMLInputElement.prototype : null;
                var desc = proto ? Object.getOwnPropertyDescriptor(proto, 'value') : null;
                if (desc && desc.set) desc.set.call(el, v);
                else el.value = v;
            }

            function selectAllEditable(el) {
                var range = document.createRange();
                range.selectNodeContents(el);
                var sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
            }

            function closestWritable(el) {
                while (el && el !== document.documentElement) {
                    var tag = (el.tagName || '').toLowerCase();
                    var role = (el.getAttribute && (el.getAttribute('role') || '').toLowerCase()) || '';
                    if (tag === 'textarea') return el;
                    if (tag === 'input') {
                        var type = (el.getAttribute('type') || 'text').toLowerCase();
                        if (!/^(button|checkbox|color|file|hidden|image|radio|range|reset|submit)$/i.test(type)) return el;
                    }
                    if (el.isContentEditable || role === 'textbox') return el;
                    el = el.parentElement;
                }
                return null;
            }

            function setValue(el, v) {
                el = closestWritable(el) || el;
                el.focus();
                var tag = (el.tagName || '').toLowerCase();
                var role = (el.getAttribute && (el.getAttribute('role') || '').toLowerCase()) || '';
                if (tag === 'input' || tag === 'textarea') {
                    nativeSet(el, v);
                    if (typeof el.setSelectionRange === 'function') el.setSelectionRange(v.length, v.length);
                    fire(el, 'beforeinput');
                    fire(el, 'input');
                    fire(el, 'change');
                } else if (el.isContentEditable || role === 'textbox') {
                    selectAllEditable(el);
                    fire(el, 'beforeinput');
                    var usedExec = false;
                    try { usedExec = document.execCommand('insertText', false, v); } catch (e) {}
                    if (!usedExec) {
                        el.textContent = v;
                    }
                    fire(el, 'input');
                    fire(el, 'change');
                    el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true, key: 'Unidentified' }));
                } else {
                    el.textContent = v;
                    fire(el, 'input');
                    fire(el, 'change');
                }
                return true;
            }

            // 1. Try numeric ID matching first
            var id = target.replace(/[\\[\\]]/g, '').trim();
            if (/^\\d+$/.test(id)) {
                var el = document.querySelector('[data-breeze-id="' + id + '"]');
                if (el) {
                    setValue(el, val);
                    return "Typed into element [" + id + "]";
                }
            }

            // 2. Try selector first
            try {
                var el = document.querySelector(target);
                if (el && setValue(el, val)) { return "Typed into element matching selector '" + target + "'"; }
            } catch(e) {}
            
            // 3. Try finding input/textarea/editable by placeholder, label, value, or text
            var inputs = Array.from(document.querySelectorAll('input, textarea, [contenteditable], [role="textbox"], [aria-label], [data-placeholder], div, span'));
            for (var el of inputs) {
                var pl = (el.placeholder || "").trim().toLowerCase();
                var aria = (el.getAttribute('aria-label') || "").trim().toLowerCase();
                var title = (el.getAttribute('title') || "").trim().toLowerCase();
                var dataPl = (el.getAttribute('data-placeholder') || "").trim().toLowerCase();
                var name = (el.getAttribute('name') || "").trim().toLowerCase();
                var valTxt = (el.value || "").trim().toLowerCase();
                var inner = (el.innerText || "").trim().toLowerCase();
                var label = "";
                if (el.id) {
                    var lblEl = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
                    if (lblEl) label = lblEl.innerText.trim().toLowerCase();
                }
                
                if (pl.includes(target) || aria.includes(target) || title.includes(target) || dataPl.includes(target) || name.includes(target) || valTxt.includes(target) || inner.includes(target) || label.includes(target)) {
                    if (setValue(el, val)) {
                        return "Typed into element matching '" + target + "'";
                    }
                }
            }
            return "Could not find any input field matching '" + target + "' to type in.";
        })()
        """
        assistant.setStatus("Typing…")
        let typeResult: String = await withCheckedContinuation { cont in
            t.webView.evaluateJavaScript(js) { result, _ in
                let s = (result as? String) ?? "Failed to execute type."
                cont.resume(returning: s)
            }
        }
        
        try? await Task.sleep(nanoseconds: 700_000_000)
        let updatedPage = await readText(of: t)
        assistant.setStatus("Thinking…")
        return "\(typeResult)\n\nUpdated Page State:\n\(updatedPage)"
    }

    @MainActor func aiSetReminder(_ text: String, minutes: Int) async -> String {
        let center = UNUserNotificationCenter.current()
        let secs = max(1, Double(minutes) * 60)
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                return "I couldn't set the reminder — notifications are off for Breeze."
            }

            let id = UUID().uuidString
            let fireAt = Date().timeIntervalSince1970 * 1000 + (secs * 1000)
            let content = UNMutableNotificationContent()
            content.title = "Breeze reminder"
            content.body = text
            if Store.shared.settings["notificationSounds"] as? Bool != false { content.sound = .default }
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))

            var reminders = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
            reminders.append(["id": id, "label": text, "fireAt": fireAt])
            Store.shared.settings["reminders"] = reminders
            Store.shared.saveSettings()
            broadcastToInternalPages()
            updateRemindersSidebar()
            return "Reminder set: \"\(text)\" in \(minutes) minute\(minutes == 1 ? "" : "s")."
        } catch {
            return "I couldn't set the reminder: \(error.localizedDescription)"
        }
    }

    func deleteReminderById(_ id: String) {
        var rems = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
        rems.removeAll { ($0["id"] as? String) == id }
        Store.shared.settings["reminders"] = rems
        Store.shared.saveSettings()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        broadcastToInternalPages()
        updateRemindersSidebar()
    }

    func updateRemindersSidebar() {
        let rems = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
        remindersView.update(rems)
    }

    private func initReminders() {
        let now = Date().timeIntervalSince1970 * 1000
        let rems = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
        let center = UNUserNotificationCenter.current()
        var live: [[String: Any]] = []
        for r in rems {
            if let fireAt = r["fireAt"] as? Double, fireAt > now {
                let secs = max(1.0, (fireAt - now) / 1000)
                let id = r["id"] as? String ?? UUID().uuidString
                let txt = r["label"] as? String ?? "Reminder"
                let content = UNMutableNotificationContent()
                content.title = "Breeze reminder"; content.body = txt
                if Store.shared.settings["notificationSounds"] as? Bool != false { content.sound = .default }
                let trig = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trig))
                live.append(r)
            }
        }
        if live.count != rems.count {
            Store.shared.settings["reminders"] = live
            Store.shared.saveSettings()
        }
        updateRemindersSidebar()
    }

    func clearCurrentSiteCache() {
        guard let url = current?.webView.url,
              !url.isFileURL,
              let host = url.host?.lowercased() else { return }
        let store = WKWebsiteDataStore.default()
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache
        ]
        store.fetchDataRecords(ofTypes: cacheTypes) { [weak self] records in
            let matching = records.filter { self?.record($0, matchesHost: host) == true }
            guard !matching.isEmpty else {
                DispatchQueue.main.async { self?.current?.webView.reload() }
                return
            }
            store.removeData(ofTypes: cacheTypes, for: matching) {
                DispatchQueue.main.async { self?.current?.webView.reload() }
            }
        }
    }

    private func record(_ record: WKWebsiteDataRecord, matchesHost host: String) -> Bool {
        let site = record.displayName.lowercased()
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let bareSite = site.hasPrefix("www.") ? String(site.dropFirst(4)) : site
        return bareHost == bareSite || bareHost.hasSuffix("." + bareSite) || bareSite.hasSuffix("." + bareHost)
    }

    func originString(_ origin: WKSecurityOrigin) -> String {
        let scheme = (origin.value(forKey: "protocol") as? String) ?? "https"
        let host = origin.host
        let port = origin.port
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return port > 0 && !defaultPort ? "\(scheme)://\(host):\(port)" : "\(scheme)://\(host)"
    }

    func storedPermission(origin: String, permission: String) -> Bool? {
        guard let permissions = Store.shared.settings["permissions"] as? [String: Any],
              let byPerm = permissions[origin] as? [String: Any] else { return nil }
        if let value = byPerm[permission] as? Bool { return value }
        if (permission == "camera" || permission == "microphone"),
           let legacy = byPerm["media"] as? Bool { return legacy }
        return nil
    }

    func setSitePermission(origin: String, permission: String, allowed: Bool?) {
        var permissions = Store.shared.settings["permissions"] as? [String: Any] ?? [:]
        var byPerm = permissions[origin] as? [String: Any] ?? [:]
        if let allowed {
            byPerm[permission] = allowed
        } else {
            byPerm.removeValue(forKey: permission)
        }
        if byPerm.isEmpty { permissions.removeValue(forKey: origin) }
        else { permissions[origin] = byPerm }
        Store.shared.settings["permissions"] = permissions
        Store.shared.saveSettings()
        broadcastToInternalPages()
    }

    func permissionKeys(for type: WKMediaCaptureType) -> [String] {
        switch type {
        case .camera: return ["camera"]
        case .microphone: return ["microphone"]
        case .cameraAndMicrophone: return ["camera", "microphone"]
        @unknown default: return ["camera", "microphone"]
        }
    }

    func mediaPermissionTitle(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "Camera"
        case .microphone: return "Microphone"
        case .cameraAndMicrophone: return "Camera and Microphone"
        @unknown default: return "Camera and Microphone"
        }
    }

    @available(macOS 12.0, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let originText = originString(origin)
        let keys = permissionKeys(for: type)
        let stored = keys.compactMap { storedPermission(origin: originText, permission: $0) }
        if stored.count == keys.count, stored.allSatisfy({ $0 }) {
            decisionHandler(.grant)
            return
        }
        if stored.contains(false) {
            decisionHandler(.deny)
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(originText) wants to use your \(mediaPermissionTitle(for: type).lowercased())"
        alert.informativeText = "Breeze can allow this once, remember the choice for this site, or block it. You can change saved choices in Settings → Site Permissions."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Block")
        let result = alert.runModal()
        switch result {
        case .alertFirstButtonReturn:
            decisionHandler(.grant)
        case .alertSecondButtonReturn:
            for key in keys { setSitePermission(origin: originText, permission: key, allowed: true) }
            decisionHandler(.grant)
        default:
            for key in keys { setSitePermission(origin: originText, permission: key, allowed: false) }
            decisionHandler(.deny)
        }
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView,
                 requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let originText = originString(origin)
        if let stored = storedPermission(origin: originText, permission: "geolocation") {
            decisionHandler(stored ? .grant : .deny)
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(originText) wants to use your location"
        alert.informativeText = "Breeze can allow this once, remember the choice for this site, or block it. You can change saved choices in Settings → Site Permissions."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Block")
        let result = alert.runModal()
        switch result {
        case .alertFirstButtonReturn:
            decisionHandler(.grant)
        case .alertSecondButtonReturn:
            setSitePermission(origin: originText, permission: "geolocation", allowed: true)
            decisionHandler(.grant)
        default:
            setSitePermission(origin: originText, permission: "geolocation", allowed: false)
            decisionHandler(.deny)
        }
    }

    func clearAllBrowsingData() {
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {
                DispatchQueue.main.async { self?.current?.webView.reload() }
            }
        }
    }

    func clearBrowsingData(options: [String: Any]) {
        var types = Set<String>()
        if options["cache"] as? Bool == true {
            types.insert(WKWebsiteDataTypeDiskCache)
            types.insert(WKWebsiteDataTypeMemoryCache)
            types.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
        }
        if options["cookies"] as? Bool == true {
            types.insert(WKWebsiteDataTypeCookies)
            types.insert(WKWebsiteDataTypeLocalStorage)
            types.insert(WKWebsiteDataTypeSessionStorage)
            types.insert(WKWebsiteDataTypeIndexedDBDatabases)
            types.insert(WKWebsiteDataTypeWebSQLDatabases)
        }
        if options["history"] as? Bool == true {
            Store.shared.history = []
            Store.shared.saveHistory()
        }
        guard !types.isEmpty else {
            DispatchQueue.main.async { self.current?.webView.reload() }
            return
        }
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: types) { [weak self] records in
            store.removeData(ofTypes: types, for: records) {
                DispatchQueue.main.async { self?.current?.webView.reload() }
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
        if body["pip"] as? String == "leave",
           let i = tabs.firstIndex(where: { $0.id == t.id }),
           current?.id != t.id {
            select(i)
        }
        updateNowPlaying()
    }

    func updateNowPlaying() {
        // The card stays pinned to the tracked tab even when its media is PAUSED —
        // it only changes when another tab starts playing (handleMedia switches it),
        // when the user taps the dismiss X (dismissNowPlaying), or when the tab is
        // gone. So a pause in a background tab no longer makes the card vanish.
        guard let t = nowPlayingTab, tabs.contains(where: { $0.id == t.id }) else {
            nowPlaying.isHidden = true; nowPlayingTab = nil; return
        }
        nowPlaying.isHidden = false
        nowPlaying.configure(host: hostOf(t.webView.url),
                             title: t.mediaTitle.isEmpty ? t.title : t.mediaTitle,
                             playing: t.isPlaying)
    }

    /// Dismiss the now-playing card (the X). Pauses the media so we don't leave
    /// audio playing with nothing on screen, then clears the card.
    func dismissNowPlaying() {
        if let t = nowPlayingTab {
            t.webView.evaluateJavaScript("(function(){var m=document.querySelector('video,audio');if(m&&!m.paused)m.pause();})()")
            t.isPlaying = false
        }
        nowPlayingTab = nil
        updateNowPlaying()
    }

    func toggleNowPlaying() {
        guard let t = nowPlayingTab else { return }
        t.webView.evaluateJavaScript("(function(){var m=document.querySelector('video,audio');if(!m)return;m.paused?m.play():m.pause();})()")
    }
    func nowPlayingPip() {
        pip(for: nowPlayingTab?.webView, toggle: true)
    }

    /// Toggle/enter Picture-in-Picture for a tab's main <video>. Uses
    /// callAsyncJavaScript (which AWAITS the promise, unlike evaluateJavaScript) so
    /// rejections don't get silently swallowed. PiP itself is enabled on the web
    /// view config via `enablePictureInPictureAPI()`; without that the request
    /// rejects with NotSupportedError on macOS.
    func pip(for webView: WKWebView?, toggle: Bool) {
        guard let webView else { return }
        let onAlready = toggle ? "await document.exitPictureInPicture(); return 'exited';"
                               : "return 'already-pip';"
        let body = """
        const v = document.querySelector('video');
        if (!v) return 'no-video';
        if (document.pictureInPictureElement) { \(onAlready) }
        if (v.disablePictureInPicture || !document.pictureInPictureEnabled) return 'unsupported';
        try { await v.requestPictureInPicture(); return 'ok'; }
        catch (e) { return 'error: ' + (e && e.name ? e.name : String(e)); }
        """
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { _ in }
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

    func webView(_ w: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        print("Breeze decidePolicyFor: \(url.absoluteString) (scheme: \(scheme))")
        let whitelist = ["http", "https", "file", "about", "blob", "data"]
        if !scheme.isEmpty && !whitelist.contains(scheme) {
            print("Breeze: Opening custom scheme natively: \(url.absoluteString)")
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let source = tabs.first(where: { $0.webView === w }) {
            openTab(url: url, from: source, autoGroupSameSite: true)
            decisionHandler(.cancel)
            return
        }
        // `<a download>`, blob:/data: download links, and right-click "Download
        // Linked File" set shouldPerformDownload. WebKit won't save the file
        // unless we answer .download here — otherwise it just navigates and the
        // download silently never happens (the "can't download anything" bug).
        if #available(macOS 11.3, *), navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    // route undisplayable responses to a download
    func webView(_ w: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        activeDownloads[ObjectIdentifier(download)] = download
        download.delegate = self
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        activeDownloads[ObjectIdentifier(download)] = download
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
        activeDownloads[ObjectIdentifier(download)] = nil
        broadcastDownloads()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let it = item(for: download) { it.state = .failed }
        activeDownloads[ObjectIdentifier(download)] = nil
        print("Breeze download failed: \(error.localizedDescription) [\(download.originalRequest?.url?.absoluteString ?? "unknown URL")] ")
        NSSound.beep()
        broadcastDownloads()
    }

    func showLinkMenu(url: URL) {
        contextLinkURL = url
        showPageMenu(link: url, image: nil, pageURL: current?.webView.url, pageTitle: current?.title ?? "", selection: "", editable: false)
    }

    func showPageMenu(link: URL?, image: URL?, pageURL: URL?, pageTitle: String, selection: String, editable: Bool) {
        contextLinkURL = link
        contextImageURL = image
        contextPageURL = pageURL
        contextPageTitle = pageTitle
        contextSelectedText = selection
        contextEditable = editable

        let menu = NSMenu()
        menu.autoenablesItems = false

        if link != nil {
            menu.addTargetedItem("Open Link", #selector(openContextLink), self)
            menu.addTargetedItem("Open Link in New Tab", #selector(openContextLinkInNewTab), self)
            menu.addTargetedItem("Open Link in New Window", #selector(openContextLinkInNewWindow), self)
            menu.addItem(.separator())
            menu.addTargetedItem("Download Linked File", #selector(downloadContextLink), self)
            menu.addTargetedItem("Copy Link", #selector(copyContextLink), self)
            menu.addItem(.separator())
        }

        if image != nil {
            menu.addTargetedItem("Open Image in New Tab", #selector(openContextImageInNewTab), self)
            menu.addTargetedItem("Download Image", #selector(downloadContextImage), self)
            menu.addTargetedItem("Copy Image Address", #selector(copyContextImageAddress), self)
            menu.addItem(.separator())
        }

        if !selection.isEmpty {
            menu.addTargetedItem("Copy", #selector(copyContextSelection), self)
            let short = selection.count > 32 ? String(selection.prefix(32)) + "..." : selection
            menu.addTargetedItem("Search for \"\(short)\"", #selector(searchContextSelection), self)
            menu.addTargetedItem("Ask Nav About Selection", #selector(askNavAboutContextSelection), self)
            menu.addItem(.separator())
        } else if editable {
            menu.addTargetedItem("Cut", #selector(cutContextEditable), self)
            menu.addTargetedItem("Copy", #selector(copyContextEditable), self)
            menu.addTargetedItem("Paste", #selector(pasteContextEditable), self)
            menu.addTargetedItem("Select All", #selector(selectAllContextEditable), self)
            menu.addItem(.separator())
        }

        let back = menu.addTargetedItem("Back", #selector(contextBack), self)
        back.isEnabled = current?.webView.canGoBack ?? false
        let forward = menu.addTargetedItem("Forward", #selector(contextForward), self)
        forward.isEnabled = current?.webView.canGoForward ?? false
        menu.addTargetedItem("Reload", #selector(contextReload), self)
        menu.addItem(.separator())
        menu.addTargetedItem("Bookmark This Page", #selector(bookmarkContextPage), self)
        menu.addTargetedItem("Copy Page URL", #selector(copyContextPageURL), self)
        menu.addTargetedItem("Share Page...", #selector(shareContextPage), self)
        menu.addTargetedItem("Find in Page...", #selector(contextFindInPage), self)
        menu.addTargetedItem("Print Page...", #selector(printContextPage), self)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func openContextLink() {
        guard let url = contextLinkURL else { return }
        navigate(url.absoluteString)
    }

    @objc func openContextLinkInNewTab() {
        guard let url = contextLinkURL else { return }
        openTab(url: url, from: current, autoGroupSameSite: true)
    }

    @objc func openContextLinkInNewWindow() {
        guard let url = contextLinkURL else { return }
        let browser = BrowserController(isPrivateWindow: current?.isPrivate ?? false, initialContent: .empty)
        (NSApp.delegate as? AppDelegate)?.browsers.append(browser)
        browser.openTab(url: url.absoluteString)
    }

    @objc func downloadContextLink() {
        guard let url = contextLinkURL, let webView = current?.webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            self.activeDownloads[ObjectIdentifier(download)] = download
            download.delegate = self
        }
    }

    @objc func copyContextLink() {
        guard let value = contextLinkURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func openContextImageInNewTab() {
        guard let url = contextImageURL else { return }
        openTab(url: url, from: current, autoGroupSameSite: false)
    }

    @objc func downloadContextImage() {
        guard let url = contextImageURL, let webView = current?.webView else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let self else { return }
            self.activeDownloads[ObjectIdentifier(download)] = download
            download.delegate = self
        }
    }

    @objc func copyContextImageAddress() {
        guard let value = contextImageURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc func copyContextSelection() {
        guard !contextSelectedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contextSelectedText, forType: .string)
    }

    @objc func searchContextSelection() {
        guard !contextSelectedText.isEmpty else { return }
        openTab(url: searchURL(for: contextSelectedText))
    }

    @objc func askNavAboutContextSelection() {
        guard !contextSelectedText.isEmpty else { return }
        setAssistant(true)
        sendToAI("Explain this selection:\n\n\(contextSelectedText)")
    }

    @objc func cutContextEditable() { current?.webView.evaluateJavaScript("document.execCommand('cut')") }
    @objc func copyContextEditable() { current?.webView.evaluateJavaScript("document.execCommand('copy')") }
    @objc func selectAllContextEditable() { current?.webView.evaluateJavaScript("document.execCommand('selectAll')") }
    @objc func pasteContextEditable() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard let data = try? JSONSerialization.data(withJSONObject: text),
              let json = String(data: data, encoding: .utf8) else { return }
        current?.webView.evaluateJavaScript("""
        (function(text){
          var el = document.activeElement;
          if (!el) return;
          if (el.isContentEditable) { document.execCommand('insertText', false, text); return; }
          var tag = (el.tagName || '').toLowerCase();
          if (tag === 'textarea' || tag === 'input') {
            var start = el.selectionStart || 0, end = el.selectionEnd || start;
            var value = el.value || '';
            el.value = value.slice(0, start) + text + value.slice(end);
            var pos = start + text.length;
            el.setSelectionRange(pos, pos);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
          }
        })(\(json));
        """)
    }

    @objc func contextBack() { current?.webView.goBack() }
    @objc func contextForward() { current?.webView.goForward() }
    @objc func contextReload() { reloadCurrentTab() }
    @objc func contextFindInPage() { openFindBar() }
    @objc func bookmarkContextPage() {
        guard let url = contextPageURL ?? current?.webView.url else { return }
        let title = contextPageTitle.isEmpty ? (current?.title ?? url.absoluteString) : contextPageTitle
        Store.shared.toggleBookmark(url: url.absoluteString, title: title)
        syncChrome()
    }
    @objc func copyContextPageURL() {
        guard let value = (contextPageURL ?? current?.webView.url)?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    @objc func shareContextPage() {
        guard let url = contextPageURL ?? current?.webView.url else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: webContainer.bounds, of: webContainer, preferredEdge: .maxY)
    }
    @objc func printContextPage() {
        guard let webView = current?.webView else { return }
        webView.printOperation(with: NSPrintInfo.shared).run()
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

    /// The accent the HTML pages should use. Default is teal; custom settings
    /// override it.
    func effectiveAccentHex() -> String {
        let accent = Store.shared.string("accent").lowercased()
        if accent == Theme.monoAccent { return effectiveTheme() == "dark" ? "#f5f5f7" : "#1c1c20" }
        return accent.isEmpty ? Theme.defaultAccent : accent
    }
    func isCustomAccentSetting() -> Bool {
        let a = Store.shared.string("accent").lowercased()
        return !a.isEmpty && a != Theme.defaultAccent && a != Theme.monoAccent
    }
    func onAccentTextHex() -> String {
        guard let color = Theme.hex(effectiveAccentHex()) else { return "#ffffff" }
        let c = color.usingColorSpace(.deviceRGB) ?? color
        guard c.numberOfComponents >= 3 else { return "#ffffff" }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? "#16161a" : "#ffffff"
    }

    private func bridgeStateJS() -> String {
        let theme = effectiveTheme()
        var settings = Store.shared.settings
        settings["rawAccent"] = Store.shared.string("accent")
        settings["accent"] = effectiveAccentHex()      // HTML follows the chrome accent
        settings["aiCloudEnabled"] = llm.usingCloud
        settings["aiKeyConnected"] = llm.ready
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
        (function(){
          var accent=getComputedStyle(document.documentElement).getPropertyValue('--accent').trim()||'\(effectiveAccentHex())';
          function rgb(hex){hex=hex.replace('#','');if(hex.length!==6)return null;var n=parseInt(hex,16);return [(n>>16)&255,(n>>8)&255,n&255];}
          var c=rgb(accent); if(!c)return;
          document.querySelectorAll('img[src$="icon.png"],img[data-breeze-logo-src]').forEach(function(img){
            var original=img.getAttribute('data-breeze-logo-src')||img.getAttribute('src');
            img.setAttribute('data-breeze-logo-src',original);
            var source=new Image();
            source.onload=function(){
              try{
                var canvas=document.createElement('canvas'); canvas.width=source.naturalWidth||source.width; canvas.height=source.naturalHeight||source.height;
                var ctx=canvas.getContext('2d'); ctx.drawImage(source,0,0,canvas.width,canvas.height);
                var d=ctx.getImageData(0,0,canvas.width,canvas.height), p=d.data;
                for(var i=0;i<p.length;i+=4){var lum=(0.299*p[i]+0.587*p[i+1]+0.114*p[i+2])/255;p[i]=c[0]*lum;p[i+1]=c[1]*lum;p[i+2]=c[2]*lum;}
                ctx.putImageData(d,0,0); img.src=canvas.toDataURL('image/png');
              }catch(e){}
            };
            source.src=original;
          });
        })();
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
        if message.name == "breezeLinkMenu",
           let body = message.body as? [String: Any] {
            let link = (body["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let image = (body["image"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let page = (body["pageURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
            let title = body["pageTitle"] as? String ?? ""
            let selection = body["selection"] as? String ?? ""
            let editable = body["editable"] as? Bool ?? false
            showPageMenu(link: link, image: image, pageURL: page, pageTitle: title, selection: selection, editable: editable)
            return
        }
        if message.name == "breezeMedia" {
            handleMedia(message); return
        }
        if message.name == "breezeFullscreen" {
            setWebFullscreen((message.body as? NSNumber)?.boolValue ?? false); return
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
        case "setSitePermission":
            if let origin = args["origin"] as? String,
               let permission = args["permission"] as? String {
                let value = args["value"]
                let allowed = value is NSNull || value == nil ? nil : (value as? Bool)
                setSitePermission(origin: origin, permission: permission, allowed: allowed)
            }
        case "openExternal":
            if let s = args["url"] as? String, let url = URL(string: s),
               url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
            }
        case "resetAIUsage":
            Store.shared.resetAIUsage()
            broadcastToInternalPages()
        case "getHistory":
            resolve(Store.json(Store.shared.history))
        case "getAIImages":
            let items = Store.shared.images.map { item -> [String: Any] in
                var copy = item
                if let path = item["path"] as? String {
                    copy["url"] = URL(fileURLWithPath: path).absoluteString
                }
                return copy
            }
            resolve(Store.json(items))
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
        case "getReminders":
            let rems = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
            resolve(Store.json(rems))
        case "deleteReminder":
            if let id = args["id"] as? String {
                deleteReminderById(id)
            }
        case "vaultList":
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
        case "downloadAIImage":
            if let path = args["path"] as? String { downloadAIImage(path: path) }
        case "askAI":
            if let text = args["text"] as? String {
                toggleAssistantFullscreen()
                newChat()
                sendToAI(text)
            }
        case "aiReady":
            // Reflects the cached flag, not secret storage, so this never prompts.
            resolve(llm.ready ? "true" : "false")
        case "clearBrowsingData":
            clearBrowsingData(options: args); resolve("{}")
        case "resetBrowser":
            Store.shared.settings = Store.defaults; Store.shared.pins = []
            Store.shared.history = []; Store.shared.bookmarks = []
            Store.shared.saveSettings(); Store.shared.savePins(); Store.shared.saveHistory(); Store.shared.saveBookmarks()
            pins = []; renderPins(); applySettingsChange(); resolve("{}")
        case "makeDefaultBrowser":
            if let bid = Bundle.main.bundleIdentifier {
                LSSetDefaultHandlerForURLScheme("http" as CFString, bid as CFString)
                LSSetDefaultHandlerForURLScheme("https" as CFString, bid as CFString)
            }
        case "openSystemPasswords":
            if let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
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
        applyChromeTheme()
        if Store.shared.settings["adblockEnabled"] as? Bool ?? true {
            AdBlocker.shared.rebuild()
        } else {
            AdBlocker.shared.remove(from: sharedConfig.userContentController)
        }
        updateAdblockModeButton()
        broadcastToInternalPages()
        newTab.applyTheme(); newTab.tick()
    }

    func shareCurrentPage(from view: NSView?) {
        guard let url = current?.webView.url, let view = view else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    func searchURL(for query: String) -> String {
        let e = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch Store.shared.string("searchEngine") {
        case "duckduckgo": return "https://duckduckgo.com/?q=\(e)"
        case "bing":       return "https://www.bing.com/search?q=\(e)"
        default:           return "https://www.google.com/search?q=\(e)"
        }
    }

    func googleSearchURL(for query: String) -> String {
        let e = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return "https://www.google.com/search?q=\(e)"
    }

    func currentHost() -> String? {
        guard let host = current?.webView.url?.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func updateAdblockModeButton() {
        let extreme = Store.shared.string("adblockMode") == "extreme" && (Store.shared.settings["adblockEnabled"] as? Bool ?? true)
        let host = currentHost()
        let exceptions = Store.shared.settings["adblockSiteExceptions"] as? [String] ?? []
        let disabledHere = host.map { h in exceptions.contains { h == $0 || h.hasSuffix("." + $0) } } ?? false
        adblockModeBtn.isHidden = !extreme || host == nil || disabledHere
        adblockModeBtn.isOn = extreme && !disabledHere
    }

    func allowCurrentSiteInExtremeAdblock() {
        guard let host = currentHost() else { return }
        var exceptions = Store.shared.settings["adblockSiteExceptions"] as? [String] ?? []
        if !exceptions.contains(host) { exceptions.append(host) }
        Store.shared.settings["adblockSiteExceptions"] = exceptions
        Store.shared.saveSettings()
        AdBlocker.shared.rebuild { [weak self] in
            DispatchQueue.main.async {
                self?.updateAdblockModeButton()
                self?.current?.webView.reload()
            }
        }
    }

    // MARK: - Theme ---------------------------------------------------------

    func findBarBackgroundColor() -> NSColor {
        let p = Theme.shared.palette
        return p.isDark ? p.surface.withAlphaComponent(0.96) : NSColor.white.withAlphaComponent(0.98)
    }

    func updateFindBarAppearance() {
        let p = Theme.shared.palette
        findBar.layer?.backgroundColor = findBarBackgroundColor().cgColor
        findBar.layer?.borderColor = p.textSoft.withAlphaComponent(p.isDark ? 0.28 : 0.22).cgColor
        findBar.layer?.shadowOpacity = p.isDark ? 0.34 : 0.18
        findField.textColor = p.text
        findField.backgroundColor = .clear
        findStatus.textColor = p.textSoft
    }

    func applyChromeTheme() {
        let p = Theme.shared.palette
        addressWrap.layer?.backgroundColor = p.surface.cgColor
        address.textColor = p.text
        updateFindBarAppearance()
        adblockPill.layer?.backgroundColor = p.surface.cgColor
        adblockCount.textColor = p.textSoft
        breezeCorner.image = navLogo()
        window.backgroundColor = p.bg
        root.needsDisplay = true
    }

    // MARK: - WK delegates --------------------------------------------------

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        syncChrome()
        if isInternal(w) { injectBridgeState(into: w) }
        else if let u = w.url?.absoluteString {
            let isPrivateTab = tabs.first(where: { $0.webView === w })?.isPrivate ?? false
            if !isPrivateTab {
                Store.shared.addHistory(url: u, title: (w.title?.isEmpty == false ? w.title! : u))
            }
        }
        // wake any AI agentic-search waiter for this tab
        if let tab = tabs.first(where: { $0.webView === w }), let c = aiNavWaiters.removeValue(forKey: tab.id) {
            c.resume()
        }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError error: Error) {
        print("Breeze Navigation didFailProvisionalNavigation: \(error.localizedDescription) (URL: \(w.url?.absoluteString ?? "none"))")
        showLoadFailureIfNeeded(for: w, error: error)
        syncChrome()
        if let tab = tabs.first(where: { $0.webView === w }), let c = aiNavWaiters.removeValue(forKey: tab.id) {
            c.resume()
        }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError error: Error) {
        print("Breeze Navigation didFail: \(error.localizedDescription) (URL: \(w.url?.absoluteString ?? "none"))")
        showLoadFailureIfNeeded(for: w, error: error)
        syncChrome()
        if let tab = tabs.first(where: { $0.webView === w }), let c = aiNavWaiters.removeValue(forKey: tab.id) {
            c.resume()
        }
    }
    func showLoadFailureIfNeeded(for w: WKWebView, error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && [NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication].contains(ns.code) { return }
        // WebKit reports policy/redirect interruptions as navigation failures even when
        // a reload or follow-up main-frame load can proceed normally.
        if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }
        guard let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? w.url else { return }
        let escapedURL = failing.absoluteString.htmlEscaped
        let escapedMessage = error.localizedDescription.htmlEscaped
        let retryURL = failing.absoluteString.jsEscaped
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Page failed to load</title>
        <style>
        :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","Segoe UI",sans-serif;background:#eef8f8;color:#10252a}
        body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 25% 12%,rgba(94,211,223,.32),transparent 34%),linear-gradient(145deg,#eef8f8,#dcebed)}
        main{width:min(560px,calc(100vw - 44px));padding:34px;border-radius:24px;background:rgba(255,255,255,.72);box-shadow:0 24px 70px rgba(15,45,52,.18);backdrop-filter:blur(22px);border:1px solid rgba(255,255,255,.68)}
        h1{font-size:32px;line-height:1.05;margin:0 0 12px;font-weight:800;letter-spacing:0}p{font-size:15px;line-height:1.45;margin:0 0 18px;color:rgba(16,37,42,.72)}
        .url{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;padding:12px 14px;border-radius:14px;background:rgba(16,37,42,.07);overflow-wrap:anywhere;color:rgba(16,37,42,.82)}
        .actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:22px}.btn{appearance:none;border:0;border-radius:999px;padding:10px 16px;font-weight:700;background:#2d9aac;color:white;text-decoration:none;cursor:pointer}.secondary{background:rgba(16,37,42,.10);color:#10252a}
        ul{margin:18px 0 0;padding-left:19px;color:rgba(16,37,42,.72);font-size:14px;line-height:1.55}
        @media (prefers-color-scheme:dark){:root{background:#14252b;color:#f7fbfb}body{background:radial-gradient(circle at 25% 12%,rgba(94,211,223,.20),transparent 34%),linear-gradient(145deg,#14252b,#0f1c21)}main{background:rgba(20,30,35,.78);border-color:rgba(255,255,255,.10);box-shadow:0 24px 70px rgba(0,0,0,.34)}p,.url,ul{color:rgba(247,251,251,.72)}.url{background:rgba(255,255,255,.08)}.secondary{background:rgba(255,255,255,.12);color:#f7fbfb}}
        </style></head><body><main><h1>This page couldn't load.</h1><p>\(escapedMessage)</p><div class="url">\(escapedURL)</div><div class="actions"><button class="btn" onclick="location.href='\(retryURL)'">Try again</button><button class="btn secondary" onclick="history.back()">Go back</button></div><ul><li>Check the address for typos.</li><li>Try again after a moment if the site is busy.</li><li>If this is a login or app page, try again after site compatibility updates finish.</li></ul></main></body></html>
        """
        w.loadHTMLString(html, baseURL: failing.deletingLastPathComponent())
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        w.magnification = tabs.first(where: { $0.webView === w })?.pageZoom ?? 1.0
        syncChrome()
        if isInternal(w) { injectBridgeState(into: w) }
    }
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let t = tabs.first(where: { $0.webView === w }), blockedPopups.contains(t.id) { return nil }
        
        cfg.websiteDataStore = w.configuration.websiteDataStore
        let isPrivateTab = tabs.first(where: { $0.webView === w })?.isPrivate ?? false
        
        let t = Tab(configuration: cfg, isPrivate: isPrivateTab)
        t.isNewTab = false
        wire(t)
        
        tabs.append(t)
        active = tabs.count - 1
        showActive()
        refreshSidebar()
        NotificationCenter.default.post(name: BrowserController.didUpdateState, object: nil)
        
        return t.webView
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = parameters.allowsDirectories
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        
        if let window = NSApp.keyWindow {
            openPanel.beginSheetModal(for: window) { response in
                if response == .OK {
                    completionHandler(openPanel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        } else {
            openPanel.begin { response in
                if response == .OK {
                    completionHandler(openPanel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        }
    }
    func webViewDidClose(_ webView: WKWebView) {
        if let t = tabs.first(where: { $0.webView === webView }) {
            closeTab(t)
        }
    }
}

extension BrowserController: AddressSuggestionsDelegate {
    func didSelectSuggestion(_ url: String) {
        navigate(url)
    }
    
    func textChanged(to text: String) {
        if let f = window.firstResponder as? NSTextView, let tf = f.delegate as? NSTextField {
            tf.stringValue = text
        }
    }
    
    // MARK: - NSTextFieldDelegate

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === address else { return }
        // Edit at full opacity — drop the dimmed-slug styling while typing.
        field.textColor = Theme.shared.palette.text
        field.stringValue = field.stringValue
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, (field === address || field === newTab.field) else { return }
        if field === newTab.field { newTab.updateFieldHeight() }
        if suggestionsPopover.isInternalUpdate { return }
        
        let q = field.stringValue.lowercased()
        if q.isEmpty {
            suggestionsPopover.hide()
            return
        }
        
        var items: [SuggestionItem] = []
        
        let bms = Store.shared.bookmarks.filter { 
            let t = ($0["title"] as? String ?? "").lowercased()
            let u = ($0["url"] as? String ?? "").lowercased()
            return t.contains(q) || u.contains(q)
        }.prefix(3)
        for b in bms { items.append(SuggestionItem(title: b["title"] as? String ?? "", url: b["url"] as? String ?? "", type: .bookmark)) }
        
        let hist = Store.shared.history.filter {
            let t = ($0["title"] as? String ?? "").lowercased()
            let u = ($0["url"] as? String ?? "").lowercased()
            return t.contains(q) || u.contains(q)
        }.prefix(7)
        
        var seen = Set(items.map { $0.url })
        for h in hist {
            let u = h["url"] as? String ?? ""
            if !seen.contains(u) {
                items.append(SuggestionItem(title: h["title"] as? String ?? "", url: u, type: .history))
                seen.insert(u)
            }
        }
        
        if items.isEmpty {
            suggestionsPopover.hide()
        } else {
            let edge: NSRectEdge = field === newTab.field ? .maxY : .minY
            suggestionsPopover.show(relativeTo: field, items: items, preferredEdge: edge)
        }
    }
    
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if control === findField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                findNextMatch()
                return true
            } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                closeFindBar()
                return true
            }
        }
        if control === address || control === newTab.field {
            let shiftSearch = (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) &&
                commandSelector == #selector(NSResponder.insertNewline(_:))
            if suggestionsPopover.isShown {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    suggestionsPopover.moveSelectionUp()
                    return true
                } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    suggestionsPopover.moveSelectionDown()
                    return true
                } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    if shiftSearch {
                        submitField(control, textView: textView, forceGoogleSearch: true)
                        return true
                    }
                    if suggestionsPopover.triggerSelected() {
                        return true
                    }
                    submitField(control, textView: textView)
                    return true
                } else if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                    suggestionsPopover.hide()
                    return true
                }
            } else if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                submitField(control, textView: textView, forceGoogleSearch: shiftSearch)
                return true
            }
        }
        return false
    }

    private func submitField(_ control: NSControl, textView: NSTextView, forceGoogleSearch: Bool = false) {
        guard let field = control as? NSTextField else { return }
        let text = textView.string
        let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        suggestionsPopover.hide()
        if field === newTab.field {
            field.stringValue = ""
            newTab.updateFieldHeight()
        }
        if forceGoogleSearch {
            navigate(googleSearchURL(for: text))
            return
        }
        submitQuery(text, isCmdEnter: isCmd)
    }
}
