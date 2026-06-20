// Native new-tab page: logo + clock + greeting + "Ask Breeze, or type a URL".
// Ports ui/newtab.html. No perpetual animation (per project rule) — the orbs are
// static. A 1s clock timer is fine (not a busy loop) and pauses when hidden.

import Cocoa

func breezeLogo() -> NSImage? {
    if let img = Bundle.main.image(forResource: "icon") { return img }
    // dev fallback when run via `swift run` (no app bundle): repo icon.png
    for p in ["../icon.png", "icon.png", "../ui/icon.png"] {
        if let img = NSImage(contentsOfFile: p) { return img }
    }
    return nil
}

final class NewTabView: NSView {
    private let logo = NSImageView()
    private let clock = NSTextField(labelWithString: "--:--")
    private let greeting = NSTextField(labelWithString: "")
    let field = NSTextField()
    var onSubmit: ((String) -> Void)?
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
        field.wantsLayer = true
        field.layer?.cornerRadius = 16
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(submit)
        // pad the text inside the rounded pill
        (field.cell as? NSTextFieldCell)?.usesSingleLineMode = true

        let fieldWrap = NSView()
        fieldWrap.wantsLayer = true
        fieldWrap.layer?.cornerRadius = 16
        fieldWrap.translatesAutoresizingMaskIntoConstraints = false
        fieldWrap.addSubview(field)

        addSubview(logo); addSubview(clock); addSubview(greeting); addSubview(fieldWrap)
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
            fieldWrap.widthAnchor.constraint(equalToConstant: 560),
            fieldWrap.heightAnchor.constraint(equalToConstant: 54),

            field.leadingAnchor.constraint(equalTo: fieldWrap.leadingAnchor, constant: 22),
            field.trailingAnchor.constraint(equalTo: fieldWrap.trailingAnchor, constant: -22),
            field.centerYAnchor.constraint(equalTo: fieldWrap.centerYAnchor),
        ])
        self.fieldWrap = fieldWrap
        applyTheme(); tick()
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }
    private var fieldWrap: NSView!

    @objc func applyTheme() {
        let p = Theme.shared.palette
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
        onSubmit?(t)
    }
}
