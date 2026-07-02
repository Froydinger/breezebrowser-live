// Small reusable AppKit widgets styled to match ui/style.css.

import Cocoa

final class PassthroughVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Painted gradient background matching `body` in style.css:
/// a 7% accent wash over the 160° bg gradient.
class GradientBackgroundView: NSView {
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
        wash.backgroundColor = p.accent.withAlphaComponent(0.12).cgColor
        wash.name = "accentWash"
        layer.insertSublayer(wash, above: g)
    }
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { if $0.name == "bgGrad" || $0.name == "accentWash" { $0.frame = bounds } }
    }
}

/// Paints only the four pixels-outside-a-rounded-rect corner wedges. This gives
/// the web area rounded visual corners without clipping WKWebView or any ancestor
/// of its hardware video layer (which breaks element fullscreen on macOS).
final class RoundedContentOverlayView: NSView {
    let radius: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // The corner mask is expressed in this view's bounds. Rebuild it when a
        // normal window is maximized/restored so the new outer edges stay round.
        if changed { needsDisplay = true }
    }

    @objc private func refresh() { needsDisplay = true }

    override func updateLayer() {
        guard let layer else { return }
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let p = Theme.shared.palette
        let clippedGradient = CALayer()
        clippedGradient.frame = bounds

        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [p.bgTop.cgColor, p.bg.cgColor, p.bgBottom.cgColor]
        gradient.locations = [0, 0.55, 1]
        gradient.startPoint = CGPoint(x: 0.1, y: 1)
        gradient.endPoint = CGPoint(x: 0.9, y: 0)
        clippedGradient.addSublayer(gradient)

        let wash = CALayer()
        wash.frame = bounds
        wash.backgroundColor = p.accent.withAlphaComponent(0.12).cgColor
        clippedGradient.addSublayer(wash)

        let outsideCorners = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        outsideCorners.path = path
        outsideCorners.fillRule = .evenOdd
        outsideCorners.fillColor = NSColor.black.cgColor
        clippedGradient.mask = outsideCorners
        layer.addSublayer(clippedGradient)
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
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
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
