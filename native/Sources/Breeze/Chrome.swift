// Sidebar item views: tab rows and pins. Styled from ui/style.css (.tab / .pin).

import Cocoa

let breezeSidebarDragType = NSPasteboard.PasteboardType("com.froydinger.breeze.sidebar-item")

enum SidebarDragKind: String {
    case pin, tab, group
}

struct SidebarDragPayload {
    let kind: SidebarDragKind
    let id: String

    var encoded: String { "\(kind.rawValue)|\(id)" }

    static func decode(_ value: String?) -> SidebarDragPayload? {
        guard let value else { return nil }
        let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = SidebarDragKind(rawValue: parts[0]) else { return nil }
        return SidebarDragPayload(kind: kind, id: parts[1])
    }
}

enum SidebarDropPlacement {
    case before, after
}

private func beginSidebarDrag(from view: NSView, event: NSEvent, payload: SidebarDragPayload, source: NSDraggingSource) {
    let item = NSPasteboardItem()
    item.setString(payload.encoded, forType: breezeSidebarDragType)
    let draggingItem = NSDraggingItem(pasteboardWriter: item)
    draggingItem.setDraggingFrame(view.bounds, contents: view.bitmapImageRepForCachingDisplay(in: view.bounds).map { rep in
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size)
        img.addRepresentation(rep)
        return img
    })
    view.beginDraggingSession(with: [draggingItem], event: event, source: source)
}

private func setSidebarDropHighlight(_ view: NSView, _ on: Bool) {
    view.wantsLayer = true
    view.layer?.borderWidth = on ? 1 : 0
    view.layer?.borderColor = Theme.shared.palette.accent.withAlphaComponent(0.55).cgColor
}

private func verticalDropPlacement(_ view: NSView, _ info: NSDraggingInfo) -> SidebarDropPlacement {
    let point = view.convert(info.draggingLocation, from: nil)
    return point.y < view.bounds.midY ? .after : .before
}

private func horizontalDropPlacement(_ view: NSView, _ info: NSDraggingInfo) -> SidebarDropPlacement {
    let point = view.convert(info.draggingLocation, from: nil)
    return point.x > view.bounds.midX ? .after : .before
}

