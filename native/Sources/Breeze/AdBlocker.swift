import WebKit

final class AdBlocker {
    static let shared = AdBlocker()
    private let identifier = "easylist"
    var ruleList: WKContentRuleList?

    private init() {}

    func compileIfNeeded(completion: @escaping () -> Void) {
        compileEasyList {
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

    func apply(to controller: WKUserContentController) {
        guard Store.shared.settings["adblockEnabled"] as? Bool ?? true else { return }
        if let list = ruleList { controller.add(list) }
    }

    func remove(from controller: WKUserContentController) {
        if let list = ruleList { controller.remove(list) }
    }
}
