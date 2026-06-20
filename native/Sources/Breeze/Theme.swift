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

    static let light = Palette(
        bg: srgb(242, 240, 237),
        bgTop: srgb(245, 242, 238),
        bgBottom: srgb(233, 228, 221),
        text: srgb(42, 42, 46),
        textSoft: srgb(42, 42, 46, 0.55),
        surface: NSColor(white: 1, alpha: 0.55),
        surfaceHover: NSColor(white: 1, alpha: 0.8),
        surfaceActive: NSColor(white: 1, alpha: 0.95),
        accent: srgb(91, 124, 250),
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
        accent: srgb(123, 149, 255),
        isDark: true
    )
}

final class Theme {
    static let shared = Theme()
    static let didChange = Notification.Name("BreezeThemeDidChange")

    private(set) var mode: ThemeMode = .system
    var palette: Palette {
        switch mode {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? .dark : .light
        }
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
