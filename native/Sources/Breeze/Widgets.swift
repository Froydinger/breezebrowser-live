// Small reusable AppKit widgets styled to match ui/style.css.

import Cocoa

final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Compact, non-modal offer shown when the current site also has an installed
/// Safari web app. Breeze remains the default destination; the app opens only
/// after an explicit click.
final class WebAppOfferView: NSVisualEffectView {
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let appIcon = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let closeButton = HoverButton(symbol: "xmark", size: 24, point: 10)

    init(appName: String, icon: NSImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.borderWidth = 1
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 16
        layer?.shadowOffset = NSSize(width: 0, height: -5)

        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.image = icon
        appIcon.imageScaling = .scaleProportionallyUpOrDown

        message.translatesAutoresizingMaskIntoConstraints = false
        message.stringValue = "\(appName) is installed for this site."
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.lineBreakMode = .byTruncatingTail

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.title = "Open in \(appName)"
        openButton.bezelStyle = .rounded
        openButton.controlSize = .regular
        openButton.target = self
        openButton.action = #selector(openTapped)

        closeButton.onTap = { [weak self] in self?.onDismiss?() }

        addSubview(appIcon)
        addSubview(message)
        addSubview(openButton)
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            widthAnchor.constraint(lessThanOrEqualToConstant: 540),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 390),
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            appIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 32),
            appIcon.heightAnchor.constraint(equalToConstant: 32),
            message.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor, constant: 10),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 14),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: openButton.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func openTapped() { onOpen?() }

    @objc private func applyTheme() {
        let p = Theme.shared.palette
        layer?.borderColor = p.accent.withAlphaComponent(p.isDark ? 0.34 : 0.22).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        message.textColor = p.text
        openButton.bezelColor = p.accent
        openButton.contentTintColor = .white
    }
}

/// Painted gradient background matching `body` in style.css:
/// a 7% accent wash over the 160° bg gradient.
class GradientBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func themeChanged() { needsDisplay = true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer = layer else { return }
        let p = Theme.shared.palette
        let g = CAGradientLayer()
        g.frame = bounds
        g.colors = [p.bgTop.cgColor, p.bg.cgColor, p.bgBottom.cgColor]
        g.locations = [0, 0.55, 1]
        g.startPoint = CGPoint(x: 0.1, y: 1)     // ~160deg
        g.endPoint = CGPoint(x: 0.9, y: 0)
        layer.sublayers?.removeAll(where: { $0.name == "bgGrad" || $0.name == "accentWash" })
        g.name = "bgGrad"
        layer.insertSublayer(g, at: 0)
        let wash = CALayer()
        wash.frame = bounds
        // The window-wide accent wash. In dark mode this 12% teal sat over every
        // surface - chrome, sidebar, new tab - which is what made "dark" read as
        // dark teal rather than black. Neutral in dark, accent tint kept in light.
        wash.backgroundColor = p.isDark
            ? NSColor(white: 1, alpha: 0.015).cgColor
            : p.accent.withAlphaComponent(0.12).cgColor
        wash.name = "accentWash"
        layer.insertSublayer(wash, above: g)
    }
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { if $0.name == "bgGrad" || $0.name == "accentWash" { $0.frame = bounds } }
    }
}

/// Render an SF Symbol tinted to an explicit color (baked in, not template) so it
/// always shows regardless of the control's default tinting behavior.
func tintedSymbol(_ name: String, point: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: point, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let img = NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
    img.isTemplate = false
    return img
}

func isEditingTextField(_ field: NSTextField) -> Bool {
    guard let editor = field.window?.firstResponder as? NSTextView else { return false }
    return (editor.delegate as AnyObject?) === field
}

