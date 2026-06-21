// Native auto-updater (the Sparkle-equivalent for the hand-built app).
//
// Checks GitHub Releases for the newest **v3.x** tag (the native channel — kept
// separate from the Electron 2.x "latest" so existing Electron users are never
// pushed a native build). When a newer release with a .zip asset is found, it
// downloads it, verifies the code signature, swaps the app bundle in place, and
// relaunches. Runs on launch, every 4 hours, and from Breeze → Check for Updates.

import Cocoa

final class Updater {
    static let shared = Updater()
    private let releasesAPI = URL(string: "https://api.github.com/repos/Froydinger/breezebrowser-live/releases?per_page=30")!
    private var timer: Timer?
    private var busy = false

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
            // newest v3.x, non-draft, non-prerelease, with a .zip asset
            var best: (ver: String, zip: String)?
            for rel in arr {
                guard (rel["draft"] as? Bool) != true, (rel["prerelease"] as? Bool) != true,
                      let tag = rel["tag_name"] as? String, tag.hasPrefix("v3.") else { continue }
                let ver = String(tag.dropFirst())
                let assets = rel["assets"] as? [[String: Any]] ?? []
                guard let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })?["browser_download_url"] as? String
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
        let a = NSAlert()
        a.messageText = failed ? "Couldn't check for updates" : "You're up to date"
        a.informativeText = failed ? "Please try again later." : "Breeze \(currentVersion) is the latest version."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    private func promptAndInstall(version: String, zip: URL) {
        let a = NSAlert()
        a.messageText = "Breeze \(version) is available"
        a.informativeText = "You're on \(currentVersion). Download and install the update now? Breeze will relaunch."
        a.addButton(withTitle: "Update & Relaunch")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        download(zip) { [weak self] local in
            guard let self, let local else { self?.alertInstallFailed(); return }
            self.install(zipURL: local)
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
        // detached: wait for us to quit, then reopen the new bundle
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func alertInstallFailed() {
        let a = NSAlert()
        a.messageText = "Update couldn't be installed"
        a.informativeText = "Please download the latest Breeze from the website and install it manually."
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.standardOutput = nil; p.standardError = nil
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    /// Semantic-ish compare: "3.0.10" > "3.0.9".
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
