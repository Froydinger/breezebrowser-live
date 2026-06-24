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
    let rawAccent = Store.shared.string("accent").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if rawAccent == Theme.monoAccent { return themedLogo(base) }
    if rawAccent.isEmpty || rawAccent == Theme.defaultAccent { return base }
    return navTintedLogo(base, color: Theme.shared.palette.accent)
}

func themedLogo(_ base: NSImage) -> NSImage {
    themedLogo(base, color: Theme.shared.palette.accent)
}

func themedLogo(_ base: NSImage, color: NSColor) -> NSImage {
    guard let data = base.tiffRepresentation,
          let input = CIImage(data: data),
          let filter = CIFilter(name: "CIColorMonochrome") else { return base }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(CIColor(color: color), forKey: kCIInputColorKey)
    filter.setValue(1.0, forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage else { return base }
    let rep = NSCIImageRep(ciImage: output)
    let tinted = NSImage(size: rep.size)
    tinted.addRepresentation(rep)
    tinted.isTemplate = false
    return tinted
}

func navTintedLogo(_ base: NSImage, color: NSColor) -> NSImage {
    guard let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let target = color.usingColorSpace(.deviceRGB) else { return themedLogo(base, color: color) }
    let width = cg.width
    let height = cg.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

    let targetHue = hue(of: target)
    for y in 0..<height {
        for x in 0..<width {
            let i = y * bytesPerRow + x * 4
            let alpha = CGFloat(pixels[i + 3]) / 255
            if alpha <= 0.02 { continue }
            let r = CGFloat(pixels[i]) / 255
            let g = CGFloat(pixels[i + 1]) / 255
            let b = CGFloat(pixels[i + 2]) / 255
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let isWhitePaper = minC > 0.72 && (maxC - minC) < 0.20
            if isWhitePaper { continue }

            let (_, sat, bri) = hsb(r, g, b)
            let darkerBrightness = min(0.82, max(0.32, bri * 0.72))
            let richerSaturation = min(0.86, max(0.46, sat * 0.92))
            let c = NSColor(calibratedHue: targetHue, saturation: richerSaturation, brightness: darkerBrightness, alpha: alpha)
                .usingColorSpace(.deviceRGB) ?? target
            pixels[i] = UInt8(clamping: Int(round(c.redComponent * 255)))
            pixels[i + 1] = UInt8(clamping: Int(round(c.greenComponent * 255)))
            pixels[i + 2] = UInt8(clamping: Int(round(c.blueComponent * 255)))
        }
    }

    guard let out = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage() else { return base }
    let img = NSImage(size: NSSize(width: width, height: height))
    img.addRepresentation(NSBitmapImageRep(cgImage: out))
    img.isTemplate = false
    return img
}

private func hsb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let maxC = max(r, g, b), minC = min(r, g, b)
    let delta = maxC - minC
    var h: CGFloat = 0
    if delta > 0 {
        if maxC == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = ((b - r) / delta) + 2 }
        else { h = ((r - g) / delta) + 4 }
        h /= 6
        if h < 0 { h += 1 }
    }
    return (h, maxC == 0 ? 0 : delta / maxC, maxC)
}

private func hue(of color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.deviceRGB) ?? color
    return hsb(c.redComponent, c.greenComponent, c.blueComponent).0
}