/// A 30×30 (configurable) icon button with hover background — the `.nav-btn` look.
final class HoverButton: NSButton {
    var diameter: CGFloat = 30
    var symbol: String = "" { didSet { applyTheme() } }
    var symbolWeight: NSFont.Weight = .regular
    var pointSize: CGFloat = 15
    var isOn = false { didSet { applyTheme() } }
    private var hovering = false
    var onTap: (() -> Void)?
    private var widthC: NSLayoutConstraint!
    private var heightC: NSLayoutConstraint!

    /// Grow or shrink the button in place. The sidebar's command tile uses this so
    /// a narrow sidebar scales its icons down instead of cramming them together.
    func resize(diameter d: CGFloat, point: CGFloat) {
        guard d != diameter || point != pointSize else { return }
        diameter = d
        pointSize = point
        widthC.constant = d
        heightC.constant = d
        applyTheme()
    }

    init(symbol: String, size: CGFloat = 30, point: CGFloat = 15) {
        super.init(frame: .zero)
        self.diameter = size; self.pointSize = point
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = size / 2
        imagePosition = .imageOnly
        target = self; action = #selector(tapped)
        self.symbol = symbol
        widthC = widthAnchor.constraint(equalToConstant: diameter)
        heightC = heightAnchor.constraint(equalToConstant: diameter)
        widthC.isActive = true
        heightC.isActive = true
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.3 } }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        let color = isOn ? p.accent : (hovering ? p.text : p.textSoft)
        image = tintedSymbol(symbol, point: pointSize, weight: symbolWeight, color: color)
        layer?.backgroundColor = (isOn ? p.surfaceActive : (hovering ? p.surfaceHover : .clear)).cgColor
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
    @objc private func tapped() { onTap?() }

    func spinGlyph() {
        guard let currentImage = image, let hostLayer = layer else { return }
        hostLayer.sublayers?.removeAll { $0.name == "breezeReloadSpinner" }
        subviews.filter { $0.identifier?.rawValue == "breezeReloadSpinner" }.forEach { $0.removeFromSuperview() }
        layoutSubtreeIfNeeded()
        let side = max(pointSize + 5, 18)
        var proposed = CGRect(origin: .zero, size: CGSize(width: side, height: side))
        guard let cgImage = currentImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        image = nil
        let spinner = CALayer()
        spinner.name = "breezeReloadSpinner"
        spinner.contents = cgImage
        spinner.contentsGravity = .resizeAspect
        spinner.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spinner.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
        hostLayer.addSublayer(spinner)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 0.42
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak spinner] in
            spinner?.removeFromSuperlayer()
            self?.applyTheme()
        }
        spinner.add(animation, forKey: "breezeReloadSpin")
        CATransaction.commit()
    }
}

final class HoverTextButton: NSButton {
    var defaultText: String
    var hoverText: String
    private var hovering = false
    var onTap: (() -> Void)?

    init(defaultText: String, hoverText: String) {
        self.defaultText = defaultText
        self.hoverText = hoverText
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 12
        target = self; action = #selector(tapped)
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        let color = hovering ? p.text : p.textSoft.withAlphaComponent(0.3)
        let titleStr = hovering ? hoverText : defaultText
        attributedTitle = NSAttributedString(string: titleStr, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ])
        layer?.backgroundColor = (hovering ? p.surfaceHover : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; applyTheme() }
    override func mouseExited(with e: NSEvent)  { hovering = false; applyTheme() }
    @objc private func tapped() { onTap?() }
}

