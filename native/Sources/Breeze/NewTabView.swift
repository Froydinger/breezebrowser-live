// Native new-tab page: logo + clock + greeting + "Ask Breeze, or type a URL".
// Ports ui/newtab.html. No perpetual animation (per project rule) — the orbs are
// static. A 1s clock timer is fine (not a busy loop) and pauses when hidden.

import Cocoa
import CoreImage

func breezeBaseLogo() -> NSImage? {
    if let img = Bundle.main.image(forResource: "icon") { return img }
    // dev fallback when run via `swift run` (no app bundle): repo icon.png
    for p in ["../icon.png", "icon.png", "../ui/icon.png"] {
        if let img = NSImage(contentsOfFile: p) { return img }
    }
    return nil
}

func breezeLogo() -> NSImage? {
    guard let base = breezeBaseLogo() else { return nil }
    return themedLogo(base)
}

func themedLogo(_ base: NSImage) -> NSImage {
    guard let data = base.tiffRepresentation,
          let input = CIImage(data: data),
          let filter = CIFilter(name: "CIColorMonochrome") else { return base }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(CIColor(color: Theme.shared.palette.accent), forKey: kCIInputColorKey)
    filter.setValue(1.0, forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage else { return base }
    let rep = NSCIImageRep(ciImage: output)
    let tinted = NSImage(size: rep.size)
    tinted.addRepresentation(rep)
    tinted.isTemplate = false
    return tinted
}

func navLogo() -> NSImage? {
    if let img = Bundle.main.image(forResource: "nav-icon") { return themedLogo(img) }
    for p in ["../nav-icon.png", "nav-icon.png", "../ui/nav-icon.png"] {
        if let img = NSImage(contentsOfFile: p) { return themedLogo(img) }
    }
    let size = NSSize(width: 256, height: 256)
    let accent = Theme.shared.palette.accent.usingColorSpace(.sRGB) ?? Theme.shared.palette.accent
    let top = accent.blended(withFraction: 0.28, of: .white) ?? accent
    let bottom = accent.blended(withFraction: 0.32, of: .black) ?? accent
    let img = NSImage(size: size, flipped: false) { rect in
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 24
        shadow.set()
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 10, dy: 10))
        NSGradient(colors: [top, bottom])?.draw(in: circle, angle: -38)
        NSGraphicsContext.restoreGraphicsState()

        if let symbol = tintedSymbol("location.north.fill", point: 112, weight: .semibold, color: .white) {
            symbol.draw(in: NSRect(x: 72, y: 58, width: 112, height: 136),
                        from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 128, y: 202))
            path.line(to: NSPoint(x: 180, y: 54))
            path.line(to: NSPoint(x: 128, y: 88))
            path.line(to: NSPoint(x: 76, y: 54))
            path.close()
            NSColor.white.setFill()
            path.fill()
        }
        return true
    }
    img.isTemplate = false
    return img
}

final class NewTabView: NSView {
    private let baseFieldHeight: CGFloat = 54
    private let maxFieldLines = 4
    private let logo = NSImageView()
    private let clock = NSTextField(labelWithString: "--:--")
    private let greeting = NSTextField(labelWithString: "")
    let field = NSTextField()
    var onSubmit: ((String, Bool) -> Void)?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        logo.image = breezeLogo()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false

        clock.font = .systemFont(ofSize: 72, weight: .ultraLight)
        clock.alignment = .center
        clock.translatesAutoresizingMaskIntoConstraints = false

