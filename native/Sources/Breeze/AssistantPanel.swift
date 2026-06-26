// Right-side AI chat panel (clone of the Electron #assistant). Pure AppKit.

import Cocoa

final class AssistantPanel: NSView, NSTextFieldDelegate {
    private let messagesStack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSView()
    private let status = NSTextField(labelWithString: "")
    let input = NSTextField()
    private let sendBtn = HoverButton(symbol: "arrow.up.circle.fill", size: 30, point: 20)
    private let attachBtn = HoverButton(symbol: "paperclip", size: 28, point: 15)
    private let creatorBtn = HoverButton(symbol: "play.rectangle.fill", size: 28, point: 14)
    /// Floating "new chat" button shown only in fullscreen (the header is hidden there).
    private let fsNewChatBtn = HoverButton(symbol: "square.and.pencil", size: 32, point: 15)
    var onAttach: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onCreatorTools: (() -> Void)?
    /// Fires with the text typed after "/" so the controller can show the Task palette.
    var onSlashTasks: ((String) -> Void)?
    /// Fires when the "/" context ends, so the controller can hide the palette.
    var onSlashTasksEnd: (() -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onAtMention: (() -> Void)?
    var onRemoveContext: ((Int) -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onDownloadImagePath: ((String) -> Void)?
    private let contextScroll = NSScrollView()
    private let contextRow = NSStackView()

    private var headerView: NSStackView!
    private var scrollTopToHeaderC: NSLayoutConstraint!
    private var scrollTopToPanelC: NSLayoutConstraint!
    private var historyTopToHeaderC: NSLayoutConstraint!
    private var historyTopToPanelC: NSLayoutConstraint!
    private var headerLeadingC: NSLayoutConstraint!
    private var messageMaxWidth: CGFloat = 250
    private var messagesWidthC: NSLayoutConstraint!
    private var inputWidthC: NSLayoutConstraint!
    private var statusWidthC: NSLayoutConstraint!
    private var contextWidthC: NSLayoutConstraint!
    private var historyWidthC: NSLayoutConstraint!
    private let headerLogo = NSImageView()
    private let emptyLogo = NSImageView()
    private struct MessageBubbleRecord {
        weak var bubble: MessageBubbleView?
        weak var widthConstraint: NSLayoutConstraint?
        weak var heightConstraint: NSLayoutConstraint?
    }
    private var messageBubbles: [MessageBubbleRecord] = []
    // chat state
    private var chatId = Date().timeIntervalSince1970
    var messages: [[String: String]] = []   // {role: user|ai|image, text, path?}
    private let historyView = NSView()
    private let historyList = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // header
        headerLogo.image = navLogo()
        headerLogo.imageScaling = .scaleProportionallyDown
        headerLogo.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Nav")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        // Chat history lives on the History page now (breeze://history → Chats),
        // not as an in-panel overlay.
        let fs = HoverButton(symbol: "arrow.up.left.and.arrow.down.right", size: 28, point: 13)
        fs.onTap = { [weak self] in self?.onToggleFullscreen?() }
        creatorBtn.toolTip = "Creator Tools"
        creatorBtn.isHidden = true
        creatorBtn.onTap = { [weak self] in self?.onCreatorTools?() }
        let newChat = HoverButton(symbol: "square.and.pencil", size: 28, point: 14)
        newChat.onTap = { [weak self] in self?.onNewChat?() }
        let close = HoverButton(symbol: "xmark", size: 28, point: 13)
        close.onTap = { [weak self] in self?.onClose?() }
        let hspacer = NSView(); hspacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerLogo, title, hspacer, creatorBtn, fs, newChat, close])
        header.spacing = 8; header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false
        self.headerView = header

        // messages
        messagesStack.orientation = .vertical; messagesStack.spacing = 12; messagesStack.alignment = .leading
        messagesStack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(messagesStack)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        buildEmptyState()

        // history overlay (list of saved chats)
        historyView.wantsLayer = true
        historyView.translatesAutoresizingMaskIntoConstraints = false
        historyView.isHidden = true
        let hHeader = NSTextField(labelWithString: "Chat history")
        hHeader.font = .systemFont(ofSize: 12, weight: .semibold); hHeader.textColor = Theme.shared.palette.textSoft
        hHeader.translatesAutoresizingMaskIntoConstraints = false
        historyList.orientation = .vertical; historyList.spacing = 4; historyList.alignment = .leading
        historyList.translatesAutoresizingMaskIntoConstraints = false
        let hDoc = FlippedView(); hDoc.translatesAutoresizingMaskIntoConstraints = false
        hDoc.addSubview(historyList)
        let hScroll = NSScrollView(); hScroll.drawsBackground = false; hScroll.hasVerticalScroller = true
        hScroll.translatesAutoresizingMaskIntoConstraints = false; hScroll.documentView = hDoc
        historyView.addSubview(hHeader); historyView.addSubview(hScroll)
        NSLayoutConstraint.activate([
            hHeader.topAnchor.constraint(equalTo: historyView.topAnchor, constant: 8),
            hHeader.leadingAnchor.constraint(equalTo: historyView.leadingAnchor, constant: 14),
            hScroll.topAnchor.constraint(equalTo: hHeader.bottomAnchor, constant: 8),
            hScroll.leadingAnchor.constraint(equalTo: historyView.leadingAnchor, constant: 8),
            hScroll.trailingAnchor.constraint(equalTo: historyView.trailingAnchor, constant: -8),
            hScroll.bottomAnchor.constraint(equalTo: historyView.bottomAnchor, constant: -8),
            hDoc.widthAnchor.constraint(equalTo: hScroll.contentView.widthAnchor),
            historyList.topAnchor.constraint(equalTo: hDoc.topAnchor),
            historyList.leadingAnchor.constraint(equalTo: hDoc.leadingAnchor, constant: 6),
            historyList.trailingAnchor.constraint(equalTo: hDoc.trailingAnchor, constant: -6),
            historyList.bottomAnchor.constraint(equalTo: hDoc.bottomAnchor),
        ])

