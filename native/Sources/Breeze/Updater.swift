// Native auto-updater (the Sparkle-equivalent for the hand-built app).
//
// Checks GitHub Releases for the newest native release tag. When a newer release
// with a .zip asset is found, it
// downloads it, verifies the code signature, swaps the app bundle in place, and
// relaunches. Runs on launch, every 4 hours, and from Breeze → Check for Updates.

import Cocoa

private final class UpdaterBannerView: NSView {
    private let primaryAction: () -> Void
    private let secondaryAction: (() -> Void)?
    private let card = NSVisualEffectView()
    private let accentBar = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = NSButton()
    private var secondaryButton: NSButton?

    init(title: String, message: String, primaryTitle: String,
         secondaryTitle: String?, primaryAction: @escaping () -> Void,
         secondaryAction: (() -> Void)?) {
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.shadowOpacity = 0.22
        card.layer?.shadowRadius = 22
        card.layer?.shadowOffset = NSSize(width: 0, height: -8)
        addSubview(card)

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        card.addSubview(accentBar)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = breezeLogo()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        messageLabel.stringValue = message
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.maximumNumberOfLines = 3
        messageLabel.lineBreakMode = .byWordWrapping

        primaryButton.title = primaryTitle
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .large
        primaryButton.keyEquivalent = "\r"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        if let secondaryTitle {
            let secondary = NSButton(title: secondaryTitle, target: self, action: #selector(secondaryTapped))
            secondary.bezelStyle = .rounded
            secondary.controlSize = .large
            secondary.keyEquivalent = "\u{1b}"
            buttons.addArrangedSubview(secondary)
            secondaryButton = secondary
        }
        buttons.addArrangedSubview(primaryButton)

        let copy = NSStackView(views: [titleLabel, messageLabel])
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 5

        let header = NSStackView(views: [icon, copy])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 14

        card.addSubview(header)
        card.addSubview(buttons)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            card.widthAnchor.constraint(equalToConstant: 460),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            accentBar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            accentBar.topAnchor.constraint(equalTo: card.topAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: 3),

            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
            messageLabel.widthAnchor.constraint(equalTo: copy.widthAnchor),

            buttons.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            buttons.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            buttons.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme),
                                               name: Theme.didChange, object: nil)
        applyTheme()
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyTheme() {
        let p = Theme.shared.palette
        layer?.backgroundColor = NSColor.black.withAlphaComponent(p.isDark ? 0.22 : 0.10).cgColor
        card.layer?.borderColor = p.accent.withAlphaComponent(p.isDark ? 0.34 : 0.24).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        accentBar.layer?.backgroundColor = p.accent.cgColor
        titleLabel.textColor = p.text
        messageLabel.textColor = p.textSoft
        primaryButton.bezelColor = p.accent
        primaryButton.contentTintColor = .white
        secondaryButton?.contentTintColor = p.text
    }

    @objc private func primaryTapped() { primaryAction() }
    @objc private func secondaryTapped() { secondaryAction?() }
}

