// Persistent app state: settings (mirrors the Electron settings keys) + pins.
// Stored as JSON in ~/Library/Application Support/Breeze/. Tabs are intentionally
// NOT persisted (fresh New Tab each launch); pins ARE.

import Foundation

final class Store {
    static let shared = Store()

    private let dir: URL
    private let settingsURL: URL
    private let pinsURL: URL
    private let historyURL: URL
    private let bookmarksURL: URL
    private let chatsURL: URL
    private let openTabsURL: URL
    var chats: [[String: Any]] = []      // { id, title, messages:[{role,text}] }

    var settings: [String: Any]
    var pins: [Pin]
    var history: [[String: Any]]      // { url, title, ts }
    var bookmarks: [[String: Any]]    // { url, title, ts }
    var openTabs: [String]            // array of tab URLs

    static let defaults: [String: Any] = [
        "theme": "system",
        "accent": "#5b7cfa",
        "pinSize": "large",
        "searchEngine": "google",
        "clock24": false,
        "showGreeting": true,
        "urlBarPosition": "top",
        "userName": "",
        "adblockEnabled": true,
        "notificationSounds": true,
        "updateSounds": true,
        "autoPip": true,
        "restoreTabs": false,
        "webNotifications": true,
        "tabSleepHours": 1,
        "aiInstructions": "",
        // Non-secret mirror of "is an OpenAI key saved". Lets the UI show readiness
        // without reading secret storage during ordinary rendering.
        "aiKeyConnected": false,
        // Cumulative OpenAI token usage (this Mac), for an estimated-cost readout.
        "aiUsageInput": 0,
        "aiUsageOutput": 0,
        "aiUsageSince": 0,
        "lastSeenVersion": "",
        "permissions": [String: Any](),
        "reminders": [Any]()
    ]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folderName = "Breeze"
        if let idx = CommandLine.arguments.firstIndex(of: "--profile"), idx + 1 < CommandLine.arguments.count {
            folderName = CommandLine.arguments[idx + 1]
        } else if let env = ProcessInfo.processInfo.environment["BREEZE_PROFILE"] {
            folderName = env
        }
        dir = base.appendingPathComponent(folderName, isDirectory: true)
        settingsURL = dir.appendingPathComponent("settings.json")
        pinsURL = dir.appendingPathComponent("pins.json")
        historyURL = dir.appendingPathComponent("history.json")
        bookmarksURL = dir.appendingPathComponent("bookmarks.json")
        chatsURL = dir.appendingPathComponent("chats.json")
        openTabsURL = dir.appendingPathComponent("opentabs.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // settings = defaults merged with whatever was saved
        var s = Store.defaults
        if let data = try? Data(contentsOf: settingsURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in saved { s[k] = v }
        }
        settings = s

        if let data = try? Data(contentsOf: pinsURL),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            pins = arr.compactMap { d in d["url"].map { Pin(url: $0, title: d["title"] ?? "") } }
        } else { pins = [] }

        history = (try? Data(contentsOf: historyURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        bookmarks = (try? Data(contentsOf: bookmarksURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        chats = (try? Data(contentsOf: chatsURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        openTabs = (try? Data(contentsOf: openTabsURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []

        // Migrate any very old plaintext setting into the owner-only key file.
        if let key = settings["openaiKey"] as? String, !key.isEmpty {
            LocalSecrets.set("openaiKey", key)
            settings.removeValue(forKey: "openaiKey")
            settings["aiKeyConnected"] = true
            saveSettings()
        }
    }

    func saveOpenTabs() {
        if let data = try? JSONSerialization.data(withJSONObject: openTabs) { try? data.write(to: openTabsURL) }
    }

    // MARK: - Chat history

    func saveChats() {
        if let data = try? JSONSerialization.data(withJSONObject: chats) { try? data.write(to: chatsURL) }
    }
    /// Insert or update a chat (newest first). Empty chats are ignored.
    func upsertChat(id: Double, title: String, messages: [[String: String]]) {
        guard !messages.isEmpty else { return }
        chats.removeAll { ($0["id"] as? Double) == id }
        chats.insert(["id": id, "title": title, "messages": messages], at: 0)
        if chats.count > 200 { chats = Array(chats.prefix(200)) }
        saveChats()
    }
    func deleteChat(id: Double) { chats.removeAll { ($0["id"] as? Double) == id }; saveChats() }
    func chatMessages(id: Double) -> [[String: String]] {
        (chats.first { ($0["id"] as? Double) == id }?["messages"] as? [[String: String]]) ?? []
    }

    static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    func saveHistory() {
        if let data = try? JSONSerialization.data(withJSONObject: history) { try? data.write(to: historyURL) }
    }
    func saveBookmarks() {
        if let data = try? JSONSerialization.data(withJSONObject: bookmarks) { try? data.write(to: bookmarksURL) }
    }

    /// Record a visit: de-dupe consecutive same-URL, newest first, capped.
    func addHistory(url: String, title: String) {
        guard !url.isEmpty, url.hasPrefix("http") else { return }
        if let first = history.first, first["url"] as? String == url { return }
        history.insert(["url": url, "title": title, "ts": Date().timeIntervalSince1970 * 1000], at: 0)
        if history.count > 5000 { history = Array(history.prefix(5000)) }
        saveHistory()
    }

    func isBookmarked(_ url: String) -> Bool { bookmarks.contains { $0["url"] as? String == url } }
    func toggleBookmark(url: String, title: String) {
        guard !url.isEmpty, url.hasPrefix("http") else { return }
        if isBookmarked(url) { bookmarks.removeAll { $0["url"] as? String == url } }
        else { bookmarks.insert(["url": url, "title": title, "ts": Date().timeIntervalSince1970 * 1000], at: 0) }
        saveBookmarks()
    }

    func saveSettings() {
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: settingsURL)
        }
    }

    func savePins() {
        let arr = pins.map { ["url": $0.url, "title": $0.title] }
        if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]) {
            try? data.write(to: pinsURL)
        }
    }

    func settingsJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: settings),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    func string(_ key: String) -> String { settings[key] as? String ?? "" }
    func bool(_ key: String) -> Bool { settings[key] as? Bool ?? false }
    func int(_ key: String) -> Int { settings[key] as? Int ?? 0 }

    // MARK: - AI usage accounting (local estimate; exact billing lives on OpenAI)

    /// Add a request's token counts to the running totals (call on the main thread).
    func addAIUsage(input: Int, output: Int) {
        settings["aiUsageInput"] = int("aiUsageInput") + input
        settings["aiUsageOutput"] = int("aiUsageOutput") + output
        if int("aiUsageSince") == 0 { settings["aiUsageSince"] = Date().timeIntervalSince1970 * 1000 }
        saveSettings()
    }

    /// Zero the usage counters and restart the "since" date.
    func resetAIUsage() {
        settings["aiUsageInput"] = 0
        settings["aiUsageOutput"] = 0
        settings["aiUsageSince"] = Date().timeIntervalSince1970 * 1000
        saveSettings()
    }
}