        // input row
        let inputWrap = NSView(); inputWrap.wantsLayer = true; inputWrap.layer?.cornerRadius = 26
        inputWrap.translatesAutoresizingMaskIntoConstraints = false
        input.placeholderString = "Ask anything…"
        input.font = .systemFont(ofSize: 13.5)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.translatesAutoresizingMaskIntoConstraints = false
        input.target = self; input.action = #selector(send)
        input.delegate = self
        contextRow.orientation = .horizontal; contextRow.spacing = 6; contextRow.alignment = .centerY
        contextRow.translatesAutoresizingMaskIntoConstraints = false
        contextScroll.drawsBackground = false
        contextScroll.hasHorizontalScroller = true
        contextScroll.hasVerticalScroller = false
        contextScroll.autohidesScrollers = true
        contextScroll.scrollerStyle = .overlay
        contextScroll.translatesAutoresizingMaskIntoConstraints = false
        let contextDoc = FlippedView()
        contextDoc.translatesAutoresizingMaskIntoConstraints = false
        contextDoc.addSubview(contextRow)
        contextScroll.documentView = contextDoc
        contextScroll.isHidden = true
        sendBtn.onTap = { [weak self] in self?.send() }
        attachBtn.onTap = { [weak self] in self?.onAttach?() }
        inputWrap.addSubview(attachBtn); inputWrap.addSubview(input); inputWrap.addSubview(sendBtn)

        status.font = .systemFont(ofSize: 11.5)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.isHidden = true

        addSubview(header); addSubview(scroll); addSubview(empty); addSubview(historyView); addSubview(status); addSubview(contextScroll); addSubview(inputWrap)

        // Fullscreen-only new-chat button, floating top-right (header is hidden there).
        fsNewChatBtn.toolTip = "New chat"
        fsNewChatBtn.isHidden = true
        fsNewChatBtn.onTap = { [weak self] in self?.onNewChat?() }
        addSubview(fsNewChatBtn)
        NSLayoutConstraint.activate([
            fsNewChatBtn.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            fsNewChatBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
        self.inputWrap = inputWrap

        messagesWidthC = messagesStack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -16)
        inputWidthC = inputWrap.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
        statusWidthC = status.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        contextWidthC = contextScroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -28)
        historyWidthC = historyView.widthAnchor.constraint(equalTo: widthAnchor)

        messagesWidthC.isActive = true
        inputWidthC.isActive = true
        statusWidthC.isActive = true
        contextWidthC.isActive = true
        historyWidthC.isActive = true

