import WebKit

final class AdBlocker {
    static let shared = AdBlocker()
    private let identifier = "easylist"
    var ruleList: WKContentRuleList?

    private init() {}

    func compileIfNeeded(completion: @escaping () -> Void) {
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { [weak self] list, _ in
            if let list = list {
                self?.ruleList = list
                self?.apply(to: sharedConfig.userContentController)
                DispatchQueue.main.async { completion() }
            } else {
                guard let url = Bundle.main.url(forResource: "easylist", withExtension: "json"),
                      let data = try? Data(contentsOf: url),
                      let jsonString = String(data: data, encoding: .utf8) else {
                    print("AdBlocker: Failed to find or read easylist.json")
                    DispatchQueue.main.async { completion() }
                    return
                }

                print("AdBlocker: Compiling rules for the first time... this may take a few seconds.")
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: self?.identifier ?? "easylist", encodedContentRuleList: jsonString) { list, error in
                    if let error = error {
                        print("AdBlocker: Compile failed - \(error.localizedDescription)")
                    } else if let list = list {
                        print("AdBlocker: Compilation successful!")
                        self?.ruleList = list
                        self?.apply(to: sharedConfig.userContentController)
                    }
                    DispatchQueue.main.async { completion() }
                }
            }
        }
    }

    func apply(to controller: WKUserContentController) {
        if let list = ruleList, Store.shared.settings["adblockEnabled"] as? Bool ?? true {
            controller.add(list)
        }
    }

    func remove(from controller: WKUserContentController) {
        if let list = ruleList {
            controller.remove(list)
        }
    }
}
