// Native new-tab page: logo + greeting + "Ask Breeze, or type a URL" + the
// suggested-sites shelf. The clock lives in the sidebar, not here.
// Ports ui/newtab.html. No perpetual animation (per project rule) — the orbs are
// static. The greeting timer fires once a minute and pauses when hidden.

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
    return base
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
    let tint = accent.blended(withFraction: 0.36, of: .black) ?? accent
    if let img = Bundle.main.image(forResource: "nav-icon") {
        return img
    }
    for p in ["../nav-icon.png", "nav-icon.png", "../ui/nav-icon.png"] {
        if let img = NSImage(contentsOfFile: p) {
            return img
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

final class NewTabView: GradientBackgroundView {
    private let baseFieldHeight: CGFloat = 54
    private let maxFieldLines = 4
    private let logo = NSImageView()
    private let greeting = NSTextField(labelWithString: "")
    private let inputHint = NSStackView()
    /// Most-visited sites, from local history only (Store.topSites). Hidden when
    /// the setting is off or history is empty, so a fresh profile shows nothing
    /// rather than an empty shelf.
    private let suggestions = NSStackView()
    var onOpenSuggestion: ((String) -> Void)?
    private let askReturnKey = NSTextField(labelWithString: "↩")
    private let askHint = NSTextField(labelWithString: "Ask")
    private let shiftKey = NSTextField(labelWithString: "⇧")
    private let searchReturnKey = NSTextField(labelWithString: "↩")
    private let searchHint = NSTextField(labelWithString: "Search")
    let field = NSTextField()
    var onSubmit: ((String, Bool) -> Void)?
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        logo.image = breezeLogo()
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false


        greeting.font = .systemFont(ofSize: 30, weight: .light)
        greeting.alignment = .center
        greeting.translatesAutoresizingMaskIntoConstraints = false

        inputHint.translatesAutoresizingMaskIntoConstraints = false
        inputHint.orientation = .horizontal
        inputHint.alignment = .centerY
        inputHint.spacing = 5
        [askReturnKey, shiftKey, searchReturnKey].forEach { key in
            key.font = .systemFont(ofSize: 10.5, weight: .semibold)
            key.alignment = .center
            key.wantsLayer = true
            key.layer?.cornerRadius = 4
            key.layer?.borderWidth = 1
            key.translatesAutoresizingMaskIntoConstraints = false
            key.widthAnchor.constraint(equalToConstant: 21).isActive = true
            key.heightAnchor.constraint(equalToConstant: 18).isActive = true
        }
        [askHint, searchHint].forEach {
            $0.font = .systemFont(ofSize: 11.5, weight: .medium)
        }
        let separator = NSTextField(labelWithString: "·")
        separator.font = .systemFont(ofSize: 11.5, weight: .medium)
        inputHint.addArrangedSubview(askReturnKey)
        inputHint.addArrangedSubview(askHint)
        inputHint.addArrangedSubview(separator)
        inputHint.addArrangedSubview(shiftKey)
        inputHint.addArrangedSubview(searchReturnKey)
        inputHint.addArrangedSubview(searchHint)

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

        suggestions.translatesAutoresizingMaskIntoConstraints = false
        suggestions.orientation = .horizontal
        suggestions.alignment = .centerY
        suggestions.spacing = 10
        suggestions.isHidden = true

        // Everything lives in one column centred as a group. It used to be a chain
        // of constraints hanging off the clock's centre, so adding anything at the
        // bottom (the suggestion shelf) pushed the whole page visibly low.
        let column = NSStackView(views: [logo, greeting, fieldWrap, inputHint, suggestions])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        column.setCustomSpacing(22, after: logo)
        column.setCustomSpacing(28, after: greeting)
        column.setCustomSpacing(11, after: fieldWrap)
        column.setCustomSpacing(34, after: inputHint)
        addSubview(column)
        let widthC = fieldWrap.widthAnchor.constraint(equalToConstant: 560)
        widthC.priority = .defaultHigh
        let maxC = fieldWrap.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        maxC.priority = .required

        fieldHeightConstraint = fieldWrap.heightAnchor.constraint(equalToConstant: baseFieldHeight)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 54),
            logo.heightAnchor.constraint(equalToConstant: 54),

            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Nudged up a touch so the column reads as optically centred rather
            // than mathematically centred, which always looks low.
            column.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            widthC,
            maxC,
            fieldHeightConstraint,

            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -22),
            field.topAnchor.constraint(equalTo: fieldWrap.topAnchor, constant: 16),
            field.bottomAnchor.constraint(equalTo: fieldWrap.bottomAnchor, constant: -16),

            suggestions.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
        self.fieldWrap = fieldWrap
        applyTheme(); tick()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    /// Rebuild the suggestion shelf. Called when the new tab appears, so it
    /// reflects history as of now without anything polling in the background.
    func reloadSuggestions() {
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Store.shared.settings["newTabSuggestions"] as? Bool ?? true else {
            // Hiding must not be a one-way trip that only Settings can undo. Leave
            // a quiet way back on the page itself.
            guard !Store.shared.topSites(limit: 1).isEmpty else {
                suggestions.isHidden = true
                return
            }
            let show = NSButton(title: "Show suggested sites", target: nil, action: nil)
            show.isBordered = false
            show.font = .systemFont(ofSize: 11, weight: .medium)
            show.contentTintColor = Theme.shared.palette.text.withAlphaComponent(0.38)
            show.translatesAutoresizingMaskIntoConstraints = false
            show.target = self
            show.action = #selector(showSuggestionsAgain)
            suggestions.addArrangedSubview(show)
            suggestions.isHidden = false
            return
        }
        let sites = Store.shared.topSites(limit: 6)
        suggestions.isHidden = sites.isEmpty
        guard !sites.isEmpty else { return }
        let p = Theme.shared.palette
        for site in sites {
            let chip = SuggestionChip(site: site, palette: p)
            chip.onTap = { [weak self] in self?.onOpenSuggestion?(site.url) }
            suggestions.addArrangedSubview(chip)
        }
        // Dismiss right where the shelf is, rather than sending people to
        // Settings to find out what this row even was. The choice is the same
        // newTabSuggestions setting, so it sticks and can be undone there.
        let hide = HoverButton(symbol: "xmark", size: 22, point: 9)
        hide.toolTip = "Hide suggested sites"
        hide.onTap = {
            Store.shared.settings["newTabSuggestions"] = false
            Store.shared.saveSettings()
            NotificationCenter.default.post(name: NewTabView.suggestionsDismissed, object: nil)
        }
        suggestions.addArrangedSubview(hide)
    }

    @objc private func showSuggestionsAgain() {
        Store.shared.settings["newTabSuggestions"] = true
        Store.shared.saveSettings()
        NotificationCenter.default.post(name: NewTabView.suggestionsDismissed, object: nil)
    }

    /// Posted when the shelf is dismissed from the page, so the controller can
    /// re-render and any open Settings page picks the change up.
    static let suggestionsDismissed = Notification.Name("BreezeNewTabSuggestionsDismissed")

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
        needsDisplay = true
        let appAppearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
        appearance = appAppearance
        greeting.appearance = appAppearance
        field.appearance = appAppearance
        fieldWrap.appearance = appAppearance

        logo.image = breezeLogo()
        let softColor = p.isDark ? p.text.withAlphaComponent(0.62) : p.text.withAlphaComponent(0.68)
        greeting.textColor = softColor
        let hintColor = p.text.withAlphaComponent(p.isDark ? 0.50 : 0.56)
        inputHint.arrangedSubviews.compactMap { $0 as? NSTextField }.forEach { $0.textColor = hintColor }
        [askReturnKey, shiftKey, searchReturnKey].forEach { key in
            key.layer?.backgroundColor = p.text.withAlphaComponent(p.isDark ? 0.06 : 0.035).cgColor
            key.layer?.borderColor = p.text.withAlphaComponent(p.isDark ? 0.20 : 0.15).cgColor
            key.attributedStringValue = NSAttributedString(
                string: key.stringValue,
                attributes: [
                    .font: key.font ?? NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: hintColor,
                    // Negative lowers the glyph. The arrow and shift glyphs sit high
                    // in their em box, so without this they float near the top edge
                    // of the key cap instead of centring in it.
                    .baselineOffset: -3.0,
                    .paragraphStyle: {
                        let ps = NSMutableParagraphStyle()
                        ps.alignment = .center
                        return ps
                    }()
                ]
            )
        }
        if !suggestions.arrangedSubviews.isEmpty { reloadSuggestions() }
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

    func tick() {
        let now = Date()
        let h = Calendar.current.component(.hour, from: now)
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        let name = (Store.shared.settings["userName"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        greeting.stringValue = name.isEmpty ? "\(part)." : "\(part), \(name)."
        greeting.isHidden = !Store.shared.bool("showGreeting")
        // Name the engine the keystroke will actually use, so ⇧⏎ is not a guess.
        searchHint.stringValue = "Search with \(NewTabView.searchEngineName())"
    }

    /// Display name for the configured search engine.
    static func searchEngineName() -> String {
        switch (Store.shared.settings["searchEngine"] as? String ?? "spectra").lowercased() {
        case "google":     return "Google"
        case "duckduckgo": return "DuckDuckGo"
        case "bing":       return "Bing"
        case "brave":      return "Brave"
        default:           return "Spectra"
        }
    }

    func startClock() {
        timer?.invalidate()
        tick()
        // The display only has minute resolution, so waking every second was pure
        // idle work. Fire on the next minute boundary, then once a minute.
        let delay = 60 - Calendar.current.component(.second, from: Date())
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.tick()
            self.timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        }
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

/// One site on the new-tab suggestion shelf: favicon over a short label.
/// Deliberately plain — no counts, no "because you visited", nothing that reads
/// as surveillance. Just the sites you actually use, one click away.
final class SuggestionChip: NSView {
    var onTap: (() -> Void)?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovering = false
    private let palette: Palette

    init(site: (url: String, title: String, host: String), palette: Palette) {
        self.palette = palette
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6
        iconView.layer?.masksToBounds = true
        iconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        iconView.contentTintColor = palette.text.withAlphaComponent(0.55)
        Favicons.shared.image(for: site.host) { [weak self] img in
            guard let self, let img else { return }
            self.iconView.contentTintColor = nil
            self.iconView.image = img
        }

        label.stringValue = SuggestionChip.siteName(title: site.title, host: site.host)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        label.textColor = palette.text.withAlphaComponent(0.62)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView); addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 76),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        toolTip = site.title
    }
    required init?(coder: NSCoder) { nil }

    /// A readable name for the site rather than its bare hostname.
    ///
    /// Page titles put the site name in no fixed position - "Main Page - Wikipedia"
    /// ends with it, "GitHub · Explore" starts with it - so picking by position
    /// alone mislabels half of them. Instead, match each segment against the
    /// host's own name and prefer the one that matches; fall back to the last
    /// segment, which is the more common convention, and then to the host.
    static func siteName(title: String, host: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostLabel = hostKeyword(host)
        var name = cleaned

        if !cleaned.isEmpty {
            var parts: [String] = [cleaned]
            for sep in [" — ", " – ", " | ", " · ", " - ", ": "] where cleaned.contains(sep) {
                parts = cleaned.components(separatedBy: sep)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                break
            }
            if parts.count > 1 {
                let matched = parts.first { part in
                    let squashed = part.lowercased().filter { $0.isLetter || $0.isNumber }
                    return !hostLabel.isEmpty && !squashed.isEmpty
                        && (squashed == hostLabel || squashed.contains(hostLabel) || hostLabel.contains(squashed))
                }
                name = matched ?? parts.last ?? cleaned
            }
        }

        if name.isEmpty { name = host }
        // A "title" that is really just the URL helps nobody - prefer the host.
        if name.lowercased().hasPrefix("http") { name = host }
        return name.count > 16 ? String(name.prefix(15)) + "…" : name
    }

    /// "en.wikipedia.org" -> "wikipedia", "github.com" -> "github". The part of a
    /// hostname that a site actually calls itself.
    private static func hostKeyword(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        let junk: Set<String> = ["www", "com", "org", "net", "io", "co", "app", "dev", "gov", "edu", "uk", "us"]
        labels.removeAll { junk.contains($0) }
        return (labels.max(by: { $0.count < $1.count }) ?? host)
            .filter { $0.isLetter || $0.isNumber }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
    override func mouseUp(with event: NSEvent) { onTap?() }

    private func restyle() {
        // Hover only — no resting animation, per the idle-GPU rule.
        layer?.backgroundColor = hovering
            ? palette.text.withAlphaComponent(palette.isDark ? 0.08 : 0.06).cgColor
            : NSColor.clear.cgColor
        label.textColor = palette.text.withAlphaComponent(hovering ? 0.85 : 0.62)
    }
}