        scrollTopToHeaderC = scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10)
        scrollTopToPanelC = scroll.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        historyTopToHeaderC = historyView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6)
        historyTopToPanelC = historyView.topAnchor.constraint(equalTo: topAnchor, constant: 12)

        NSLayoutConstraint.activate([
            contextScroll.centerXAnchor.constraint(equalTo: centerXAnchor),
            contextScroll.bottomAnchor.constraint(equalTo: inputWrap.topAnchor, constant: -6),
            contextScroll.heightAnchor.constraint(equalToConstant: 26),
            contextDoc.heightAnchor.constraint(equalTo: contextScroll.contentView.heightAnchor),
            contextRow.topAnchor.constraint(equalTo: contextDoc.topAnchor),
            contextRow.leadingAnchor.constraint(equalTo: contextDoc.leadingAnchor),
            contextRow.trailingAnchor.constraint(equalTo: contextDoc.trailingAnchor),
            contextRow.bottomAnchor.constraint(equalTo: contextDoc.bottomAnchor),
            historyView.centerXAnchor.constraint(equalTo: centerXAnchor),
            historyView.bottomAnchor.constraint(equalTo: inputWrap.topAnchor, constant: -6),
            historyTopToHeaderC,
        ])
        headerLeadingC = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerLeadingC,
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headerLogo.widthAnchor.constraint(equalToConstant: 20), headerLogo.heightAnchor.constraint(equalToConstant: 20),

            scrollTopToHeaderC,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: contextScroll.topAnchor, constant: -4),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            messagesStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            messagesStack.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            messagesStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),

            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.bottomAnchor.constraint(equalTo: contextRow.topAnchor, constant: -4),

            inputWrap.centerXAnchor.constraint(equalTo: centerXAnchor),
            inputWrap.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            inputWrap.heightAnchor.constraint(equalToConstant: 52),
            attachBtn.leadingAnchor.constraint(equalTo: inputWrap.leadingAnchor, constant: 6),
            attachBtn.centerYAnchor.constraint(equalTo: inputWrap.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: attachBtn.trailingAnchor, constant: 6),
            input.centerYAnchor.constraint(equalTo: inputWrap.centerYAnchor),
            input.trailingAnchor.constraint(equalTo: sendBtn.leadingAnchor, constant: -6),
            sendBtn.trailingAnchor.constraint(equalTo: inputWrap.trailingAnchor, constant: -8),
            sendBtn.centerYAnchor.constraint(equalTo: inputWrap.centerYAnchor),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    private var inputWrap: NSView!

    private func buildEmptyState() {
        empty.translatesAutoresizingMaskIntoConstraints = false
        emptyLogo.image = navLogo()
        emptyLogo.imageScaling = .scaleProportionallyDown
        emptyLogo.translatesAutoresizingMaskIntoConstraints = false
        let h = NSTextField(labelWithString: "Nav")
        h.font = .systemFont(ofSize: 16, weight: .semibold); h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        let p = NSTextField(labelWithString: "Powered by Breeze Cloud.\nReads pages, searches the web, and acts for you.")
        p.font = .systemFont(ofSize: 12.5); p.alignment = .center; p.maximumNumberOfLines = 3
        p.textColor = Theme.shared.palette.textSoft
        p.translatesAutoresizingMaskIntoConstraints = false
        p.cell?.wraps = true
        p.cell?.lineBreakMode = .byWordWrapping

        let tip = buildTipTile()

        let s = NSStackView(views: [emptyLogo, h, p, tip]); s.orientation = .vertical; s.spacing = 12; s.alignment = .centerX
        s.translatesAutoresizingMaskIntoConstraints = false
        s.setCustomSpacing(18, after: p)
        empty.addSubview(s); s.pin(to: empty)

        NSLayoutConstraint.activate([
            emptyLogo.widthAnchor.constraint(equalToConstant: 44),
            emptyLogo.heightAnchor.constraint(equalToConstant: 44),
            h.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16),
            p.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16),
            tip.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            tip.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -24)
        ])
        self.emptyTitle = h; self.emptySub = p
        refreshTipVisibility()
    }
    private var emptyTitle: NSTextField!
    private var emptySub: NSTextField!

    // MARK: - Rotating Nav tips (replaces the old quick-prompt chips)

    private let navTips: [String] = [
        "Type / to run a Task — like /research or /summarize — right here, in a new tab, or the address bar.",
        "Press ⌘E anytime to open or close Nav.",
        "Type @ to pull another open tab into the conversation.",
        "Highlight text on any page, then ask Nav about just that selection.",
        "Tell Nav “remind me in 20 minutes to…” and it’ll fire a notification when it’s time."
    ]
    private var tipIndex = 0
    private var tipTimer: Timer?
    private var tipCard: NSView!
    private var tipLabel: NSTextField!
    private var tipDismiss: HoverButton!

    private func buildTipTile() -> NSView {
        let card = NSView(); card.wantsLayer = true; card.layer?.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false

        let bulb = NSImageView()
        bulb.image = tintedSymbol("lightbulb.fill", point: 13, weight: .semibold, color: Theme.shared.palette.accent)
        bulb.translatesAutoresizingMaskIntoConstraints = false

        tipIndex = Int.random(in: 0..<navTips.count)
        let label = NSTextField(wrappingLabelWithString: navTips[tipIndex])
        label.font = .systemFont(ofSize: 12.5); label.alignment = .left
        label.textColor = Theme.shared.palette.text
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isSelectable = false
        tipLabel = label

        let x = HoverButton(symbol: "xmark", size: 20, point: 9)
        x.toolTip = "Hide tips"
        x.onTap = { [weak self] in self?.dismissTips() }
        tipDismiss = x

        card.addSubview(bulb); card.addSubview(label); card.addSubview(x)
        NSLayoutConstraint.activate([
            bulb.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            bulb.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            bulb.widthAnchor.constraint(equalToConstant: 15), bulb.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: bulb.trailingAnchor, constant: 9),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
            label.trailingAnchor.constraint(equalTo: x.leadingAnchor, constant: -6),
            x.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            x.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
        ])
        // Tap the card (not the X) to cycle to the next tip.
        let g = NSClickGestureRecognizer(target: self, action: #selector(cycleTip))
        card.addGestureRecognizer(g)
        tipCard = card
        styleTipCard()
        return card
    }

    private func styleTipCard() {
        guard let tipCard else { return }
        let p = Theme.shared.palette
        tipCard.layer?.backgroundColor = p.accent.withAlphaComponent(p.isDark ? 0.13 : 0.10).cgColor
        tipCard.layer?.borderWidth = 1
        tipCard.layer?.borderColor = p.accent.withAlphaComponent(0.22).cgColor
        tipLabel?.textColor = p.text
    }

    @objc private func cycleTip() {
        guard !navTips.isEmpty else { return }
        tipIndex = (tipIndex + 1) % navTips.count
        tipLabel?.stringValue = navTips[tipIndex]
    }

    /// Show/hide the whole tip tile based on the saved preference, and start a gentle
    /// rotation only while the empty state is visible (timer is torn down the moment a
    /// message arrives — no idle/perpetual work).
    private func refreshTipVisibility() {
        let hidden = Store.shared.bool("hideNavTips")
        tipCard?.isHidden = hidden
        if hidden || empty.isHidden { stopTipRotation() } else { startTipRotation() }
    }
    private func startTipRotation() {
        guard tipTimer == nil, !(tipCard?.isHidden ?? true) else { return }
        tipTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.cycleTip()
        }
    }
    func stopTipRotation() { tipTimer?.invalidate(); tipTimer = nil }
    /// Restart tip rotation when Nav is shown again on an empty chat.
    func resumeTipsIfEmpty() { if !empty.isHidden { refreshTipVisibility() } }
    private func dismissTips() {
        Store.shared.settings["hideNavTips"] = true; Store.shared.saveSettings()
        tipCard?.isHidden = true
        stopTipRotation()
    }


    // MARK: messages

    func addUser(_ text: String) {
        messages.append(["role": "user", "text": text]); persist()
        addMessage(text, user: true)
        applyTheme()
    }
    func addAI(_ text: String, chips: [String] = []) {
        messages.append(["role": "ai", "text": text]); persist()
        if !chips.isEmpty { addChipsRow(chips) }
        addMessage(text, user: false)
        applyTheme()
    }
    func addImageLoading() -> GeneratedImageBubble {
        empty.isHidden = true
        let bubble = GeneratedImageBubble()
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [bubble, spacer])
        row.orientation = .horizontal; row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        messagesStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor).isActive = true
        bubble.widthAnchor.constraint(equalToConstant: 236).isActive = true
        bubble.heightAnchor.constraint(equalToConstant: 236).isActive = true
        scrollToBottom()
        return bubble
    }
    func finishImage(_ bubble: GeneratedImageBubble, image: NSImage, prompt: String, path: String?) {
        if let path {
            bubble.onDownload = { [weak self] in self?.onDownloadImagePath?(path) }
        }
        bubble.finish(image)
        var msg = ["role": "image", "text": prompt]
        if let path { msg["path"] = path }
        messages.append(msg)
        persist()
        scrollToBottom()
    }
    func failImage(_ bubble: GeneratedImageBubble, message: String) {
        bubble.fail(message)
        scrollToBottom()
    }
    private func persist() {
        guard let first = messages.first(where: { $0["role"] == "user" })?["text"] else { return }
        Store.shared.upsertChat(id: chatId, title: String(first.prefix(48)), messages: messages)
    }

    func startNewChat() {
        chatId = Date().timeIntervalSince1970
        messages = []
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        messageBubbles.removeAll()
        empty.isHidden = false
        setMode(history: false)
    }
    private func loadChat(id: Double) {
        chatId = id
        messages = Store.shared.chatMessages(id: id)
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        messageBubbles.removeAll()
        empty.isHidden = !messages.isEmpty
        for m in messages {
            if m["role"] == "image", let path = m["path"], let img = NSImage(contentsOfFile: path) {
                let bubble = addImageLoading()
                bubble.onDownload = { [weak self] in self?.onDownloadImagePath?(path) }
                bubble.finish(img, animated: false)
            } else {
                addMessage(m["text"] ?? "", user: m["role"] == "user")
            }
        }
        setMode(history: false)
    }
    /// Open a saved chat in the panel (called when a chat is tapped on the
    /// History page).
    func openChat(id: Double) { loadChat(id: id) }

    private func addChipsRow(_ chips: [String]) {
        empty.isHidden = true
        let p = Theme.shared.palette
        let visibleChips = Array(chips.prefix(4))
        guard !visibleChips.isEmpty else { return }
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 5; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        for c in visibleChips {
            let clean = cleanPillText(c)
            let pill = NSView(); pill.wantsLayer = true; pill.layer?.cornerRadius = 8
            pill.layer?.backgroundColor = p.surface.cgColor
            pill.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: contextIcon(for: clean))
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: compactPillText(clean)); l.font = .systemFont(ofSize: 10.5); l.textColor = p.textSoft
            l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(icon); pill.addSubview(l)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 18),
                pill.widthAnchor.constraint(lessThanOrEqualToConstant: 154),
                icon.widthAnchor.constraint(equalToConstant: 12),
                icon.heightAnchor.constraint(equalToConstant: 12),
                icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
                icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                l.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                l.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            ])
            row.addArrangedSubview(pill)
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(row)
        scroll.documentView = doc
        messagesStack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: messagesStack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 22),
            doc.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: doc.centerYAnchor),
        ])
    }

    private func addMessage(_ text: String, user: Bool) {
        empty.isHidden = true
        stopTipRotation()
        let p = Theme.shared.palette
        let attributed: NSAttributedString
        if user {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: onAccentText(p.accent)
            ]
            attributed = NSAttributedString(string: text, attributes: attrs)
        } else {
            attributed = Self.renderMarkdown(text, color: .white)   // **bold**, lists, etc.
        }
        let card = MessageBubbleView(text: attributed, isUser: user, accent: p.accent, isDark: p.isDark)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.required, for: .horizontal)
        card.setContentCompressionResistancePriority(.required, for: .horizontal)
        let size = card.update(maxTextWidth: messageMaxWidth)
        let bubbleWidth = card.widthAnchor.constraint(equalToConstant: size.width)
        let bubbleHeight = card.heightAnchor.constraint(equalToConstant: size.height)
        NSLayoutConstraint.activate([bubbleWidth, bubbleHeight])
        messageBubbles.append(MessageBubbleRecord(bubble: card, widthConstraint: bubbleWidth, heightConstraint: bubbleHeight))

        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(card)
        messagesStack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor),
            card.topAnchor.constraint(equalTo: row.topAnchor),
            card.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor)
        ])
        if user {
            NSLayoutConstraint.activate([
                card.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                card.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                card.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                card.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor)
            ])
        }
        scrollToBottom()
    }

    func clear() {
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        messageBubbles.removeAll()
        empty.isHidden = false
        tipIndex = Int.random(in: 0..<max(1, navTips.count))
        tipLabel?.stringValue = navTips.isEmpty ? "" : navTips[tipIndex]
        refreshTipVisibility()   // fresh tip + restart rotation on a new chat
    }
    func setStatus(_ s: String?) {
        status.isHidden = (s == nil)
        status.stringValue = s ?? ""
        if let s, !s.isEmpty { taskLoader?.setLabel(s) }   // keep the chat loader's label in sync
    }

    // MARK: - Working loader (animated dots in the chat while Nav runs a Task)

    private var taskLoader: TaskLoaderView?
    /// Show an animated "working" bubble in the chat. The dots animate on the render
    /// server (no main-thread timer) and the bubble is torn down the moment work ends,
    /// so it never violates the no-idle-animation rule.
    func showTaskLoader(_ label: String) {
        empty.isHidden = true
        hideTaskLoader()
        let loader = TaskLoaderView(label: label)
        loader.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(loader)
        messagesStack.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor),
            loader.topAnchor.constraint(equalTo: row.topAnchor),
            loader.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            loader.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            loader.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])
        taskLoader = loader
        loader.startAnimating()
        scrollToBottom()
    }
    func hideTaskLoader() {
        taskLoader?.superview?.removeFromSuperview()
        taskLoader = nil
    }
    /// Shown in the empty state so the user can see the model's readiness.
    func setModelStatus(_ text: String) {
        if messagesStack.arrangedSubviews.isEmpty { empty.isHidden = false; emptySub.stringValue = text }
    }
    /// Lock the input while the model downloads / prepares.
    func setInputEnabled(_ on: Bool, placeholder: String? = nil) {
        input.isEnabled = on
        input.placeholderString = placeholder ?? "Ask anything…  (@ tab · / task)"
    }

    /// Image generation was removed from Nav; kept as a no-op so older call sites
    /// (and any saved state) don't need to change.
    func setImageMode(_ on: Bool) {}

    // typing "@" opens the tab picker; "/" at the start opens the Task palette.
    func controlTextDidChange(_ obj: Notification) {
        let v = input.stringValue
        if v.hasSuffix("@") { onAtMention?(); return }
        // While typing the slug (leading "/", no space yet) show the live Task list;
        // otherwise dismiss it.
        if v.hasPrefix("/") && !v.contains(" ") { onSlashTasks?(String(v.dropFirst())) }
        else { onSlashTasksEnd?() }
    }

    /// Picked a Task from the palette — drop "/slug " into the input, ready for the
    /// user's prompt (or just Enter for page-based Tasks), and update the hint.
    func fillSlashTask(_ task: BreezeTask) {
        input.stringValue = "/\(task.slug) "
        input.placeholderString = task.placeholder
        focusInput()
        input.currentEditor()?.selectedRange = NSRange(location: (input.stringValue as NSString).length, length: 0)
    }

    func popMenuAtInput(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: -4), in: inputWrap)
    }

    private(set) var historyMode = false
    /// History is an overlay over the chat (input stays); toggled by the button.
    func setMode(history: Bool) {
        historyMode = history
        historyView.isHidden = !history
        if history { renderHistory() }
    }
    func toggleHistory() { setMode(history: !historyMode) }
    func showHistory() { setMode(history: true) }
    /// In fullscreen the panel fills the tab. `clearLights` indents the header
    /// only when the panel reaches the window's left edge (sidebar hidden).
    func setFullscreen(_ on: Bool, clearLights: Bool = false) {
        headerView.isHidden = on
        fsNewChatBtn.isHidden = !on   // header (with its new-chat button) is hidden in fullscreen
        scrollTopToHeaderC.isActive = !on
        scrollTopToPanelC.isActive = on
        historyTopToHeaderC.isActive = !on
        historyTopToPanelC.isActive = on
        headerLeadingC.constant = (on && clearLights) ? 82 : 14
        updateMessageWidths(fullscreen: on)

        messagesWidthC.isActive = false
        inputWidthC.isActive = false
        statusWidthC.isActive = false
        contextWidthC.isActive = false
        historyWidthC.isActive = false

        if on {
            let column = messageColumnWidth(fullscreen: true)
            messagesWidthC = messagesStack.widthAnchor.constraint(equalToConstant: column)
            inputWidthC = inputWrap.widthAnchor.constraint(equalToConstant: min(680, column))
            statusWidthC = status.widthAnchor.constraint(equalToConstant: min(680, column))
            contextWidthC = contextScroll.widthAnchor.constraint(equalToConstant: min(680, column))
            historyWidthC = historyView.widthAnchor.constraint(equalToConstant: column)
        } else {
            messagesWidthC = messagesStack.widthAnchor.constraint(equalTo: scroll.documentView!.widthAnchor, constant: -16)
            inputWidthC = inputWrap.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
            statusWidthC = status.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
            contextWidthC = contextScroll.widthAnchor.constraint(equalTo: widthAnchor, constant: -28)
            historyWidthC = historyView.widthAnchor.constraint(equalTo: widthAnchor)
        }

        messagesWidthC.isActive = true
        inputWidthC.isActive = true
        statusWidthC.isActive = true
        contextWidthC.isActive = true
        historyWidthC.isActive = true
        refreshExistingMessageWidths()
    }

    func prepareForFullscreenReparent() {
        isHidden = true
        setFullscreen(false, clearLights: false)
        layoutSubtreeIfNeeded()
    }

    func finishFullscreenReparent(clearLights: Bool = false) {
        isHidden = false
        setFullscreen(true, clearLights: clearLights)
        needsLayout = true
        layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFullscreen(true, clearLights: clearLights)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    private func updateMessageWidths(fullscreen: Bool? = nil) {
        let isFullscreen = fullscreen ?? headerView.isHidden
        messageMaxWidth = max(120, messageColumnWidth(fullscreen: isFullscreen) - (isFullscreen ? 64 : 28))
    }

    private func messageColumnWidth(fullscreen: Bool) -> CGFloat {
        let available = max(220, bounds.width - (fullscreen ? 150 : 36))
        return fullscreen ? min(760, available) : min(360, max(240, available))
    }

    private func refreshExistingMessageWidths() {
        for record in messageBubbles {
            guard let bubble = record.bubble else { continue }
            let size = bubble.update(maxTextWidth: messageMaxWidth)
            record.widthConstraint?.constant = size.width
            record.heightConstraint?.constant = size.height
        }
    }

    private func renderHistory() {
        let p = Theme.shared.palette
        historyView.layer?.backgroundColor = p.bg.cgColor
        historyList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let chats = Store.shared.chats
        if chats.isEmpty {
            let l = NSTextField(labelWithString: "No saved chats yet.")
            l.font = .systemFont(ofSize: 12); l.textColor = p.textSoft
            historyList.addArrangedSubview(l); return
        }
        for c in chats {
            guard let id = c["id"] as? Double else { continue }
            let title = (c["title"] as? String) ?? "Chat"
            let row = NSView(); row.wantsLayer = true; row.layer?.cornerRadius = 16
            row.layer?.backgroundColor = p.surface.cgColor
            row.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: title); l.font = .systemFont(ofSize: 12.5)
            l.textColor = p.text; l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            let del = NSButton(title: "✕", target: self, action: #selector(deleteChatRow(_:)))
            del.isBordered = false; del.font = .systemFont(ofSize: 10); del.contentTintColor = p.textSoft
            del.translatesAutoresizingMaskIntoConstraints = false
            del.identifier = NSUserInterfaceItemIdentifier(String(id))
            row.addSubview(l); row.addSubview(del)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 34),
                row.widthAnchor.constraint(equalTo: historyList.widthAnchor),
                l.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 11),
                l.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                l.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -6),
                del.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
                del.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            let g = NSClickGestureRecognizer(target: self, action: #selector(openChatRow(_:)))
            row.addGestureRecognizer(g)
            row.identifier = NSUserInterfaceItemIdentifier(String(id))
            historyList.addArrangedSubview(row)
        }
    }
    @objc private func openChatRow(_ g: NSClickGestureRecognizer) {
        if let s = g.view?.identifier?.rawValue, let id = Double(s) { loadChat(id: id) }
    }
    @objc private func deleteChatRow(_ sender: NSButton) {
        if let s = sender.identifier?.rawValue, let id = Double(s) { Store.shared.deleteChat(id: id); renderHistory() }
    }

    /// Pills above the input: the current tab (always included) + @-added tabs.
    func setContextPills(current: String?, extras: [String]) {
        contextRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let p = Theme.shared.palette
        func pill(_ text: String, removeIndex: Int?) -> NSView {
            let clean = cleanPillText(text)
            let v = NSView(); v.wantsLayer = true; v.layer?.cornerRadius = 15
            v.layer?.backgroundColor = (removeIndex == nil ? p.surfaceActive : p.surface).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            let icon = NSImageView(image: contextIcon(for: clean))
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: compactPillText(clean)); l.font = .systemFont(ofSize: 11); l.textColor = p.text
            l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(icon); v.addSubview(l)
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8).isActive = true
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
            icon.widthAnchor.constraint(equalToConstant: 13).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 13).isActive = true
            l.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5).isActive = true
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
            v.heightAnchor.constraint(equalToConstant: 22).isActive = true
            v.widthAnchor.constraint(lessThanOrEqualToConstant: removeIndex == nil ? 172 : 150).isActive = true
            if let idx = removeIndex {
                let x = NSButton(image: tintedSymbol("xmark", point: 9, weight: .semibold, color: p.textSoft) ?? NSImage(), target: self, action: #selector(removePill(_:)))
                x.isBordered = false; x.tag = idx
                x.contentTintColor = p.textSoft; x.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(x)
                x.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 3).isActive = true
                x.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -5).isActive = true
                x.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
                x.widthAnchor.constraint(equalToConstant: 14).isActive = true
                x.heightAnchor.constraint(equalToConstant: 14).isActive = true
            } else {
                l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -9).isActive = true
            }
            return v
        }
        if let cur = current { contextRow.addArrangedSubview(pill(cur, removeIndex: nil)) }
        for (i, e) in extras.enumerated() { contextRow.addArrangedSubview(pill(e, removeIndex: i)) }
        contextScroll.isHidden = (current == nil && extras.isEmpty)
    }
    @objc private func removePill(_ sender: NSButton) { onRemoveContext?(sender.tag) }

    private func cleanPillText(_ text: String) -> String {
        var s = text
        for prefix in ["📄 ", "🕐 ", "🔖 ", "📑 ", "🖼 ", "📁 "] {
            if s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        }
        s = s.replacingOccurrences(of: " · included", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compactPillText(_ text: String) -> String {
        switch text.lowercased() {
        case "recent history": return "History"
        case "open tabs": return "Tabs"
        default:
            let limit = 28
            if text.count <= limit { return text }
            return String(text.prefix(limit - 1)) + "…"
        }
    }

    private func contextIcon(for text: String) -> NSImage {
        let lower = text.lowercased()
        let symbol: String
        if lower.contains("history") {
            symbol = "clock"
        } else if lower.contains("bookmark") {
            symbol = "bookmark"
        } else if lower.contains("open tab") || lower == "tabs" || lower.contains("tabs") {
            symbol = "rectangle.on.rectangle"
        } else if lower.contains(".png") || lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".heic") || lower.contains("image") {
            symbol = "photo"
        } else {
            symbol = "doc.text"
        }
        return tintedSymbol(symbol, point: 10.5, weight: .semibold, color: Theme.shared.palette.textSoft) ?? NSImage()
    }

    /// Render a markdown subset (bold/italic/code/links, preserved line breaks).
    static func renderMarkdown(_ s: String, color: NSColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attr: NSMutableAttributedString
        if let a = try? NSAttributedString(markdown: s, options: opts) {
            attr = NSMutableAttributedString(attributedString: a)
        } else {
            attr = NSMutableAttributedString(string: s)
        }
        let full = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.foregroundColor, value: color, range: full)
        // normalize every run to 14pt while preserving bold/italic traits
        attr.enumerateAttribute(.font, in: full) { val, range, _ in
            let traits = (val as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var desc = NSFont.systemFont(ofSize: 14).fontDescriptor
            var keep: NSFontDescriptor.SymbolicTraits = []
            if traits.contains(.bold) { keep.insert(.bold) }
            if traits.contains(.italic) { keep.insert(.italic) }
            if !keep.isEmpty { desc = desc.withSymbolicTraits(keep) }
            let f = NSFont(descriptor: desc, size: 14) ?? .systemFont(ofSize: 14)
            attr.addAttribute(.font, value: f, range: range)
        }
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = 7
        para.lineSpacing = 2
        para.lineBreakMode = .byWordWrapping
        para.allowsDefaultTighteningForTruncation = false
        attr.addAttribute(.paragraphStyle, value: para, range: full)
        return attr
    }

    private func onAccentText(_ accent: NSColor) -> NSColor {
        guard let c = accent.usingColorSpace(.sRGB) else { return .white }
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum > 0.6 ? NSColor(white: 0.08, alpha: 1) : .white
    }

    private func scrollToBottom() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            let h = self.scroll.documentView?.bounds.height ?? 0
            self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, h - self.scroll.contentView.bounds.height)))
        }
    }

    @objc private func send() {
        let t = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        input.stringValue = ""
        onSend?(t)
    }

    func focusInput() { window?.makeFirstResponder(input) }

    func setCreatorToolsAvailable(_ available: Bool) {
        creatorBtn.isHidden = !available
    }

    override func layout() {
        super.layout()
        updateMessageWidths()
        refreshExistingMessageWidths()
        syncBackgroundLayers()
    }

    private func syncBackgroundLayers() {
        guard let layer else { return }
        let p = Theme.shared.palette
        let gradient = (layer.sublayers?.first { $0.name == "assistantBgGrad" } as? CAGradientLayer) ?? CAGradientLayer()
        gradient.name = "assistantBgGrad"
        gradient.frame = bounds
        gradient.colors = [p.bgTop.cgColor, p.bg.cgColor, p.bgBottom.cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.1, y: 1)
        gradient.endPoint = CGPoint(x: 0.9, y: 0)
        if gradient.superlayer == nil { layer.insertSublayer(gradient, at: 0) }

        let wash = layer.sublayers?.first { $0.name == "assistantAccentWash" } ?? CALayer()
        wash.name = "assistantAccentWash"
        wash.frame = bounds
        wash.backgroundColor = p.accent.withAlphaComponent(0.12).cgColor
        if wash.superlayer == nil { layer.insertSublayer(wash, above: gradient) }
    }


    @objc func applyTheme() {
        let p = Theme.shared.palette
        appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)   // sync glass/material so light-mode chat text stays readable
        layer?.backgroundColor = p.bg.cgColor
        syncBackgroundLayers()
        inputWrap.layer?.backgroundColor = p.surface.cgColor
        input.textColor = p.text
        status.textColor = p.textSoft
        headerLogo.image = navLogo()
        emptyLogo.image = navLogo()
        creatorBtn.applyTheme()
        emptyTitle?.textColor = p.text
        emptySub?.textColor = p.textSoft
        styleTipCard()
    }
}