final class LinePlusButton: NSButton {
    private var hovering = false
    var onTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        attributedTitle = NSAttributedString(string: "")
        alternateTitle = ""
        image = nil
        imagePosition = .noImage
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 12
        target = self
        action = #selector(tapped)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    @objc private func themeChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = Theme.shared.palette.surfaceHover.cgColor
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let p = Theme.shared.palette
        let color = hovering ? p.text.withAlphaComponent(0.68) : p.text.withAlphaComponent(0.5)
        color.setStroke()
        color.setFill()
        let y = bounds.midY
        let centerGap: CGFloat = 18
        let lineLength = max(18, (bounds.midX - centerGap - 18) * 0.36)
        let left = NSBezierPath()
        left.lineWidth = 1.5
        left.lineCapStyle = .round
        left.move(to: NSPoint(x: bounds.midX - centerGap - lineLength, y: y))
        left.line(to: NSPoint(x: bounds.midX - centerGap, y: y))
        left.stroke()
        let right = NSBezierPath()
        right.lineWidth = 1.5
        right.lineCapStyle = .round
        right.move(to: NSPoint(x: bounds.midX + centerGap, y: y))
        right.line(to: NSPoint(x: bounds.midX + centerGap + lineLength, y: y))
        right.stroke()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: bounds.midX - 3.5, y: y))
        plus.line(to: NSPoint(x: bounds.midX + 3.5, y: y))
        plus.move(to: NSPoint(x: bounds.midX, y: y - 3.5))
        plus.line(to: NSPoint(x: bounds.midX, y: y + 3.5))
        plus.stroke()
    }

    @objc private func tapped() { onTap?() }
}
/// Top-left origin view so scroll-view content starts at the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Thin draggable column divider — shows the left-right resize cursor.
final class ColumnResizeView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    // don't let isMovableByWindowBackground steal the drag — we resize instead
    override var mouseDownCanMoveWindow: Bool { false }
}

/// NSView that reports mouse enter/exit — used for the sidebar edge-peek.
final class HoverReportView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with e: NSEvent) { onEnter?() }
    override func mouseExited(with e: NSEvent)  { onExit?() }
}

/// NSMenuItem that runs a closure when chosen.
final class BlockMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not supported") }
    @objc private func fire() { handler() }
}

enum MenuEntry {
    case item(String, () -> Void)
    case check(String, Bool, () -> Void)     // checkbox item
    case disabled(String)
    case submenu(String, [MenuEntry])
    case separator
}

func buildMenu(_ entries: [MenuEntry]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in entries {
        switch entry {
        case .item(let title, let action):
            menu.addItem(BlockMenuItem(title, action))
        case .check(let title, let checked, let action):
            let it = BlockMenuItem(title, action); it.state = checked ? .on : .off
            menu.addItem(it)
        case .disabled(let title):
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.isEnabled = false
            menu.addItem(it)
        case .submenu(let title, let sub):
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = buildMenu(sub)
            menu.addItem(it)
        case .separator:
            menu.addItem(.separator())
        }
    }
    return menu
}

extension NSMenu {
    @discardableResult
    func addTargetedItem(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}

/// Build and pop up a context menu at the event location.
func popupMenu(_ entries: [MenuEntry], for view: NSView, with event: NSEvent) {
    NSMenu.popUpContextMenu(buildMenu(entries), with: event, for: view)
}

extension NSView {
    func pin(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }
}

final class TabPlaceholderView: NSView {
    var onPull: (() -> Void)?
    
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        
        let box = NSStackView()
        box.orientation = .vertical
        box.spacing = 16
        box.alignment = .centerX
        box.translatesAutoresizingMaskIntoConstraints = false
        
        let text = NSTextField(labelWithString: "This tab is active in another window.")
        text.font = .systemFont(ofSize: 14.5, weight: .medium)
        text.textColor = Theme.shared.palette.textSoft
        text.translatesAutoresizingMaskIntoConstraints = false
        
        let pullBtn = NSButton(title: "Pull Tab Here", target: self, action: #selector(tapped))
        pullBtn.bezelStyle = .rounded
        pullBtn.font = .systemFont(ofSize: 13, weight: .medium)
        pullBtn.translatesAutoresizingMaskIntoConstraints = false
        
        box.addArrangedSubview(text)
        box.addArrangedSubview(pullBtn)
        addSubview(box)
        
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: centerXAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: Theme.didChange, object: nil)
        applyTheme()
    }
    
    required init?(coder: NSCoder) { nil }
    
