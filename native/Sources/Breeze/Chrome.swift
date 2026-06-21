// Sidebar item views: tab rows and pins. Styled from ui/style.css (.tab / .pin).

import Cocoa

final class TabRowView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var menuProvider: (() -> [MenuEntry])?     // controller builds the full menu
    private let faviconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let close = HoverButton(symbol: "xmark", size: 20, point: 9)
    private let perfBadge = NSTextField(labelWithString: "🚀")
    private var active: Bool
    private var hovering = false

    init(title: String, host: String, active: Bool, perf: Bool = false, asleep: Bool = false) {
        self.active = active
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyDown
        faviconView.wantsLayer = true
        faviconView.layer?.cornerRadius = 4
        faviconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        close.onTap = { [weak self] in self?.onClose?() }
        close.alphaValue = 0
        perfBadge.font = .systemFont(ofSize: 11)
        perfBadge.translatesAutoresizingMaskIntoConstraints = false
        perfBadge.isHidden = !perf
        perfBadge.toolTip = "Performance Mode on"

        addSubview(faviconView); addSubview(titleLabel); addSubview(perfBadge); addSubview(close)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: faviconView.trailingAnchor, constant: 9),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: perfBadge.leadingAnchor, constant: -4),
            perfBadge.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            perfBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
        if !host.isEmpty {
            Favicons.shared.image(for: host) { [weak self] img in if let img { self?.faviconView.image = img } }
        }
        if asleep { faviconView.alphaValue = 0.5; titleLabel.alphaValue = 0.55 }   // dimmed when sleeping
    }
    required init?(coder: NSCoder) { nil }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        titleLabel.textColor = p.text
        let bg: NSColor = active ? p.surfaceActive : (hovering ? p.surfaceHover : .clear)
        layer?.backgroundColor = bg.cgColor
        if active {
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = p.isDark ? 0.25 : 0.06
            layer?.shadowRadius = 8; layer?.shadowOffset = CGSize(width: 0, height: -2)
        } else { layer?.shadowOpacity = 0 }
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
        if !perfBadge.isHidden { perfBadge.animator().alphaValue = 0 }
        applyTheme()
    }
    override func mouseExited(with e: NSEvent) {
        hovering = false; close.animator().alphaValue = 0
        if !perfBadge.isHidden { perfBadge.animator().alphaValue = 1 }
        applyTheme()
    }
    @objc private func clicked() { onSelect?() }

    override func rightMouseDown(with e: NSEvent) {
        if let entries = menuProvider?() { popupMenu(entries, for: self, with: e) }
    }
}

/// One split-view pane: its own URL-bar strip (back/fwd/reload + address) over a
/// hosted web view. Mirrors the Electron per-pane split-bar.
final class SplitPane: NSView {
    let back = HoverButton(symbol: "chevron.left", size: 26, point: 13)
    let forward = HoverButton(symbol: "chevron.right", size: 26, point: 13)
    let reload = HoverButton(symbol: "arrow.clockwise", size: 26, point: 12)
    let address = NSTextField()
    private let addressWrap = NSView()
    let content = NSView()
    var onNavigate: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.masksToBounds = true; layer?.cornerRadius = 10

        addressWrap.wantsLayer = true; addressWrap.layer?.cornerRadius = 9
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

        let nav = NSStackView(views: [back, forward, reload]); nav.spacing = 1
        nav.translatesAutoresizingMaskIntoConstraints = false
        let strip = NSView(); strip.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(nav); strip.addSubview(addressWrap)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip); addSubview(content)
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 40),
            nav.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 4),
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

    func host(_ view: NSView) {
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(view); view.pin(to: content)
    }
    func setURL(_ s: String) {
        if window?.firstResponder !== address.currentEditor() { address.stringValue = s }
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
final class GroupHeaderView: NSView {
    var onToggle: (() -> Void)?
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
    @objc private func clicked() { onToggle?() }
}

/// Sidebar now-playing card: favicon + title + play/pause + pip + back-to-tab.
final class NowPlayingView: NSView {
    private let fav = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    let playBtn = HoverButton(symbol: "pause.fill", size: 26, point: 12)
    let pipBtn = HoverButton(symbol: "pip", size: 26, point: 12)
    let backBtn = HoverButton(symbol: "arrow.uturn.left", size: 26, point: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        fav.translatesAutoresizingMaskIntoConstraints = false
        fav.imageScaling = .scaleProportionallyDown
        fav.wantsLayer = true; fav.layer?.cornerRadius = 4
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [fav, titleLabel, playBtn, pipBtn, backBtn])
        row.spacing = 6; row.alignment = .centerY
        addSubview(row); row.pin(to: self, insets: NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9))
        NSLayoutConstraint.activate([
            fav.widthAnchor.constraint(equalToConstant: 16),
            fav.heightAnchor.constraint(equalToConstant: 16),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    func configure(host: String, title: String, playing: Bool) {
        titleLabel.stringValue = title
        playBtn.symbol = playing ? "pause.fill" : "play.fill"
        if !host.isEmpty {
            Favicons.shared.image(for: host) { [weak self] img in self?.fav.image = img }
        }
    }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = p.surface.cgColor
        titleLabel.textColor = p.text
    }
}

final class PinView: NSView {
    var onSelect: (() -> Void)?
    var onUnpin: (() -> Void)?
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
    @objc private func clicked() { onSelect?() }

    override func rightMouseDown(with e: NSEvent) {
        if let entries = menuProvider?() { popupMenu(entries, for: self, with: e) }
    }
}