final class GeneratedImageBubble: NSView {
    private let imageView = NSImageView()
    private let shimmer = CALayer()
    private let gradient = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")
    private let downloadBtn = HoverButton(symbol: "arrow.down.circle.fill", size: 30, point: 16)
    var onDownload: (() -> Void)? {
        didSet { downloadBtn.isHidden = onDownload == nil || imageView.image == nil }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor

        gradient.type = .conic
        gradient.colors = [
            NSColor(srgbRed: 0.58, green: 0.45, blue: 0.82, alpha: 0.48).cgColor,
            NSColor(srgbRed: 0.25, green: 0.58, blue: 0.78, alpha: 0.42).cgColor,
            NSColor(srgbRed: 0.28, green: 0.68, blue: 0.58, alpha: 0.42).cgColor,
            NSColor(srgbRed: 0.86, green: 0.70, blue: 0.35, alpha: 0.38).cgColor,
            NSColor(srgbRed: 0.82, green: 0.38, blue: 0.46, alpha: 0.42).cgColor,
            NSColor(srgbRed: 0.58, green: 0.45, blue: 0.82, alpha: 0.48).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.opacity = 0.55
        shimmer.addSublayer(gradient)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(26.0, forKey: "inputRadius")
            shimmer.filters = [blur]
        }
        layer?.addSublayer(shimmer)

        for i in 0..<10 {
            let dot = CALayer()
            dot.backgroundColor = NSColor.white.withAlphaComponent(i % 3 == 0 ? 0.45 : 0.26).cgColor
            dot.cornerRadius = 2
            dot.bounds = CGRect(x: 0, y: 0, width: i % 4 == 0 ? 4 : 2.5, height: i % 4 == 0 ? 4 : 2.5)
            dot.name = "sparkle"
            layer?.addSublayer(dot)
        }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.alphaValue = 0
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 18
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
        imageView.pin(to: self)

        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.82)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = "Making image…"
        addSubview(label)
        downloadBtn.toolTip = "Download image"
        downloadBtn.isHidden = true
        downloadBtn.onTap = { [weak self] in self?.onDownload?() }
        addSubview(downloadBtn)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -28),
            downloadBtn.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            downloadBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = 3.0
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "imageGradientSpin")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        shimmer.frame = bounds.insetBy(dx: -30, dy: -30)
        gradient.frame = shimmer.bounds
        let dots = layer?.sublayers?.filter { $0.name == "sparkle" } ?? []
        for (i, dot) in dots.enumerated() {
            let x = bounds.width * CGFloat((i * 37) % 100) / 100
            let y = bounds.height * CGFloat((i * 61) % 100) / 100
            dot.position = CGPoint(x: x, y: y)
        }
    }

    func finish(_ image: NSImage, animated: Bool = true) {
        label.isHidden = true
        shimmer.removeAllAnimations()
        shimmer.opacity = 0
        imageView.image = image
        imageView.alphaValue = animated ? 0 : 1
        downloadBtn.isHidden = onDownload == nil
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                imageView.animator().alphaValue = 1
            }
        }
    }

    func fail(_ message: String) {
        shimmer.removeAllAnimations()
        gradient.opacity = 0.25
        label.stringValue = message
        downloadBtn.isHidden = true
    }
}