    @objc func tapped() {
        onPull?()
    }
    
    @objc func applyTheme() {
        layer?.backgroundColor = Theme.shared.palette.bg.cgColor
    }
}

final class SelectableMessageTextView: NSTextField {
    private var maxWidth: CGFloat

    init(maxWidth: CGFloat) {
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        configure()
    }

    override init(frame frameRect: NSRect) {
        self.maxWidth = max(1, frameRect.width)
        super.init(frame: frameRect)
        configure()
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    var attributedString: NSAttributedString {
        get { attributedStringValue }
        set {
            attributedStringValue = newValue
            invalidateIntrinsicContentSize()
        }
    }

    func updateMaxWidth(_ width: CGFloat) {
        maxWidth = max(1, width)
        preferredMaxLayoutWidth = maxWidth
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let rect = attributedStringValue.boundingRect(
            with: NSSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: maxWidth, height: max(ceil(rect.height), 18))
    }
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}

/// The sidebar's command tile: the browser-level actions (settings, theme,
/// history, bookmarks, downloads) grouped on one surface with the time and date,
/// instead of a loose row of icons floating at the bottom of the sidebar.
///
/// It owns its own scaling. The sidebar is user-resizable and five fixed 30pt
/// buttons stop fitting well before the sidebar reaches its minimum, so the icons
/// shrink with the available width rather than colliding or being clipped. The
/// time and date are inset to line up with the icon glyphs below them, not with
/// the buttons' invisible hit circles.
final class CommandTile: NSView {
    private let row = NSStackView()
    private let buttons: [HoverButton]
    let timeLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "·")
    private let meta = NSStackView()
    private var metaLeading: NSLayoutConstraint!
    var onTimeTap: (() -> Void)?
    var onDateTap: (() -> Void)?

    init(buttons: [HoverButton]) {
        self.buttons = buttons
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 13

        for (label, sel) in [(timeLabel, #selector(timeTapped)), (dateLabel, #selector(dateTapped))] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: sel))
        }
        dot.font = .systemFont(ofSize: 11, weight: .medium)
        dot.stringValue = "·"
        timeLabel.toolTip = "Reminders"
        dateLabel.toolTip = "Today's news"

        meta.orientation = .horizontal
        meta.alignment = .firstBaseline
        meta.spacing = 5
        meta.translatesAutoresizingMaskIntoConstraints = false
        [timeLabel, dot, dateLabel].forEach { meta.addArrangedSubview($0) }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        buttons.forEach { row.addArrangedSubview($0) }

        addSubview(meta); addSubview(row)
        metaLeading = meta.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17)
        NSLayoutConstraint.activate([
            metaLeading,
            meta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            meta.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: meta.bottomAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        applyTheme()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func timeTapped() { onTimeTap?() }
    @objc private func dateTapped() { onDateTap?() }

    override func layout() {
        super.layout()
        let available = bounds.width - 20
        guard available > 0, !buttons.isEmpty else { return }
        let perButton = available / CGFloat(buttons.count)
        let diameter = max(22, min(30, perButton - 4))
        let point = max(11.5, min(15, diameter * 0.5))
        buttons.forEach { $0.resize(diameter: diameter, point: point) }
        // A button's glyph is centred in its circle, so the text has to start
        // half the leftover width in to look aligned with the icon beneath it.
        metaLeading.constant = 10 + max(0, (diameter - point) / 2)
        // Below a certain width the date stops fitting next to the time.
        let tight = bounds.width < 150
        dot.isHidden = tight
        dateLabel.isHidden = tight
    }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = p.text.withAlphaComponent(p.isDark ? 0.045 : 0.035).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = p.text.withAlphaComponent(p.isDark ? 0.07 : 0.06).cgColor
        let soft = p.text.withAlphaComponent(p.isDark ? 0.42 : 0.45)
        [timeLabel, dateLabel, dot].forEach { $0.textColor = soft }
    }
}