final class TabRowView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var dragPayload: SidebarDragPayload?
    var onDropPayload: ((SidebarDragPayload, SidebarDropPlacement) -> Bool)?
    var menuProvider: (() -> [MenuEntry])?     // controller builds the full menu
    private let faviconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let close = HoverButton(symbol: "xmark", size: 24, point: 10)
    private let perfBadge = NSTextField(labelWithString: "🚀")
    private let privateBadge = NSTextField(labelWithString: "🕵️")
    private var titleTrailingToBadges: NSLayoutConstraint!
    private var titleTrailingToEdge: NSLayoutConstraint!
    private var active: Bool
    private var inSplit: Bool
    private var hovering = false
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    init(title: String, host: String, active: Bool, perf: Bool = false, asleep: Bool = false, inSplit: Bool = false, isPrivate: Bool = false) {
        self.active = active
        self.inSplit = inSplit
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 19

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyDown
        faviconView.wantsLayer = true
        faviconView.layer?.cornerRadius = 4
        if isPrivate {
            faviconView.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
        } else {
            faviconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        }

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        close.onTap = { [weak self] in self?.onClose?() }
        close.alphaValue = active ? 0.9 : 0
        close.toolTip = "Close Tab"
        perfBadge.font = .systemFont(ofSize: 11)
        perfBadge.translatesAutoresizingMaskIntoConstraints = false
        perfBadge.isHidden = !perf
        perfBadge.toolTip = "Performance Mode on"

        privateBadge.font = .systemFont(ofSize: 11)
        privateBadge.translatesAutoresizingMaskIntoConstraints = false
        privateBadge.isHidden = !isPrivate
        privateBadge.toolTip = "Private Tab"

        addSubview(faviconView); addSubview(titleLabel); addSubview(perfBadge); addSubview(privateBadge); addSubview(close)
        titleTrailingToBadges = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: privateBadge.leadingAnchor, constant: -4)
        titleTrailingToEdge = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleTrailingToEdge,
            privateBadge.trailingAnchor.constraint(equalTo: perfBadge.leadingAnchor, constant: -4),
            privateBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            perfBadge.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            perfBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        titleTrailingToBadges.isActive = false
        registerForDraggedTypes([breezeSidebarDragType])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
        if !isPrivate && !host.isEmpty {
            Favicons.shared.image(for: host) { [weak self] img in if let img { self?.faviconView.image = img } }
        }
        if asleep { faviconView.alphaValue = 0.5; titleLabel.alphaValue = 0.55 }   // dimmed when sleeping
    }
    required init?(coder: NSCoder) { nil }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        titleLabel.textColor = p.text
        
        var bg: NSColor = active ? p.surfaceActive : (hovering ? p.surfaceHover : .clear)
        if inSplit {
            bg = p.accent.withAlphaComponent(active ? 0.25 : 0.12)
        }
        layer?.backgroundColor = bg.cgColor
        
        if active {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = p.isDark ? 0.25 : 0.06
            layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -2)
            
            if inSplit {
                layer?.borderWidth = 1.5
                layer?.borderColor = p.accent.cgColor
            } else {
                layer?.borderWidth = 0
            }
        } else {
            layer?.shadowOpacity = 0
            if inSplit {
                layer?.borderWidth = 1.5
                layer?.borderColor = p.accent.withAlphaComponent(0.4).cgColor
            } else {
                layer?.borderWidth = 0
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) {
        hovering = true; close.animator().alphaValue = 1
        titleTrailingToEdge.isActive = false
        titleTrailingToBadges.isActive = true
        if !perfBadge.isHidden { perfBadge.animator().alphaValue = 0 }
        applyTheme()
    }
    override func mouseExited(with e: NSEvent) {
        hovering = false; close.animator().alphaValue = active ? 0.9 : 0
        titleTrailingToBadges.isActive = false
        titleTrailingToEdge.isActive = true
        if !perfBadge.isHidden { perfBadge.animator().alphaValue = 1 }
        applyTheme()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in our superview's coordinate system. The whole row is one
        // click target — if we let it fall through to subviews (title label,
        // favicon), their views swallow the click and TabRowView.mouseUp never
        // fires, so selecting a tab took several clicks. mouseUp decides select
        // vs. close from the real cursor position.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return self
    }

    // Switch tabs on the FIRST click even when a WKWebView currently has focus.
    // Without this, AppKit eats the first click just to move first-responder off the
    // web view, so selecting a tab (especially from a split) took 2–3 clicks.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        mouseDownPoint = point
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil; mouseDownEvent = nil; dragStarted = false }
        guard !dragStarted, mouseDownPoint != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let closePoint = close.convert(point, from: self)
        if close.bounds.insetBy(dx: -4, dy: -4).contains(closePoint) {
            onClose?()
            return
        }
        if bounds.contains(point) { onSelect?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownPoint,
              let initialEvent = mouseDownEvent, let dragPayload else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
        dragStarted = true
        beginSidebarDrag(from: self, event: initialEvent, payload: dragPayload, source: self)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) != nil else { return [] }
        setSidebarDropHighlight(self, true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        setSidebarDropHighlight(self, false)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setSidebarDropHighlight(self, false)
        guard let payload = SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) else { return false }
        return onDropPayload?(payload, verticalDropPlacement(self, sender)) ?? false
    }

    override func rightMouseDown(with e: NSEvent) {
        if let entries = menuProvider?() { popupMenu(entries, for: self, with: e) }
    }
}

/// One split-view pane: its own URL-bar strip (back/fwd/reload + address) over a
/// hosted web view. Mirrors the Electron per-pane split-bar.
final class SplitPane: NSView {
    let sidebarToggle = HoverButton(symbol: "sidebar.left", size: 26, point: 13)
    let back = HoverButton(symbol: "chevron.left", size: 26, point: 13)
    let forward = HoverButton(symbol: "chevron.right", size: 26, point: 13)
    let reload = HoverButton(symbol: "arrow.clockwise", size: 26, point: 12)
    let address = NSTextField()
    private let addressWrap = NSView()
    let content = NSView()
    var onNavigate: ((String) -> Void)?
    var onSidebarToggle: (() -> Void)?
    var showsSidebarToggle = false {
        didSet {
            sidebarToggle.isHidden = !showsSidebarToggle
        }
    }
    private var navLeadingC: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.masksToBounds = true; layer?.cornerRadius = 10

        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        sidebarToggle.isHidden = true
        sidebarToggle.onTap = { [weak self] in self?.onSidebarToggle?() }