private final class MessageBubbleView: NSView {
    private let text: NSAttributedString
    private let isUser: Bool
    private let fillColor: NSColor
    private let borderColor: NSColor?
    private let shadowOpacity: Float
    private let shadowRadius: CGFloat
    private let shadowYOffset: CGFloat
    private let insets: NSEdgeInsets
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer()
    private var textWidth: CGFloat = 0

    init(text: NSAttributedString, isUser: Bool, accent: NSColor, isDark: Bool) {
        self.text = text
        self.isUser = isUser
        self.insets = NSEdgeInsets(top: isUser ? 10 : 16, left: isUser ? 17 : 18, bottom: isUser ? 10 : 17, right: isUser ? 17 : 18)
        self.fillColor = isUser
            ? (accent.usingColorSpace(.deviceRGB) ?? accent)
            : NSColor(srgbRed: 0.075, green: 0.078, blue: 0.09, alpha: 0.96)
        self.borderColor = isUser ? nil : NSColor.white.withAlphaComponent(isDark ? 0.08 : 0.12)
        self.shadowOpacity = isUser ? 0.04 : 0.10
        self.shadowRadius = isUser ? 4 : 9
        self.shadowYOffset = isUser ? 1 : 3
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineBreakMode = .byWordWrapping
        storage.setAttributedString(text)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func update(maxTextWidth: CGFloat) -> CGSize {
        let maxWidth = max(90, maxTextWidth)
        let minimum: CGFloat = isUser ? 26 : 56
        let single = measuredTextSize(width: 10_000)
        let targetWidth = min(maxWidth, max(minimum, ceil(single.width) + 2))
        let wrapped = measuredTextSize(width: targetWidth)
        textWidth = min(maxWidth, max(minimum, ceil(wrapped.width) + 2))
        let final = measuredTextSize(width: textWidth)
        let height = ceil(final.height) + insets.top + insets.bottom + 3
        let width = textWidth + insets.left + insets.right
        needsDisplay = true
        return CGSize(width: ceil(width), height: ceil(height))
    }

    private func measuredTextSize(width: CGFloat) -> CGSize {
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: max(used.width, 1), height: max(used.height, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(isUser ? 28 : 26, bounds.height / 2)
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setShadow(offset: CGSize(width: 0, height: shadowYOffset), blur: shadowRadius, color: NSColor.black.withAlphaComponent(CGFloat(shadowOpacity)).cgColor)
        }
        fillColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let borderColor {
            borderColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        textContainer.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let point = CGPoint(x: insets.left, y: insets.top)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: point)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: point)
    }
}

