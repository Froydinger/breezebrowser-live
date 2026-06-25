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
    private let imageBtn = HoverButton(symbol: "paintbrush", size: 28, point: 15)
    var onAttach: (() -> Void)?
    var onSend: ((String) -> Void)?
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
    private var emptyChipViews: [(NSView, NSTextField)] = []
    private struct MessageBubbleRecord {
        weak var textView: SelectableMessageTextView?
        weak var textWidthConstraint: NSLayoutConstraint?
        weak var bubbleWidthConstraint: NSLayoutConstraint?
        let attributedText: NSAttributedString
        let isUser: Bool
    }
    private var messageBubbles: [MessageBubbleRecord] = []
    private var imageMode = false
    // chat state
    private var chatId = Date().timeIntervalSince1970
    var messages: [[String: String]] = []   // {role: user|ai|image, text, path?}
    var wantsImageMode: Bool { imageMode }
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
        let newChat = HoverButton(symbol: "square.and.pencil", size: 28, point: 14)
        newChat.onTap = { [weak self] in self?.onNewChat?() }
        let close = HoverButton(symbol: "xmark", size: 28, point: 13)
        close.onTap = { [weak self] in self?.onClose?() }
        let hspacer = NSView(); hspacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [headerLogo, title, hspacer, fs, newChat, close])
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
        imageBtn.toolTip = "Generate or edit an image"
        imageBtn.onTap = { [weak self] in self?.setImageMode(!(self?.imageMode ?? false)) }
        inputWrap.addSubview(attachBtn); inputWrap.addSubview(imageBtn); inputWrap.addSubview(input); inputWrap.addSubview(sendBtn)

        status.font = .systemFont(ofSize: 11.5)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.isHidden = true

        addSubview(header); addSubview(scroll); addSubview(empty); addSubview(historyView); addSubview(status); addSubview(contextScroll); addSubview(inputWrap)
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
            imageBtn.leadingAnchor.constraint(equalTo: attachBtn.trailingAnchor, constant: 2),
            imageBtn.centerYAnchor.constraint(equalTo: inputWrap.centerYAnchor),
            input.leadingAnchor.constraint(equalTo: imageBtn.trailingAnchor, constant: 4),
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
        let p = NSTextField(labelWithString: "Powered by Breeze Cloud.\nReads pages, searches the web, makes images, and acts for you.")
        p.font = .systemFont(ofSize: 12.5); p.alignment = .center; p.maximumNumberOfLines = 3
        p.textColor = Theme.shared.palette.textSoft
        p.translatesAutoresizingMaskIntoConstraints = false
        p.cell?.wraps = true
        p.cell?.lineBreakMode = .byWordWrapping
        
        let chips = NSStackView(views: ["Summarize this page", "Key takeaways", "Explain this simply"].map { chip($0) })
        chips.orientation = .vertical; chips.spacing = 6; chips.alignment = .centerX
        chips.translatesAutoresizingMaskIntoConstraints = false
        
        let s = NSStackView(views: [emptyLogo, h, p, chips]); s.orientation = .vertical; s.spacing = 10; s.alignment = .centerX
        s.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(s); s.pin(to: empty)
        
        NSLayoutConstraint.activate([
            emptyLogo.widthAnchor.constraint(equalToConstant: 44),
            emptyLogo.heightAnchor.constraint(equalToConstant: 44),
            h.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16),
            p.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16),
            chips.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16)
        ])
        self.emptyTitle = h; self.emptySub = p
    }
    private var emptyTitle: NSTextField!
    private var emptySub: NSTextField!

    /// Full rounded pill with padding.
    private func chip(_ text: String) -> NSView {
        let pill = NSView(); pill.wantsLayer = true; pill.layer?.cornerRadius = 15
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 30),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
        ])
        let g = NSClickGestureRecognizer(target: self, action: #selector(chipClicked(_:)))
        pill.addGestureRecognizer(g)
        pill.identifier = NSUserInterfaceItemIdentifier(text)
        emptyChipViews.append((pill, label))
        styleEmptyChip(pill, label: label)
        return pill
    }
    @objc private func chipClicked(_ g: NSClickGestureRecognizer) {
        if let t = g.view?.identifier?.rawValue { onSend?(t) }
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
        let p = Theme.shared.palette
        // AI replies always sit in a near-black bubble with white text, so they stay
        // readable in light OR dark mode (avoids low-contrast text on a light panel).
        let aiBubble = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.09, alpha: 0.96)
        let card = NSView(); card.wantsLayer = true; card.layer?.cornerRadius = user ? 22 : 24
        let userBubble = p.accent.usingColorSpace(.deviceRGB) ?? p.accent
        card.layer?.backgroundColor = (user ? userBubble : aiBubble).cgColor
        card.layer?.borderWidth = user ? 0 : 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(p.isDark ? 0.08 : 0.12).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = user ? 0.04 : 0.10
        card.layer?.shadowRadius = user ? 4 : 9
        card.layer?.shadowOffset = CGSize(width: 0, height: user ? 1 : 3)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.required, for: .horizontal)
        card.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bubblePadding = NSEdgeInsets(top: user ? 10 : 13, left: user ? 16 : 17, bottom: user ? 10 : 13, right: user ? 16 : 17)
        let label = SelectableMessageTextView(maxWidth: messageMaxWidth)
        let attributed: NSAttributedString
        if user {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: onAccentText(p.accent)
            ]
            attributed = NSAttributedString(string: text, attributes: attrs)
        } else {
            label.textColor = .white
            attributed = Self.renderMarkdown(text, color: .white)   // **bold**, lists, etc.
        }
        label.attributedString = attributed
        card.addSubview(label)
        let metrics = measuredBubbleMetrics(attributed, maxTextWidth: messageMaxWidth, insets: bubblePadding, isUser: user)
        let labelWidth = label.widthAnchor.constraint(equalToConstant: metrics.textWidth)
        let bubbleWidth = card.widthAnchor.constraint(equalToConstant: metrics.bubbleWidth)
        NSLayoutConstraint.activate([labelWidth, bubbleWidth])
        label.updateMaxWidth(metrics.textWidth)
        label.pin(to: card, insets: bubblePadding)
        messageBubbles.append(MessageBubbleRecord(textView: label, textWidthConstraint: labelWidth, bubbleWidthConstraint: bubbleWidth, attributedText: attributed, isUser: user))

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
    }
    func setStatus(_ s: String?) {
        status.isHidden = (s == nil)
        status.stringValue = s ?? ""
    }
    /// Shown in the empty state so the user can see the model's readiness.
    func setModelStatus(_ text: String) {
        if messagesStack.arrangedSubviews.isEmpty { empty.isHidden = false; emptySub.stringValue = text }
    }
    /// Lock the input while the model downloads / prepares.
    func setInputEnabled(_ on: Bool, placeholder: String? = nil) {
        input.isEnabled = on
        input.placeholderString = placeholder ?? (imageMode ? "Describe the image to create or edit…" : "Ask anything…  (@ to add a tab)")
    }

    func setImageMode(_ on: Bool) {
        imageMode = on
        imageBtn.isOn = on
        imageBtn.toolTip = on ? "Image mode on" : "Generate or edit an image"
        input.placeholderString = on ? "Describe the image to create or edit…" : "Ask anything…  (@ to add a tab)"
    }

    // typing "@" opens the tab picker
    func controlTextDidChange(_ obj: Notification) {
        if input.stringValue.hasSuffix("@") { onAtMention?() }
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

    private func updateMessageWidths(fullscreen: Bool? = nil) {
        let isFullscreen = fullscreen ?? headerView.isHidden
        messageMaxWidth = messageColumnWidth(fullscreen: isFullscreen) - (isFullscreen ? 40 : 28)
    }

    private func messageColumnWidth(fullscreen: Bool) -> CGFloat {
        let available = max(260, bounds.width - (fullscreen ? 180 : 36))
        return fullscreen ? min(760, max(500, available)) : min(360, max(240, available))
    }

    private func refreshExistingMessageWidths() {
        for record in messageBubbles {
            let insets = NSEdgeInsets(top: record.isUser ? 10 : 13, left: record.isUser ? 16 : 17, bottom: record.isUser ? 10 : 13, right: record.isUser ? 16 : 17)
            let metrics = measuredBubbleMetrics(record.attributedText, maxTextWidth: messageMaxWidth, insets: insets, isUser: record.isUser)
            record.textWidthConstraint?.constant = metrics.textWidth
            record.bubbleWidthConstraint?.constant = metrics.bubbleWidth
            record.textView?.updateMaxWidth(metrics.textWidth)
        }
    }

    private func measuredBubbleMetrics(_ attr: NSAttributedString, maxTextWidth: CGFloat, insets: NSEdgeInsets, isUser: Bool) -> (textWidth: CGFloat, bubbleWidth: CGFloat) {
        let minWidth: CGFloat = isUser ? 18 : 34
        let maxWidth = max(80, maxTextWidth)
        let singleLine = attr.boundingRect(
            with: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let target = min(maxWidth, max(minWidth, ceil(singleLine.width) + 4))
        let wrapped = attr.boundingRect(
            with: NSSize(width: target, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textWidth = min(maxWidth, max(minWidth, ceil(min(singleLine.width, wrapped.width)) + 4))
        return (textWidth, textWidth + insets.left + insets.right)
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

    private func styleEmptyChip(_ pill: NSView, label: NSTextField) {
        let p = Theme.shared.palette
        if p.isDark {
            pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.88).cgColor
            label.textColor = NSColor(white: 0.10, alpha: 1)
        } else {
            pill.layer?.backgroundColor = p.surface.cgColor
            label.textColor = p.text
        }
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
        emptyTitle?.textColor = p.text
        emptySub?.textColor = p.textSoft
        emptyChipViews.forEach { styleEmptyChip($0.0, label: $0.1) }
        imageBtn.isOn = imageMode
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