        addressWrap.wantsLayer = true; addressWrap.layer?.cornerRadius = 15
        addressWrap.translatesAutoresizingMaskIntoConstraints = false
        address.placeholderString = "Search or enter URL"
        address.font = .systemFont(ofSize: 12.5)
        address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.usesSingleLineMode = true; address.lineBreakMode = .byTruncatingTail
        address.cell?.truncatesLastVisibleLine = true
        address.translatesAutoresizingMaskIntoConstraints = false
        address.target = self; address.action = #selector(submit)
        addressWrap.addSubview(address)
        NSLayoutConstraint.activate([
            address.leadingAnchor.constraint(equalTo: addressWrap.leadingAnchor, constant: 10),
            address.trailingAnchor.constraint(equalTo: addressWrap.trailingAnchor, constant: -10),
            address.centerYAnchor.constraint(equalTo: addressWrap.centerYAnchor),
        ])

        let nav = NSStackView(views: [sidebarToggle, back, forward, reload]); nav.spacing = 1
        nav.translatesAutoresizingMaskIntoConstraints = false
        let strip = NSView(); strip.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(nav); strip.addSubview(addressWrap)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip); addSubview(content)

        let leadingConstraint = nav.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 4)
        self.navLeadingC = leadingConstraint

        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 40),
            leadingConstraint,
            nav.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            addressWrap.leadingAnchor.constraint(equalTo: nav.trailingAnchor, constant: 6),
            addressWrap.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -6),
            addressWrap.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            addressWrap.heightAnchor.constraint(equalToConstant: 30),
            content.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                                name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func setLeftSpacingForTrafficLights(_ isLeftPaneWithHiddenSidebar: Bool) {
        navLeadingC?.constant = isLeftPaneWithHiddenSidebar ? 80 : 4
    }

    func host(_ view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(view); view.pin(to: content)
    }
    func setURL(_ s: String) {
        if !isEditingTextField(address) { address.stringValue = s }
    }
    @objc private func submit() { onNavigate?(address.stringValue) }
    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = p.surface.cgColor
        addressWrap.layer?.backgroundColor = p.surface.cgColor
        address.textColor = p.text
    }
}

/// Collapsible tab-group header: carrot + colored dot + name + count.
final class GroupHeaderView: NSView, NSDraggingSource {
    var onToggle: (() -> Void)?
    var dragPayload: SidebarDragPayload?
    var onDropPayload: ((SidebarDragPayload, SidebarDropPlacement) -> Bool)?
    var menuProvider: (() -> [MenuEntry])?
    private let carrot = NSImageView()
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")

    init(name: String, count: Int, collapsed: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        carrot.translatesAutoresizingMaskIntoConstraints = false
        carrot.imageScaling = .scaleProportionallyDown
        dot.wantsLayer = true; dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = name.uppercased()
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        countLabel.stringValue = "\(count)"
        countLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [carrot, dot, nameLabel, spacer, countLabel])
        row.spacing = 7; row.alignment = .centerY
        addSubview(row); row.pin(to: self, insets: NSEdgeInsets(top: 3, left: 11, bottom: 5, right: 11))
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            dot.widthAnchor.constraint(equalToConstant: 7), dot.heightAnchor.constraint(equalToConstant: 7),
            carrot.widthAnchor.constraint(equalToConstant: 10),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        registerForDraggedTypes([breezeSidebarDragType])
        carrotCollapsed = collapsed
        apply(collapsed: collapsed)
        NotificationCenter.default.addObserver(self, selector: #selector(themed), name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    private func apply(collapsed: Bool) {
        let p = Theme.shared.palette
        carrot.image = tintedSymbol(collapsed ? "chevron.right" : "chevron.down", point: 9, weight: .semibold, color: p.textSoft)
        dot.layer?.backgroundColor = p.accent.cgColor
        nameLabel.textColor = p.textSoft
        countLabel.textColor = p.textSoft
    }
    @objc private func themed() { /* re-tint keeps current carrot dir */ apply(collapsed: carrotCollapsed) }
    private var carrotCollapsed = false
    func setCollapsed(_ c: Bool) { carrotCollapsed = c; apply(collapsed: c) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func clicked() { onToggle?() }
    override func mouseDragged(with event: NSEvent) {
        guard let dragPayload else { return }
        beginSidebarDrag(from: self, event: event, payload: dragPayload, source: self)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) != nil else { return [] }
        setSidebarDropHighlight(self, true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        setSidebarDropHighlight(self, false)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setSidebarDropHighlight(self, false)
        guard let payload = SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) else { return false }
        return onDropPayload?(payload, verticalDropPlacement(self, sender)) ?? false
    }
    override func rightMouseDown(with e: NSEvent) {
        if let entries = menuProvider?() { popupMenu(entries, for: self, with: e) }
    }
}