/// The animated "Nav is working" bubble shown in the chat while a Task runs. Three
/// dots breathe in a staggered wave (Core Animation, render-server) next to a live
/// status label. It only exists between send and done, so there's no idle GPU cost.
private final class TaskLoaderView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dotsLayer = CALayer()
    private var dots: [CALayer] = []

    init(label text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 17
        layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.09, alpha: 0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        label.stringValue = text
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let dotHost = NSView(); dotHost.wantsLayer = true
        dotHost.translatesAutoresizingMaskIntoConstraints = false
        dotHost.layer?.addSublayer(dotsLayer)
        addSubview(dotHost)

        let r: CGFloat = 3.0, gap: CGFloat = 7.0
        for i in 0..<3 {
            let d = CALayer()
            d.frame = CGRect(x: CGFloat(i) * gap, y: 0, width: r * 2, height: r * 2)
            d.cornerRadius = r
            d.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            dotsLayer.addSublayer(d)
            dots.append(d)
        }
        dotsLayer.frame = CGRect(x: 0, y: 0, width: gap * 2 + r * 2, height: r * 2)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
            dotHost.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 9),
            dotHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            dotHost.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            dotHost.widthAnchor.constraint(equalToConstant: gap * 2 + r * 2),
            dotHost.heightAnchor.constraint(equalToConstant: r * 2),
        ])
    }
    required init?(coder: NSCoder) { nil }

    func setLabel(_ s: String) { label.stringValue = s }

    func startAnimating() {
        for (i, d) in dots.enumerated() {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.25; a.toValue = 1.0
            a.duration = 0.55
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.18
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            d.add(a, forKey: "breathe")
        }
    }
}
