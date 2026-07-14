// Native auto-updater (the Sparkle-equivalent for the hand-built app).
//
// Checks GitHub Releases for the newest native release tag. When a newer release
// with a .zip asset is found, it
// downloads it, verifies the code signature, swaps the app bundle in place, and
// relaunches. Runs on launch, every 4 hours, and from Breeze → Check for Updates.

import Cocoa

private final class UpdaterBannerView: NSVisualEffectView {
    private let primaryAction: () -> Void
    private let secondaryAction: (() -> Void)?

    init(title: String, message: String, primaryTitle: String,
         secondaryTitle: String?, primaryAction: @escaping () -> Void,
         secondaryAction: (() -> Void)?) {
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3

        let primary = NSButton(title: primaryTitle, target: self, action: #selector(primaryTapped))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        if let secondaryTitle {
            let secondary = NSButton(title: secondaryTitle, target: self, action: #selector(secondaryTapped))
            secondary.bezelStyle = .rounded
            buttons.addArrangedSubview(secondary)
        }
        buttons.addArrangedSubview(primary)

        let stack = NSStackView(views: [titleLabel, messageLabel, buttons])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

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
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 18),
            view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            view.widthAnchor.constraint(equalToConstant: 480),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 18),
            view.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -18),
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
