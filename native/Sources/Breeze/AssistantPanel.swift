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
    var onAttach: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onAtMention: (() -> Void)?
    var onRemoveContext: ((Int) -> Void)?
    var onToggleFullscreen: (() -> Void)?
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
    // chat state
    private var chatId = Date().timeIntervalSince1970
    private var messages: [[String: String]] = []   // {role: user|ai, text}
    private let historyView = NSView()
    private let historyList = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // header
        let logo = NSImageView(); logo.image = breezeLogo()
        logo.imageScaling = .scaleProportionallyDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "Assistant")
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
        let header = NSStackView(views: [logo, title, hspacer, fs, newChat, close])
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
        let inputWrap = NSView(); inputWrap.wantsLayer = true; inputWrap.layer?.cornerRadius = 14
        inputWrap.translatesAutoresizingMaskIntoConstraints = false
        input.placeholderString = "Ask anything…"
        input.font = .systemFont(ofSize: 13.5)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.translatesAutoresizingMaskIntoConstraints = false
        input.target = self; input.action = #selector(send)
        input.delegate = self
        contextRow.orientation = .horizontal; contextRow.spacing = 5; contextRow.alignment = .centerY
        contextRow.translatesAutoresizingMaskIntoConstraints = false
        contextRow.isHidden = true
        sendBtn.onTap = { [weak self] in self?.send() }
        attachBtn.onTap = { [weak self] in self?.onAttach?() }
        inputWrap.addSubview(attachBtn); inputWrap.addSubview(input); inputWrap.addSubview(sendBtn)

        status.font = .systemFont(ofSize: 11.5)
        status.translatesAutoresizingMaskIntoConstraints = false
        status.isHidden = true

        addSubview(header); addSubview(scroll); addSubview(empty); addSubview(historyView); addSubview(status); addSubview(contextRow); addSubview(inputWrap)
        self.inputWrap = inputWrap

        messagesWidthC = messagesStack.widthAnchor.constraint(equalTo: doc.widthAnchor, constant: -16)
        inputWidthC = inputWrap.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
        statusWidthC = status.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
        contextWidthC = contextRow.widthAnchor.constraint(equalTo: widthAnchor, constant: -28)
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
            contextRow.centerXAnchor.constraint(equalTo: centerXAnchor),
            contextRow.bottomAnchor.constraint(equalTo: inputWrap.topAnchor, constant: -6),
            historyView.centerXAnchor.constraint(equalTo: centerXAnchor),
            historyView.bottomAnchor.constraint(equalTo: inputWrap.topAnchor, constant: -6),
            historyTopToHeaderC,
        ])
        headerLeadingC = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerLeadingC,
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            logo.widthAnchor.constraint(equalToConstant: 20), logo.heightAnchor.constraint(equalToConstant: 20),

            scrollTopToHeaderC,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: inputWrap.topAnchor, constant: -8),
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
            input.leadingAnchor.constraint(equalTo: attachBtn.trailingAnchor, constant: 4),
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
        let logo = NSImageView(); logo.image = breezeLogo()
        logo.imageScaling = .scaleProportionallyDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        let h = NSTextField(labelWithString: "Private intelligence")
        h.font = .systemFont(ofSize: 16, weight: .semibold); h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        let p = NSTextField(labelWithString: "Runs on your Mac.\nReads pages, searches the web — all on-device.")
        p.font = .systemFont(ofSize: 12.5); p.alignment = .center; p.maximumNumberOfLines = 3
        p.textColor = Theme.shared.palette.textSoft
        p.translatesAutoresizingMaskIntoConstraints = false
        p.cell?.wraps = true
        p.cell?.lineBreakMode = .byWordWrapping
        
        let chips = NSStackView(views: ["Summarize this page", "Key takeaways", "Explain this simply"].map { chip($0) })
        chips.orientation = .vertical; chips.spacing = 6; chips.alignment = .centerX
        chips.translatesAutoresizingMaskIntoConstraints = false
        
        let s = NSStackView(views: [logo, h, p, chips]); s.orientation = .vertical; s.spacing = 10; s.alignment = .centerX
        s.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(s); s.pin(to: empty)
        
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 44),
            logo.heightAnchor.constraint(equalToConstant: 44),
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
        pill.layer?.backgroundColor = Theme.shared.palette.surface.cgColor
        pill.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12); label.textColor = Theme.shared.palette.text
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
        return pill
    }
    @objc private func chipClicked(_ g: NSClickGestureRecognizer) {
        if let t = g.view?.identifier?.rawValue { onSend?(t) }
    }

    // MARK: messages

    func addUser(_ text: String) {
        messages.append(["role": "user", "text": text]); persist()
        addMessage(text, user: true)
    }
    func addAI(_ text: String, chips: [String] = []) {
        messages.append(["role": "ai", "text": text]); persist()
        if !chips.isEmpty { addChipsRow(chips) }
        addMessage(text, user: false)
    }
    private func persist() {
        guard let first = messages.first(where: { $0["role"] == "user" })?["text"] else { return }
        Store.shared.upsertChat(id: chatId, title: String(first.prefix(48)), messages: messages)
    }

    func startNewChat() {
        chatId = Date().timeIntervalSince1970
        messages = []
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        empty.isHidden = false
        setMode(history: false)
    }
    private func loadChat(id: Double) {
        chatId = id
        messages = Store.shared.chatMessages(id: id)
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        empty.isHidden = !messages.isEmpty
        for m in messages { addMessage(m["text"] ?? "", user: m["role"] == "user") }
        setMode(history: false)
    }
    /// Open a saved chat in the panel (called when a chat is tapped on the
    /// History page).
    func openChat(id: Double) { loadChat(id: id) }

    private func addChipsRow(_ chips: [String]) {
        empty.isHidden = true
        let p = Theme.shared.palette
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 5; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        for c in chips {
            let pill = NSView(); pill.wantsLayer = true; pill.layer?.cornerRadius = 8
            pill.layer?.backgroundColor = p.surface.cgColor
            pill.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: c); l.font = .systemFont(ofSize: 10.5); l.textColor = p.textSoft
            l.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(l)
            NSLayoutConstraint.activate([
                pill.heightAnchor.constraint(equalToConstant: 18),
                l.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                l.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
                l.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            ])
            row.addArrangedSubview(pill)
        }
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(row)
        messagesStack.addArrangedSubview(wrap)          // add BEFORE cross-view constraints
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            row.topAnchor.constraint(equalTo: wrap.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
            wrap.widthAnchor.constraint(equalTo: messagesStack.widthAnchor),
        ])
    }

    private func addMessage(_ text: String, user: Bool) {
        empty.isHidden = true
        let p = Theme.shared.palette
        let card = NSView(); card.wantsLayer = true; card.layer?.cornerRadius = 13
        card.layer?.backgroundColor = (user ? p.accent : p.surface).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(wrappingLabelWithString: text)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = messageMaxWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        if user {
            label.font = .systemFont(ofSize: 13)
            label.textColor = onAccentText(p.accent)
        } else {
            label.attributedStringValue = Self.renderMarkdown(text, color: p.text)   // **bold**, lists, etc.
        }
        card.addSubview(label)
        label.pin(to: card, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))

        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: user ? [spacer, card] : [card, spacer])
        row.orientation = .horizontal; row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        messagesStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: messagesStack.widthAnchor).isActive = true
        scrollToBottom()
    }

    func clear() {
        messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
        input.placeholderString = placeholder ?? "Ask anything…  (@ to add a tab)"
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
        // wider reading column for messages when fullscreen
        messageMaxWidth = on ? 600 : 250

        messagesWidthC.isActive = false
        inputWidthC.isActive = false
        statusWidthC.isActive = false
        contextWidthC.isActive = false
        historyWidthC.isActive = false

        if on {
            messagesWidthC = messagesStack.widthAnchor.constraint(equalToConstant: 600)
            inputWidthC = inputWrap.widthAnchor.constraint(equalToConstant: 600)
            statusWidthC = status.widthAnchor.constraint(equalToConstant: 600)
            contextWidthC = contextRow.widthAnchor.constraint(equalToConstant: 600)
            historyWidthC = historyView.widthAnchor.constraint(equalToConstant: 600)
        } else {
            messagesWidthC = messagesStack.widthAnchor.constraint(equalTo: scroll.documentView!.widthAnchor, constant: -16)
            inputWidthC = inputWrap.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
            statusWidthC = status.widthAnchor.constraint(equalTo: widthAnchor, constant: -32)
            contextWidthC = contextRow.widthAnchor.constraint(equalTo: widthAnchor, constant: -28)
            historyWidthC = historyView.widthAnchor.constraint(equalTo: widthAnchor)
        }

        messagesWidthC.isActive = true
        inputWidthC.isActive = true
        statusWidthC.isActive = true
        contextWidthC.isActive = true
        historyWidthC.isActive = true
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
            let row = NSView(); row.wantsLayer = true; row.layer?.cornerRadius = 8
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
            let v = NSView(); v.wantsLayer = true; v.layer?.cornerRadius = 9
            v.layer?.backgroundColor = (removeIndex == nil ? p.surfaceActive : p.surface).cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: 11); l.textColor = p.text
            l.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(l)
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 9).isActive = true
            l.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
            v.heightAnchor.constraint(equalToConstant: 22).isActive = true
            if let idx = removeIndex {
                let x = NSButton(title: "✕", target: self, action: #selector(removePill(_:)))
                x.isBordered = false; x.font = .systemFont(ofSize: 9); x.tag = idx
                x.contentTintColor = p.textSoft; x.translatesAutoresizingMaskIntoConstraints = false
                v.addSubview(x)
                x.leadingAnchor.constraint(equalTo: l.trailingAnchor, constant: 3).isActive = true
                x.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -5).isActive = true
                x.centerYAnchor.constraint(equalTo: v.centerYAnchor).isActive = true
            } else {
                l.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -9).isActive = true
            }
            return v
        }
        if let cur = current { contextRow.addArrangedSubview(pill(cur + " · included", removeIndex: nil)) }
        for (i, e) in extras.enumerated() { contextRow.addArrangedSubview(pill(e, removeIndex: i)) }
        contextRow.isHidden = (current == nil && extras.isEmpty)
    }
    @objc private func removePill(_ sender: NSButton) { onRemoveContext?(sender.tag) }

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
        // normalize every run to 13pt while preserving bold/italic traits
        attr.enumerateAttribute(.font, in: full) { val, range, _ in
            let traits = (val as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var desc = NSFont.systemFont(ofSize: 13).fontDescriptor
            var keep: NSFontDescriptor.SymbolicTraits = []
            if traits.contains(.bold) { keep.insert(.bold) }
            if traits.contains(.italic) { keep.insert(.italic) }
            if !keep.isEmpty { desc = desc.withSymbolicTraits(keep) }
            let f = NSFont(descriptor: desc, size: 13) ?? .systemFont(ofSize: 13)
            attr.addAttribute(.font, value: f, range: range)
        }
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 5; para.lineSpacing = 1.5
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

    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = p.bg.cgColor
        inputWrap.layer?.backgroundColor = p.surface.cgColor
        input.textColor = p.text
        status.textColor = p.textSoft
        emptyTitle?.textColor = p.text
        emptySub?.textColor = p.textSoft
    }
}
