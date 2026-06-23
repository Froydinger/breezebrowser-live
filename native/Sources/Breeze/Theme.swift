// Design tokens ported 1:1 from ui/style.css :root (+ html.dark). Single source
// of truth for colors so the native chrome matches the Electron app exactly.

import Cocoa

enum ThemeMode: String { case light, dark, system }

private func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

struct Palette {
    let bg: NSColor
    let bgTop: NSColor          // top of the 160° gradient
    let bgBottom: NSColor       // bottom of the gradient
    let text: NSColor
    let textSoft: NSColor
    let surface: NSColor
    let surfaceHover: NSColor
    let surfaceActive: NSColor
    let accent: NSColor
    let isDark: Bool

    func withAccent(_ c: NSColor) -> Palette {
        Palette(bg: bg, bgTop: bgTop, bgBottom: bgBottom, text: text, textSoft: textSoft,
                surface: surface, surfaceHover: surfaceHover, surfaceActive: surfaceActive,
                accent: c, isDark: isDark)
    }

    static let light = Palette(
        bg: srgb(242, 240, 237),
        bgTop: srgb(245, 242, 238),
        bgBottom: srgb(233, 228, 221),
        text: srgb(42, 42, 46),
        textSoft: srgb(42, 42, 46, 0.55),
        surface: NSColor(white: 1, alpha: 0.55),
        surfaceHover: NSColor(white: 1, alpha: 0.8),
        surfaceActive: NSColor(white: 1, alpha: 0.95),
        accent: srgb(58, 166, 185),        // default teal, close to the Breeze mark
        isDark: false
    )

    static let dark = Palette(
        bg: srgb(22, 22, 26),
        bgTop: srgb(26, 26, 32),
        bgBottom: srgb(18, 18, 22),
        text: srgb(236, 236, 240),
        textSoft: srgb(236, 236, 240, 0.5),
        surface: NSColor(white: 1, alpha: 0.06),
        surfaceHover: NSColor(white: 1, alpha: 0.10),
        surfaceActive: NSColor(white: 1, alpha: 0.14),
        accent: srgb(58, 166, 185),        // default teal, close to the Breeze mark
        isDark: true
    )
}

final class Theme {
    static let shared = Theme()
    static let didChange = Notification.Name("BreezeThemeDidChange")

    private(set) var mode: ThemeMode = .system

    static let defaultAccent = "#3aa6b9"
    static let monoAccent = "mono"

    static func hex(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return srgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    /// True when the user picked a non-default accent.
    var isCustomAccent: Bool {
        let a = Store.shared.string("accent").lowercased()
        return !a.isEmpty && a != Theme.defaultAccent && a != Theme.monoAccent
    }
    var customAccent: NSColor? {
        let a = Store.shared.string("accent").lowercased()
        if a == Theme.monoAccent { return basePalette.isDark ? srgb(245, 245, 247) : srgb(28, 28, 32) }
        return isCustomAccent ? Theme.hex(Store.shared.string("accent")) : nil
    }

    private var basePalette: Palette {
        switch mode {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .dark : .light
        }
    }

    var palette: Palette {
        if let c = customAccent { return basePalette.withAccent(c) }
        return basePalette
    }

    func cycle() {  // matches #theme-btn: Light → Dark → System
        switch mode {
        case .light:  mode = .dark
        case .dark:   mode = .system
        case .system: mode = .light
        }
        apply()
    }

    func set(_ m: ThemeMode) { mode = m; apply() }

    func apply() {
        switch mode {
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        NotificationCenter.default.post(name: Theme.didChange, object: nil)
    }
}