/// Sidebar now-playing mini-player. Deliberately NOT shaped like a tab row:
/// album-style artwork + title + "now playing" subtitle on top, with a real
/// transport-control row underneath. The transport row is what sets it apart —
/// no tab has play/pip/back controls — so it reads as its own little module in
/// the footer rather than a second selected tab.
final class NowPlayingView: NSView {
    private let art = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    let playBtn = HoverButton(symbol: "pause.fill", size: 34, point: 16)
    let pipBtn = HoverButton(symbol: "pip", size: 30, point: 14)
    let backBtn = HoverButton(symbol: "arrow.uturn.left", size: 30, point: 14)
    let dismissBtn = HoverButton(symbol: "xmark", size: 22, point: 10)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1

        art.translatesAutoresizingMaskIntoConstraints = false
        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true; art.layer?.cornerRadius = 7; art.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitle.font = .systemFont(ofSize: 10, weight: .medium)
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textCol = NSStackView(views: [titleLabel, subtitle])
        textCol.orientation = .vertical; textCol.spacing = 1; textCol.alignment = .leading

        let topRow = NSStackView(views: [art, textCol])
        topRow.spacing = 9; topRow.alignment = .centerY

        // Transport controls spread edge-to-edge: back · play/pause · pip.
        let controls = NSStackView(views: [backBtn, playBtn, pipBtn])
        controls.distribution = .equalSpacing; controls.alignment = .centerY

        let col = NSStackView(views: [topRow, controls])
        col.orientation = .vertical; col.spacing = 10; col.alignment = .leading
        addSubview(col)
        col.pin(to: self, insets: NSEdgeInsets(top: 11, left: 12, bottom: 11, right: 12))

        // Dismiss "X" in the top-right corner (hides the card; see dismissNowPlaying).
        addSubview(dismissBtn)
        NSLayoutConstraint.activate([
            dismissBtn.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            dismissBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])

        NSLayoutConstraint.activate([
            art.widthAnchor.constraint(equalToConstant: 34),
            art.heightAnchor.constraint(equalToConstant: 34),
            // Transport row spans the full inner width so the controls spread evenly;
            // the title row stops short of the dismiss button so text never runs under it.
            topRow.leadingAnchor.constraint(equalTo: col.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: col.trailingAnchor, constant: -20),
            controls.leadingAnchor.constraint(equalTo: col.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: col.trailingAnchor),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func configure(host: String, title: String, playing: Bool) {
        titleLabel.stringValue = title
        subtitle.stringValue = host.isEmpty ? "Now playing" : host
        playBtn.symbol = playing ? "pause.fill" : "play.fill"
        if !host.isEmpty {
            Favicons.shared.image(for: host) { [weak self] img in self?.art.image = img }
        }
    }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = p.surface.cgColor
        layer?.borderColor = p.text.withAlphaComponent(0.08).cgColor
        art.layer?.backgroundColor = p.surfaceActive.cgColor
        titleLabel.textColor = p.text
        subtitle.textColor = p.textSoft
    }
}

final class PinView: NSView, NSDraggingSource {
    var onSelect: (() -> Void)?
    var onUnpin: (() -> Void)?
    var dragPayload: SidebarDragPayload?
    var onDropPayload: ((SidebarDragPayload, SidebarDropPlacement) -> Bool)?
    var menuProvider: (() -> [MenuEntry])?
    private let iconView = NSImageView()
    private let letter = NSTextField(labelWithString: "")
    private var hovering = false
    let url: String

    init(pin: Pin) {
        self.url = pin.url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 13

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6

        let host = hostOf(URL(string: pin.url))
        letter.stringValue = String((pin.title.isEmpty ? host : pin.title).prefix(1)).uppercased()
        letter.font = .systemFont(ofSize: 12, weight: .bold)
        letter.textColor = .white
        letter.alignment = .center
        letter.wantsLayer = true
        letter.layer?.cornerRadius = 6
        letter.layer?.backgroundColor = Theme.shared.palette.accent.cgColor
        letter.translatesAutoresizingMaskIntoConstraints = false

        addSubview(letter); addSubview(iconView)
        // Size is enforced by the pins grid (fillEqually cell + fixed row height).
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            letter.widthAnchor.constraint(equalToConstant: 22),
            letter.heightAnchor.constraint(equalToConstant: 22),
            letter.centerXAnchor.constraint(equalTo: centerXAnchor),
            letter.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        registerForDraggedTypes([breezeSidebarDragType])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
        if !host.isEmpty {
            Favicons.shared.image(for: host) { [weak self] img in
                if let img { self?.iconView.image = img; self?.letter.isHidden = true }
            }
        }
    }
    required init?(coder: NSCoder) { nil }

