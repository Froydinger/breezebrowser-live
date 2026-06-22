import WebKit

final class AdBlocker {
    static let shared = AdBlocker()
    private let identifier = "easylist"
    private let youtubeIdentifier = "breeze-youtube-v1"
    var ruleList: WKContentRuleList?
    var youtubeList: WKContentRuleList?

    private init() {}

    // Supplementary YouTube rules. WKContentRuleList is declarative-only — no
    // scriptlet injection (what uBlock/Ghostery use to strip YouTube's in-player
    // video ads), and YouTube streams those ads from the same domain as the real
    // video, so they can't be blocked here. These do what WKWebView *can*: drop ad
    // tracking/beacon requests and hide static banner / feed / overlay ad slots.
    private let youtubeRules = """
    [
      {"trigger":{"url-filter":"youtube\\\\.com/api/stats/ads"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"youtube\\\\.com/pagead/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"youtube\\\\.com/ptracking"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"/pagead/interaction/"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"doubleclick\\\\.net"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googlesyndication\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"googleadservices\\\\.com"},"action":{"type":"block"}},
      {"trigger":{"url-filter":".*","if-domain":["*youtube.com"]},"action":{"type":"css-display-none","selector":"#masthead-ad, #player-ads, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer, ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer, ytd-companion-slot-renderer, ytd-banner-promo-renderer, ytd-statement-banner-renderer, .ytp-ad-overlay-slot, .ytd-mealbar-promo-renderer"}}
    ]
    """

    func compileIfNeeded(completion: @escaping () -> Void) {
        let group = DispatchGroup()
        group.enter(); compileEasyList { group.leave() }
        group.enter(); compileYouTube { group.leave() }
        group.notify(queue: .main) {
            self.apply(to: sharedConfig.userContentController)
            completion()
        }
    }

    private func compileEasyList(_ done: @escaping () -> Void) {
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            if let list = list { self?.ruleList = list; done(); return }
            guard let url = Bundle.main.url(forResource: "easylist", withExtension: "json"),
                  let json = try? String(contentsOf: url, encoding: .utf8) else {
                print("AdBlocker: easylist.json not found"); done(); return
            }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: self?.identifier ?? "easylist", encodedContentRuleList: json) { list, error in
                if let error = error { print("AdBlocker: easylist compile failed - \(error.localizedDescription)") }
                self?.ruleList = list
                done()
            }
        }
    }

    private func compileYouTube(_ done: @escaping () -> Void) {
        // Always (re)compile — the list is tiny and this avoids serving a stale
        // cached version when the rules change between releases.
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: youtubeIdentifier, encodedContentRuleList: youtubeRules) { [weak self] list, error in
            if let error = error { print("AdBlocker: youtube rules compile failed - \(error.localizedDescription)") }
            self?.youtubeList = list
            done()
        }
    }

    func apply(to controller: WKUserContentController) {
        guard Store.shared.settings["adblockEnabled"] as? Bool ?? true else { return }
        if let list = ruleList { controller.add(list) }
        if let list = youtubeList { controller.add(list) }
    }

    func remove(from controller: WKUserContentController) {
        if let list = ruleList { controller.remove(list) }
        if let list = youtubeList { controller.remove(list) }
    }
}
