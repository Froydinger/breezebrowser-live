import WebKit

final class AdBlocker {
    static let shared = AdBlocker()
    private var identifier = "breeze-adblock"
    private var ruleLists: [WKContentRuleList] = []
    private var pendingCompiles = 0
    private var idleCallbacks: [() -> Void] = []

    private init() {}

    func compileIfNeeded(completion: @escaping () -> Void) {
        beginCompile()
        compileRuleLists {
            DispatchQueue.main.async {
                self.apply(to: sharedConfig.userContentController)
                completion()
                self.finishCompile()
            }
        }
    }

    func rebuild(completion: @escaping () -> Void = {}) {
        remove(from: sharedConfig.userContentController)
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in
            self.compileIfNeeded(completion: completion)
        }
    }

    private func compileRuleLists(_ done: @escaping () -> Void) {
        let mode = Store.shared.string("adblockMode") == "extreme" ? "extreme" : "normal"
        let exceptions = (Store.shared.settings["adblockSiteExceptions"] as? [String] ?? []).sorted().joined(separator: ",")
        let cacheKey = "\(mode)|\(exceptions)"
        identifier = "breeze-adblock-\(mode)-\(stableHash(cacheKey))"
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            if let list = list { self?.ruleLists = [list]; done(); return }
            guard let url = Bundle.main.url(forResource: "easylist", withExtension: "json"),
                  let json = try? String(contentsOf: url, encoding: .utf8) else {
                print("AdBlocker: easylist.json not found"); done(); return
            }
            let combined = self?.combinedRules(baseJSON: json, mode: mode) ?? json
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: self?.identifier ?? "breeze-adblock", encodedContentRuleList: combined) { list, error in
                if let error = error { print("AdBlocker: easylist compile failed - \(error.localizedDescription)") }
                self?.ruleLists = list.map { [$0] } ?? []
                done()
            }
        }
    }

    private func combinedRules(baseJSON: String, mode: String) -> String {
        guard var arr = (try? JSONSerialization.jsonObject(with: Data(baseJSON.utf8))) as? [[String: Any]] else {
            return baseJSON
        }
        let exceptions = (Store.shared.settings["adblockSiteExceptions"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let unless = exceptions.isEmpty ? nil : exceptions
        func trigger(_ pattern: String) -> [String: Any] {
            var t: [String: Any] = ["url-filter": pattern, "load-type": ["third-party"]]
            if let unless { t["unless-domain"] = unless }
            return t
        }
        let blockPatterns = [
            ".*://([^/]+\\.)?doubleclick\\.net/.*",
            ".*://([^/]+\\.)?googlesyndication\\.com/.*",
            ".*://securepubads\\.g\\.doubleclick\\.net/.*",
            ".*://([^/]+\\.)?googleadservices\\.com/.*",
            ".*://([^/]+\\.)?amazon-adsystem\\.com/.*",
            ".*://([^/]+\\.)?taboola\\.com/.*",
            ".*://([^/]+\\.)?outbrain\\.com/.*",
            ".*://([^/]+\\.)?adnxs\\.com/.*",
            ".*://([^/]+\\.)?rubiconproject\\.com/.*",
            ".*://([^/]+\\.)?pubmatic\\.com/.*",
            ".*://([^/]+\\.)?scorecardresearch\\.com/.*",
            ".*://([^/]+\\.)?criteo\\.com/.*",
            ".*://([^/]+\\.)?media\\.net/.*",
            ".*://([^/]+\\.)?ads\\.yahoo\\.com/.*",
            ".*://([^/]+\\.)?adtech\\.yahooinc\\.com/.*",
            ".*://([^/]+\\.)?gemini\\.yahoo\\.com/.*"
        ]
        for pattern in blockPatterns {
            arr.append(["trigger": trigger(pattern), "action": ["type": "block"]])
        }
        guard mode == "extreme" else {
            guard let data = try? JSONSerialization.data(withJSONObject: arr),
                  let out = String(data: data, encoding: .utf8) else { return baseJSON }
            return out
        }
        var cssTrigger: [String: Any] = ["url-filter": ".*"]
        if let unless { cssTrigger["unless-domain"] = unless }
        arr.append([
            "trigger": cssTrigger,
            "action": [
                "type": "css-display-none",
                "selector": "[id^='google_ads'],[id*='google_ads'],[id*='ad-container'],[class*='ad-container'],[class*='ad_unit'],[class*='ad-slot'],[class*='advertisement'],[data-ad],[data-testid*='ad']"
            ]
        ])
        guard let data = try? JSONSerialization.data(withJSONObject: arr),
              let out = String(data: data, encoding: .utf8) else { return baseJSON }
        return out
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func beginCompile() {
        if Thread.isMainThread {
            pendingCompiles += 1
        } else {
            DispatchQueue.main.sync { pendingCompiles += 1 }
        }
    }

    private func finishCompile() {
        pendingCompiles = max(0, pendingCompiles - 1)
        guard pendingCompiles == 0 else { return }
        let callbacks = idleCallbacks
        idleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    var isBusy: Bool {
        Thread.isMainThread ? pendingCompiles > 0 : DispatchQueue.main.sync { pendingCompiles > 0 }
    }

    func waitUntilIdle(_ done: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.pendingCompiles == 0 {
                done()
            } else {
                self.idleCallbacks.append(done)
            }
        }
    }

    func apply(to controller: WKUserContentController) {
        guard Store.shared.settings["adblockEnabled"] as? Bool ?? true else { return }
        ruleLists.forEach { controller.add($0) }
    }

    func remove(from controller: WKUserContentController) {
        ruleLists.forEach { controller.remove($0) }
    }
}
