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
        bg: srgb(14, 15, 19),
        bgTop: srgb(18, 19, 25),
        bgBottom: srgb(10, 11, 15),
        text: srgb(236, 236, 240),
        textSoft: srgb(236, 236, 240, 0.56),
        surface: NSColor(white: 1, alpha: 0.055),
        surfaceHover: NSColor(white: 1, alpha: 0.095),
        surfaceActive: NSColor(white: 1, alpha: 0.13),
        accent: srgb(58, 166, 185),        // default teal, close to the Breeze mark
        isDark: true
    )
}

final class Theme {
    static let shared = Theme()
    static let didChange = Notification.Name("BreezeThemeDidChange")

    private(set) var mode: ThemeMode = .system
    private var systemIsDark: Bool
    private var appearanceObservation: NSKeyValueObservation?

    private init() {
        let globalStyle = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        if let globalStyle {
            systemIsDark = globalStyle.caseInsensitiveCompare("Dark") == .orderedSame
        } else {
            systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        // Explicit Breeze theme changes already call apply(). System appearance
        // changes do not, so bridge AppKit's documented KVO signal into the same
        // notification path after its effective appearance has settled.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self, self.mode == .system else { return }
                let isDark = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                guard isDark != self.systemIsDark else { return }
                self.systemIsDark = isDark
                NotificationCenter.default.post(name: Theme.didChange, object: nil)
            }
        }
    }

    static let defaultAccent = "#3aa6b9"
    static func hex(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return srgb((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    private var basePalette: Palette {
        switch mode {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            return systemIsDark ? .dark : .light
        }
    }

    var palette: Palette {
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