final class Updater {
    static let shared = Updater()
    private let releasesAPI = URL(string: "https://api.github.com/repos/Froydinger/breezebrowser-live/releases?per_page=30")!
    private var timer: Timer?
    private var busy = false
    private weak var banner: UpdaterBannerView?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    func start() {
        // first check shortly after launch, then every 4 hours
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.check(manual: false)
        }
    }

    /// Look for a newer native release. `manual` shows an "up to date" alert.
    func check(manual: Bool) {
        if busy { return }
        busy = true
        var req = URLRequest(url: releasesAPI)
        req.timeoutInterval = 12
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { return }
            defer { self.busy = false }
            guard let data,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if manual { DispatchQueue.main.async { self.alertUpToDate(failed: true) } }
                return
            }
            // newest native release, non-draft, non-prerelease, with a .zip asset
            var best: (ver: String, zip: String)?
            for rel in arr {
                guard (rel["draft"] as? Bool) != true, (rel["prerelease"] as? Bool) != true,
                      let tag = rel["tag_name"] as? String,
                      let ver = Self.nativeVersion(from: tag) else { continue }
                let assets = rel["assets"] as? [[String: Any]] ?? []
                guard let zip = assets.first(where: { asset in
                    guard let name = asset["name"] as? String else { return false }
                    return name == "Breeze-arm64.zip" || name == "Breeze-\(ver)-arm64.zip"
                })?["browser_download_url"] as? String
                else { continue }
                if best == nil || Self.isNewer(ver, than: best!.ver) { best = (ver, zip) }
            }
            DispatchQueue.main.async {
                guard let best, Self.isNewer(best.ver, than: self.currentVersion), let url = URL(string: best.zip) else {
                    if manual { self.alertUpToDate(failed: false) }
                    return
                }
                self.promptAndInstall(version: best.ver, zip: url)
            }
        }.resume()
    }

    private func alertUpToDate(failed: Bool) {
        showBanner(title: failed ? "Couldn't check for updates" : "You're up to date",
                   message: failed ? "Please try again later." : "Breeze \(currentVersion) is the latest version.",
                   primaryTitle: "OK", secondaryTitle: nil, primaryAction: {})
    }

    private func promptAndInstall(version: String, zip: URL) {
        if Store.shared.settings["updateSounds"] as? Bool != false {
            NSSound(named: "Glass")?.play()
        }
        showBanner(title: "Breeze \(version) is available",
                   message: "You're on \(currentVersion). Install the update now? Breeze will relaunch.",
                   primaryTitle: "Update & Relaunch", secondaryTitle: "Later") { [weak self] in
            self?.download(zip) { [weak self] local in
                guard let self, let local else { self?.alertInstallFailed(); return }
                self.install(zipURL: local)
            }
        }
    }

    private func download(_ url: URL, _ done: @escaping (URL?) -> Void) {
        URLSession.shared.downloadTask(with: url) { tmp, _, _ in
            guard let tmp else { DispatchQueue.main.async { done(nil) }; return }
            // move out of the URLSession temp before it's reaped
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("breeze-update-\(UUID().uuidString).zip")
            try? FileManager.default.moveItem(at: tmp, to: dest)
            DispatchQueue.main.async { done(dest) }
        }.resume()
    }

    private func install(zipURL: URL) {
        let fm = FileManager.default
        let unpack = fm.temporaryDirectory.appendingPathComponent("breeze-unpack-\(UUID().uuidString)")
        try? fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpack.path]) == 0,
              let appName = (try? fm.contentsOfDirectory(atPath: unpack.path))?.first(where: { $0.hasSuffix(".app") })
        else { alertInstallFailed(); return }
        let newApp = unpack.appendingPathComponent(appName)
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])   // not browser-downloaded → unblock
        // refuse to install a broken/unsigned bundle
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            alertInstallFailed(); return
        }
        let dest = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backup = dest.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: dest, to: backup)     // move the running bundle aside (inode stays live)
            try fm.moveItem(at: newApp, to: dest)     // drop the new bundle into place
            try? fm.removeItem(at: backup)
        } catch {
            // try to restore if the swap half-failed
            if !fm.fileExists(atPath: dest.path), fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: dest)
            }
            alertInstallFailed(); return
        }
        relaunch(path: dest.path)
    }

    private func relaunch(path: String) {
        // LaunchServices treats `open` as activation while the old instance is
        // still alive. A fixed sleep races WebKit/AppKit shutdown and can activate
        // the dying process without starting the replacement. Wait for this exact
        // PID to disappear, then force a fresh instance of the updated bundle.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$BREEZE_OLD_PID\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open -n \"$BREEZE_RELAUNCH_PATH\""]
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "BREEZE_OLD_PID": String(ProcessInfo.processInfo.processIdentifier),
            "BREEZE_RELAUNCH_PATH": path,
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            alertInstallFailed()
            return
        }
        NSApp.terminate(nil)
    }

    private func alertInstallFailed() {
        showBanner(title: "Update couldn't be installed",
                   message: "Please download the latest Breeze from the website and install it manually.",
                   primaryTitle: "OK", secondaryTitle: nil, primaryAction: {})
    }

    /// Update notices stay inside the existing Breeze window. On macOS 27,
    /// ordering an NSAlert while WebKit owns a fullscreen/PiP remote view can make
    /// ViewBridge attach that stale view to the alert window and abort the app.
    private func showBanner(title: String, message: String, primaryTitle: String,
                            secondaryTitle: String?, primaryAction: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        let browserWindows = NSApp.windows.filter {
            $0.isVisible && $0.delegate is BrowserController
        }
        let targetWindow = browserWindows.first(where: \.isKeyWindow) ?? browserWindows.first
        guard let host = targetWindow?.contentView else {
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        banner?.removeFromSuperview()
        let view = UpdaterBannerView(
            title: title, message: message, primaryTitle: primaryTitle,
            secondaryTitle: secondaryTitle,
            primaryAction: { [weak self] in
                self?.banner?.removeFromSuperview()
                primaryAction()
            },
            secondaryAction: secondaryTitle == nil ? nil : { [weak self] in
                self?.banner?.removeFromSuperview()
            }
        )
        host.addSubview(view, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        banner = view
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = nil; p.standardError = nil
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    static func nativeVersion(from tag: String) -> String? {
        guard tag.hasPrefix("v") else { return nil }
        let ver = String(tag.dropFirst())
        let parts = ver.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2, parts[0] >= 3 else { return nil }
        return ver
    }

    /// Semantic-ish compare: "4.0.10" > "4.0.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