    private var isOpen = false
    private var isActive = false
    func setState(open: Bool, active: Bool) { isOpen = open; isActive = active; applyTheme() }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = (hovering ? p.surfaceActive : p.surface).cgColor
        letter.layer?.backgroundColor = p.accent.cgColor
        // open pins get a soft accent ring; the active pin a full ring (matches CSS)
        if isActive {
            layer?.borderWidth = 2; layer?.borderColor = p.accent.cgColor
        } else if isOpen {
            layer?.borderWidth = 1.5
            layer?.borderColor = p.accent.withAlphaComponent(0.5).cgColor
        } else {
            layer?.borderWidth = 0
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with e: NSEvent)  { hovering = false; applyTheme() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func clicked() { onSelect?() }
    override func mouseDragged(with event: NSEvent) {
        guard let dragPayload else { return }
        beginSidebarDrag(from: self, event: event, payload: dragPayload, source: self)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) != nil else { return [] }
        setSidebarDropHighlight(self, true)
        return .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        setSidebarDropHighlight(self, false)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setSidebarDropHighlight(self, false)
        guard let payload = SidebarDragPayload.decode(sender.draggingPasteboard.string(forType: breezeSidebarDragType)) else { return false }
        return onDropPayload?(payload, horizontalDropPlacement(self, sender)) ?? false
    }

    override func rightMouseDown(with e: NSEvent) {
        if let entries = menuProvider?() { popupMenu(entries, for: self, with: e) }
    }
}

/// Sidebar reminders container: vertical stack of active reminders.
final class RemindersView: NSStackView {
    var onCancelReminder: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        spacing = 4
        alignment = .leading
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    func update(_ list: [[String: Any]]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = list.isEmpty
        
        let p = Theme.shared.palette
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        
        for r in list {
            guard let id = r["id"] as? String else { continue }
            let label = r["label"] as? String ?? "Reminder"
            let fireAt = r["fireAt"] as? Double ?? 0
            let targetDate = Date(timeIntervalSince1970: fireAt / 1000.0)
            
            let row = NSView()
            row.wantsLayer = true
            row.layer?.cornerRadius = 13
            row.layer?.backgroundColor = p.surface.cgColor
            row.translatesAutoresizingMaskIntoConstraints = false
            
            let clock = NSImageView()
            clock.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            clock.contentTintColor = p.textSoft
            clock.translatesAutoresizingMaskIntoConstraints = false
            
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 11)
            lbl.textColor = p.text
            lbl.lineBreakMode = .byTruncatingTail
            lbl.translatesAutoresizingMaskIntoConstraints = false
            
            let timeLbl = NSTextField(labelWithString: df.string(from: targetDate))
            timeLbl.font = .systemFont(ofSize: 9.5)
            timeLbl.textColor = p.textSoft
            timeLbl.translatesAutoresizingMaskIntoConstraints = false
            
            let cancelBtn = HoverButton(symbol: "xmark", size: 18, point: 8)
            cancelBtn.onTap = { [weak self] in self?.onCancelReminder?(id) }
            cancelBtn.translatesAutoresizingMaskIntoConstraints = false
            
            row.addSubview(clock)
            row.addSubview(lbl)
            row.addSubview(timeLbl)
            row.addSubview(cancelBtn)

            // The row and reminders stack must share a view hierarchy before
            // activating the width constraint between them.
            addArrangedSubview(row)
            
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 26),
                row.widthAnchor.constraint(equalTo: widthAnchor),
                
                clock.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
                clock.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                clock.widthAnchor.constraint(equalToConstant: 12),
                clock.heightAnchor.constraint(equalToConstant: 12),
                
                lbl.leadingAnchor.constraint(equalTo: clock.trailingAnchor, constant: 4),
                lbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                lbl.trailingAnchor.constraint(equalTo: timeLbl.leadingAnchor, constant: -4),
                
                timeLbl.trailingAnchor.constraint(equalTo: cancelBtn.leadingAnchor, constant: -4),
                timeLbl.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                
                cancelBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
                cancelBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
            
        }
    }
}
