// Small reusable AppKit widgets styled to match ui/style.css.

import Cocoa

/// Painted gradient background matching `body` in style.css:
/// a 7% accent wash over the 160° bg gradient.
final class GradientBackgroundView: NSView {
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
        layer.sublayers?.removeAll(where: { $0.name == "bgGrad" })
        g.name = "bgGrad"
        layer.insertSublayer(g, at: 0)
    }
    override func layout() { super.layout(); needsDisplay = true
        layer?.sublayers?.first(where: { $0.name == "bgGrad" })?.frame = bounds }
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

/// A 30×30 (configurable) icon button with hover background — the `.nav-btn` look.
final class HoverButton: NSButton {
    var diameter: CGFloat = 30
    var radius: CGFloat = 8
    var symbol: String = "" { didSet { applyTheme() } }
    var symbolWeight: NSFont.Weight = .regular
    var pointSize: CGFloat = 15
    private var hovering = false
    var onTap: (() -> Void)?

    init(symbol: String, size: CGFloat = 30, point: CGFloat = 15) {
        super.init(frame: .zero)
        self.diameter = size; self.pointSize = point
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = radius
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

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.3 } }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        let color = hovering ? p.text : p.textSoft
        image = tintedSymbol(symbol, point: pointSize, weight: symbolWeight, color: color)
        layer?.backgroundColor = (hovering ? p.surfaceHover : .clear).cgColor
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
}

/// Top-left origin view so scroll-view content starts at the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

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
    case separator
}

/// Build and pop up a context menu at the event location.
func popupMenu(_ entries: [MenuEntry], for view: NSView, with event: NSEvent) {
    let menu = NSMenu()
    for entry in entries {
        switch entry {
        case .item(let title, let action): menu.addItem(BlockMenuItem(title, action))
        case .separator: menu.addItem(.separator())
        }
    }
    NSMenu.popUpContextMenu(menu, with: event, for: view)
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