func navLogo() -> NSImage? {
    let accent = Theme.shared.palette.accent
    let rawAccent = Store.shared.string("accent").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let tint = rawAccent == Theme.monoAccent ? accent : (accent.blended(withFraction: 0.36, of: .black) ?? accent)
    if let img = Bundle.main.image(forResource: "nav-icon") {
        if rawAccent == Theme.monoAccent { return themedLogo(img, color: tint) }
        if rawAccent.isEmpty || rawAccent == Theme.defaultAccent { return img }
        return navTintedLogo(img, color: tint)
    }
    for p in ["../nav-icon.png", "nav-icon.png", "../ui/nav-icon.png"] {
        if let img = NSImage(contentsOfFile: p) {
            if rawAccent == Theme.monoAccent { return themedLogo(img, color: tint) }
            if rawAccent.isEmpty || rawAccent == Theme.defaultAccent { return img }
            return navTintedLogo(img, color: tint)
        }
    }
    let size = NSSize(width: 256, height: 256)
    let fallbackAccent = tint.usingColorSpace(.sRGB) ?? tint
    let top = fallbackAccent.blended(withFraction: 0.28, of: .white) ?? fallbackAccent
    let bottom = fallbackAccent.blended(withFraction: 0.32, of: .black) ?? fallbackAccent
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
    private let hint = NSTextField(labelWithString: "Enter: ask Nav or open URL    Cmd-Enter: search web    Type \"search ...\" to force search")
    private let shortcutsButton = NSButton(title: "Shortcuts", target: nil, action: nil)
    let field = NSTextField()
    var onSubmit: ((String, Bool) -> Void)?
    private var timer: Timer?
    private var shortcutsOpen = false

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

        hint.font = .systemFont(ofSize: 11.5, weight: .medium)
        hint.alignment = .center
        hint.lineBreakMode = .byTruncatingTail
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.isHidden = true

        shortcutsButton.translatesAutoresizingMaskIntoConstraints = false
        shortcutsButton.isBordered = false
        shortcutsButton.font = .systemFont(ofSize: 11.5, weight: .semibold)
        shortcutsButton.target = self
        shortcutsButton.action = #selector(toggleShortcuts)

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

        addSubview(logo); addSubview(clock); addSubview(greeting); addSubview(fieldWrap); addSubview(shortcutsButton); addSubview(hint)
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

            shortcutsButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            shortcutsButton.topAnchor.constraint(equalTo: fieldWrap.bottomAnchor, constant: 10),

            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: shortcutsButton.bottomAnchor, constant: 4),
            hint.widthAnchor.constraint(lessThanOrEqualTo: fieldWrap.widthAnchor),
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
        let appAppearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        appearance = appAppearance
        clock.appearance = appAppearance
        greeting.appearance = appAppearance
        field.appearance = appAppearance
        fieldWrap.appearance = appAppearance
        hint.appearance = appAppearance

        logo.image = breezeLogo()
        let clockColor = p.isDark ? p.text.withAlphaComponent(0.72) : p.text.withAlphaComponent(0.58)
        let softColor = p.isDark ? p.text.withAlphaComponent(0.62) : p.text.withAlphaComponent(0.68)
        clock.textColor = clockColor
        greeting.textColor = softColor
        hint.textColor = p.text.withAlphaComponent(p.isDark ? 0.42 : 0.50)
        shortcutsButton.contentTintColor = p.text.withAlphaComponent(p.isDark ? 0.50 : 0.56)
        field.textColor = p.text
        field.placeholderAttributedString = NSAttributedString(
            string: "Ask Breeze, or type a URL",
            attributes: [
                .foregroundColor: softColor,
                .font: field.font ?? NSFont.systemFont(ofSize: 16)
            ]
        )
        fieldWrap.layer?.backgroundColor = (p.isDark ? p.surface : NSColor.white.withAlphaComponent(0.72)).cgColor
        fieldWrap.layer?.shadowColor = NSColor.black.cgColor
        fieldWrap.layer?.shadowOpacity = p.isDark ? 0.25 : 0.10
        fieldWrap.layer?.shadowRadius = p.isDark ? 18 : 16
        fieldWrap.layer?.shadowOffset = CGSize(width: 0, height: -6)
    }

    @objc private func toggleShortcuts() {
        shortcutsOpen.toggle()
        hint.isHidden = !shortcutsOpen
        shortcutsButton.title = shortcutsOpen ? "Hide Shortcuts" : "Shortcuts"
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