        greeting.font = .systemFont(ofSize: 15)
        greeting.alignment = .center
        greeting.translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = "Ask Breeze, or type a URL"
        field.font = .systemFont(ofSize: 16)
        field.alignment = .left
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submit)
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = false
            cell.wraps = true
            cell.lineBreakMode = .byWordWrapping
        }

        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 27
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)

        addSubview(logo); addSubview(clock); addSubview(greeting); addSubview(fieldWrap)
        let widthC = fieldWrap.widthAnchor.constraint(equalToConstant: 560)
        widthC.priority = .defaultHigh
        let maxC = fieldWrap.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        maxC.priority = .required

        fieldHeightConstraint = fieldWrap.heightAnchor.constraint(equalToConstant: baseFieldHeight)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 64),
            logo.heightAnchor.constraint(equalToConstant: 64),
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.bottomAnchor.constraint(equalTo: clock.topAnchor, constant: 6),

            clock.centerXAnchor.constraint(equalTo: centerXAnchor),
            clock.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),

            greeting.centerXAnchor.constraint(equalTo: centerXAnchor),
            greeting.topAnchor.constraint(equalTo: clock.bottomAnchor, constant: 2),

            fieldWrap.centerXAnchor.constraint(equalTo: centerXAnchor),
            fieldWrap.topAnchor.constraint(equalTo: greeting.bottomAnchor, constant: 26),
            widthC,
            maxC,
            fieldHeightConstraint,

            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -22),
            field.topAnchor.constraint(equalTo: fieldWrap.topAnchor, constant: 16),
            field.bottomAnchor.constraint(equalTo: fieldWrap.bottomAnchor, constant: -16),
        ])
        self.fieldWrap = fieldWrap
        applyTheme(); tick()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    private var fieldWrap: NSView!
    private var fieldHeightConstraint: NSLayoutConstraint!

    override func layout() {
        super.layout()
        updateFieldHeight()
    }

    func updateFieldHeight() {
        guard fieldHeightConstraint != nil else { return }
        let text = field.stringValue.isEmpty ? " " : field.stringValue
        let font = field.font ?? .systemFont(ofSize: 16)
        let availableWidth = max(field.bounds.width, fieldWrap.bounds.width - 44, 1)
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let lines = min(max(Int(ceil(measured.height / lineHeight)), 1), maxFieldLines)
        let desiredHeight = baseFieldHeight + CGFloat(lines - 1) * lineHeight
        if abs(fieldHeightConstraint.constant - desiredHeight) > 0.5 {
            fieldHeightConstraint.constant = desiredHeight
        }
    }

    @objc func applyTheme() {
        let p = Theme.shared.palette
        logo.image = breezeLogo()
        clock.textColor = p.text
        greeting.textColor = p.textSoft
        field.textColor = p.text
        fieldWrap.layer?.backgroundColor = p.surface.cgColor
        fieldWrap.layer?.shadowColor = NSColor.black.cgColor
        fieldWrap.layer?.shadowOpacity = p.isDark ? 0.25 : 0.08
        fieldWrap.layer?.shadowRadius = 18
        fieldWrap.layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    func tick() {
        let now = Date()
        let f = DateFormatter(); f.dateFormat = Store.shared.bool("clock24") ? "H:mm" : "h:mm"
        clock.stringValue = f.string(from: now)
        let h = Calendar.current.component(.hour, from: now)
        greeting.stringValue = h < 12 ? "Good morning." : (h < 18 ? "Good afternoon." : "Good evening.")
        greeting.isHidden = !Store.shared.bool("showGreeting")
    }

    func startClock() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }
    func stopClock() { timer?.invalidate(); timer = nil }

    @objc private func submit() {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        field.stringValue = ""
        updateFieldHeight()
        let isCmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        // Defer out of the field editor's textDidEndEditing/_giveUpFirstResponder
        // teardown. Submitting routes to navigate()/the chat path, which calls
        // showActive() and removes THIS view (whose field editor is still mid-
        // teardown) from the window. Mutating the hierarchy reentrantly here
        // corrupts the window's first-responder/field-editor state and crashes
        // with a use-after-free in applyChromeTheme(). One runloop turn later the
        // text system has fully unwound, so it's safe to tear the view down.
        DispatchQueue.main.async { [weak self] in self?.onSubmit?(t, isCmd) }
    }
}
