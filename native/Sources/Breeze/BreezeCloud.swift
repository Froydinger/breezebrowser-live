import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import os
import Security
import UserNotifications

struct BreezeCloudSyncPreferences: Codable {
    var bookmarks = false
    var tabs = false
    var history = false
    var chats = false
    var reminders = false

    static let collections = ["bookmarks", "tabs", "history", "chats", "reminders"]

    init(json: [String: Any] = [:]) {
        bookmarks = json["bookmarks"] as? Bool ?? false
        tabs = json["tabs"] as? Bool ?? false
        history = json["history"] as? Bool ?? false
        chats = json["chats"] as? Bool ?? false
        reminders = json["reminders"] as? Bool ?? false
    }

    init(bookmarks: Bool, tabs: Bool, history: Bool, chats: Bool, reminders: Bool) {
        self.bookmarks = bookmarks
        self.tabs = tabs
        self.history = history
        self.chats = chats
        self.reminders = reminders
    }

    func enabled(_ name: String) -> Bool {
        switch name {
        case "bookmarks": bookmarks
        case "tabs": tabs
        case "history": history
        case "chats": chats
        case "reminders": reminders
        default: false
        }
    }

    mutating func set(_ name: String, enabled: Bool) {
        switch name {
        case "bookmarks": bookmarks = enabled
        case "tabs": tabs = enabled
        case "history": history = enabled
        case "chats": chats = enabled
        case "reminders": reminders = enabled
        default: break
        }
    }
}

let breezeCloudRedirectURI = Bundle.main.object(forInfoDictionaryKey: "BreezeCloudRedirectURI") as? String
    ?? "com.froydinger.breeze://auth-callback"
let breezeCloudRedirectScheme = URLComponents(string: breezeCloudRedirectURI)?.scheme?.lowercased()
    ?? "com.froydinger.breeze"

/// URL parsers represent custom-scheme callbacks inconsistently across the
/// browser and Launch Services. Accept both the authority form
/// (`scheme://auth-callback`) and its path form (`scheme:/auth-callback`),
/// while requiring the callback scheme embedded in this app build.
func isBreezeAuthCallbackURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == breezeCloudRedirectScheme,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
    if components.host?.lowercased() == "auth-callback" {
        return components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }
    return components.host == nil
        && components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == "auth-callback"
}

private struct BreezeCloudVersion: Codable {
    var fingerprint: String
    var updatedAt: Int64
}

private struct BreezeCloudTabIdentity: Codable {
    var id: String
    var title: String
    var lastAccessedAt: Int64
}

private struct BreezeCloudSyncState: Codable {
    var versions: [String: [String: BreezeCloudVersion]] = [:]
    var deletedIds: [String: [String]] = [:]
    var tabsByURL: [String: [BreezeCloudTabIdentity]] = [:]
    var cloudChatIDByLocalID: [String: String] = [:]
    var localChatIDByCloudID: [String: Double] = [:]
}

/// Direct Supabase Auth + PostgREST client for the native browser. The app only
/// embeds the public project key; user tokens live in Keychain and passwords are
/// sent once over TLS, never saved by Breeze.
@MainActor
final class BreezeCloud: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = BreezeCloud()
    static let stateDidChange = Notification.Name("BreezeCloudStateDidChange")
    static var redirectURI: String { breezeCloudRedirectURI }
    static var redirectScheme: String { breezeCloudRedirectScheme }

    private let projectURL = "https://sbvjjseitpahdpewsqqc.supabase.co"
    private let authLogger = Logger(subsystem: "com.froydinger.breeze", category: "BreezeCloudAuth")
    private let publicKey: String
    private let keychainService: String
    private var session: [String: Any]
    private var preferences = BreezeCloudSyncPreferences()
    private var syncState = BreezeCloudSyncState()
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var authenticationSession: ASWebAuthenticationSession?
    private weak var pendingGoogleAuthBrowser: BrowserController?
    private var pendingGoogleAuthTabID: UUID?
    private var pendingGoogleAuthPreviousTabID: UUID?
    private var statusText = "Not signed in"

    private var syncStateURL: URL { Store.shared.supportDirectory.appendingPathComponent("cloud-sync-state.json") }
    private var accessToken: String { session["access_token"] as? String ?? "" }
    private var refreshToken: String { session["refresh_token"] as? String ?? "" }
    private var userID: String { session["user_id"] as? String ?? "" }
    private var email: String { session["email"] as? String ?? "" }
    private var expiresAt: TimeInterval { session["expires_at"] as? TimeInterval ?? 0 }
    var signedIn: Bool { !accessToken.isEmpty && !userID.isEmpty }
    var configured: Bool { projectURL.hasPrefix("https://") && !publicKey.isEmpty }

    private override init() {
        publicKey = Bundle.main.infoDictionary?["BreezeCloudSupabaseAnonKey"] as? String ?? ""
        keychainService = "\(Bundle.main.bundleIdentifier ?? "com.froydinger.breeze").cloud-session"
        session = Self.readKeychain(service: keychainService)
        let stateURL = Store.shared.supportDirectory.appendingPathComponent("cloud-sync-state.json")
        if let data = try? Data(contentsOf: stateURL),
           let state = try? JSONDecoder().decode(BreezeCloudSyncState.self, from: data) {
            syncState = state
        }
        if let saved = session["sync_preferences"] as? [String: Any] { preferences = BreezeCloudSyncPreferences(json: saved) }
        super.init()
    }

    func state() -> [String: Any] {
        ["configured": configured, "signedIn": signedIn, "email": email,
         "status": statusText, "preferences": preferences.dictionary]
    }

    func refreshState() async -> [String: Any] {
        if signedIn {
            do { try await loadPreferences() }
            catch { setStatus("Could not refresh cloud settings") }
        } else if !configured {
            setStatus("Cloud sign-in is not configured in this build")
        }
        return state()
    }

    func signUp(email address: String, password: String) async throws -> String {
        try requireConfigured()
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.contains("@") else { throw cloudError("Enter a valid email address.") }
        guard password.count >= 8 else { throw cloudError("Use a password with at least 8 characters.") }
        let verifier = makeVerifier()
        session["pending_verifier"] = verifier
        try saveKeychain()
        var components = URLComponents(string: projectURL + "/auth/v1/signup")!
        components.queryItems = [
            URLQueryItem(name: "redirect_to", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: makeChallenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256")
        ]
        let value = try await request("POST", components.string!, body: ["email": address, "password": password])
        if let payload = value as? [String: Any], !(payload["access_token"] as? String ?? "").isEmpty {
            try persistSession(payload)
            try await loadPreferences()
            setStatus("Signed in")
            return "Your Breeze account is ready."
        }
        setStatus("Check your email to finish creating your account")
        return "Check your email to confirm your account. Breeze will finish signing you in when you open the confirmation link."
    }

    func signIn(email address: String, password: String) async throws {
        try requireConfigured()
        let value = try await request("POST", projectURL + "/auth/v1/token?grant_type=password",
                                      body: ["email": address.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        guard let payload = value as? [String: Any] else { throw cloudError("Breeze received an invalid sign-in response.") }
        try persistSession(payload)
        try await syncNow()
    }

    /// Starts Google sign-in with AuthenticationServices. On macOS builds where
    /// the system reports the original authorize URL as the callback (instead of
    /// calling the browser's `begin` handler), continue that exact request in a
    /// normal Breeze tab and finish through the same PKCE deep-link callback.
    /// Other unexpected URLs still fail closed.
    func signInWithGoogle(in browser: BrowserController) async throws -> Bool {
        try requireConfigured()
        guard authenticationSession == nil else {
            throw cloudError("Google sign-in is already in progress.")
        }
        if let pendingGoogleAuthTabID,
           let pendingGoogleAuthBrowser,
           pendingGoogleAuthBrowser.tabs.contains(where: { $0.id == pendingGoogleAuthTabID }) {
            throw cloudError("Finish the Google sign-in already open in Breeze first.")
        }
        clearPendingGoogleAuthTab()
        let verifier = makeVerifier()
        session["pending_verifier"] = verifier
        try saveKeychain()
        var components = URLComponents(string: projectURL + "/auth/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: makeChallenge(verifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]
        guard let url = components.url else { throw cloudError("Could not open Google sign-in.") }
        authLogger.info("Opening Google OAuth with account selection enabled")
        setStatus("Waiting for Google sign-in in Breeze…")
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            let completion: (URL?, Error?) -> Void = { [weak self] callbackURL, error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: NSError(domain: "BreezeCloud", code: 1,
                                                              userInfo: [NSLocalizedDescriptionKey: "Breeze closed before sign-in finished."]))
                        return
                    }
                    self.authenticationSession = nil
                    if let callbackURL, callbackURL.absoluteString == url.absoluteString {
                        self.authLogger.notice("AuthenticationServices returned the authorize start URL; continuing in a Breeze tab")
                        self.openGoogleAuthTab(url, in: browser)
                        self.setStatus("Finish Google sign-in in the Breeze tab")
                        continuation.resume(returning: false)
                        return
                    }
                    if let error {
                        self.setStatus("Google sign-in was canceled")
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let callbackURL else {
                        continuation.resume(throwing: self.cloudError("Google sign-in did not return to Breeze."))
                        return
                    }
                    do {
                        try await self.finishAuthCallback(callbackURL)
                        self.setStatus("Signed in with Google")
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            let session: ASWebAuthenticationSession
            if #available(macOS 14.4, *) {
                // Use Apple's explicit callback matcher so the browser session
                // handler receives the exact redirect contract. The legacy
                // callbackURLScheme initializer has produced the authorize
                // start URL as a false completion in browser-handler flows.
                let callback = ASWebAuthenticationSession.Callback.customScheme(Self.redirectScheme)
                session = ASWebAuthenticationSession(url: url, callback: callback,
                                                     completionHandler: completion)
            } else {
                session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.redirectScheme,
                                                     completionHandler: completion)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                authenticationSession = nil
                continuation.resume(throwing: cloudError("Breeze could not start Google sign-in."))
                return
            }
        }
    }

    private func openGoogleAuthTab(_ url: URL, in browser: BrowserController) {
        let previousTabID = browser.current?.id
        let tab = browser.openTab(url: url.absoluteString, playSound: false)
        pendingGoogleAuthBrowser = browser
        pendingGoogleAuthTabID = tab.id
        pendingGoogleAuthPreviousTabID = previousTabID
    }

    private func clearPendingGoogleAuthTab() {
        pendingGoogleAuthBrowser = nil
        pendingGoogleAuthTabID = nil
        pendingGoogleAuthPreviousTabID = nil
    }

    private func restoreAfterGoogleAuthTab() {
        guard let browser = pendingGoogleAuthBrowser,
              let tabID = pendingGoogleAuthTabID else {
            clearPendingGoogleAuthTab()
            return
        }
        let previousTabID = pendingGoogleAuthPreviousTabID
        clearPendingGoogleAuthTab()
        if let tab = browser.tabs.first(where: { $0.id == tabID }) {
            browser.closeTab(tab)
        }
        if let previousTabID,
           let index = browser.tabs.firstIndex(where: { $0.id == previousTabID }) {
            browser.select(index)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let keyWindow = NSApp.keyWindow { return keyWindow }
        if let browser = (NSApp.delegate as? AppDelegate)?.activeBrowser { return browser.window }
        return NSApp.windows.first ?? NSWindow()
    }

    func finishAuthCallback(_ url: URL) async throws {
        defer {
            if isBreezeAuthCallbackURL(url) { restoreAfterGoogleAuthTab() }
        }
        guard isBreezeAuthCallbackURL(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // Do not include the callback's query or fragment here: either can
            // carry OAuth codes or tokens.
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let scheme = parts?.scheme ?? "missing"
            let host = parts?.host ?? "none"
            let path = parts?.path ?? "none"
            authLogger.error("Auth returned a non-callback URL: \(scheme, privacy: .public)://\(host, privacy: .public)\(path, privacy: .public)")
            throw cloudError("Breeze received an unexpected sign-in callback (\(scheme), \(host), \(path)). Start Google sign-in again.")
        }
        let parameters = callbackParameters(from: parts)
        if let error = parameters["error_description"] ?? parameters["error"] {
            throw cloudError(String(error.prefix(220)))
        }
        if let code = parameters["code"] {
            let verifier = session["pending_verifier"] as? String ?? ""
            guard !verifier.isEmpty else { throw cloudError("This sign-in link has expired. Start sign-in again in Breeze.") }
            let value = try await request("POST", projectURL + "/auth/v1/token?grant_type=pkce",
                                          body: ["auth_code": code, "code_verifier": verifier])
            guard let payload = value as? [String: Any] else { throw cloudError("Breeze received an invalid sign-in response.") }
            try persistSession(payload)
            try await syncNow()
            return
        }
        if let tokenHash = parameters["token_hash"] {
            let type = parameters["type"] ?? "signup"
            let value = try await request("POST", projectURL + "/auth/v1/verify", body: ["token_hash": tokenHash, "type": type])
            if let payload = value as? [String: Any], payload["access_token"] != nil {
                try persistSession(payload)
                try await syncNow()
            }
            return
        }
        throw cloudError("This Breeze sign-in link is incomplete. Start sign-in again.")
    }

    private func callbackParameters(from parts: URLComponents) -> [String: String] {
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value
        }
        // Some OAuth providers and callback handlers return parameters after
        // `#` instead of `?`. PKCE codes normally use the query, but accepting
        // either form prevents a valid callback from being lost in transit.
        if let fragment = parts.fragment {
            let query = fragment.hasPrefix("?") ? String(fragment.dropFirst()) : fragment
            if let fragmentParts = URLComponents(string: "https://callback.invalid/?\(query)") {
                for item in fragmentParts.queryItems ?? [] where values[item.name] == nil {
                    values[item.name] = item.value
                }
            }
        }
        return values
    }

    func setSyncPreference(_ collection: String, enabled: Bool) async throws {
        guard BreezeCloudSyncPreferences.collections.contains(collection) else { throw cloudError("Unknown sync category.") }
        try requireSignedIn()
        try await loadPreferences()
        var next = preferences
        next.set(collection, enabled: enabled)
        let payload = next.dictionary.merging(["user_id": userID]) { _, new in new }
        _ = try await request("POST", projectURL + "/rest/v1/breeze_sync_preferences?on_conflict=user_id",
                              body: payload, token: try await validAccessToken(), prefer: "resolution=merge-duplicates,return=minimal")
        preferences = next
        session["sync_preferences"] = next.dictionary
        try saveKeychain()
        if enabled { try await syncCollection(collection) }
        else { setStatus("Sync paused for \(collection)") }
        postStateChange()
    }

    func syncNow() async throws {
        try requireSignedIn()
        try await loadPreferences()
        setStatus("Syncing selected data…")
        var count = 0
        do {
            for collection in BreezeCloudSyncPreferences.collections where preferences.enabled(collection) {
                try await syncCollection(collection)
                count += 1
            }
            setStatus(count == 0 ? "No sync categories selected" : "Synced just now")
        } catch {
            setStatus("Sync paused until connected")
            throw error
        }
    }

    func signOut() async {
        let enabled = BreezeCloudSyncPreferences.collections.filter { preferences.enabled($0) }
        if signedIn { _ = try? await request("POST", projectURL + "/auth/v1/logout", body: [:], token: try? await validAccessToken()) }
        session = [:]
        preferences = BreezeCloudSyncPreferences()
        try? saveKeychain()
        clearLocalSyncedData(enabled)
        setStatus("Signed out")
    }

    func deleteAccount() async throws {
        try requireSignedIn()
        let token = try await validAccessToken()
        _ = try await request("POST", projectURL + "/functions/v1/delete-account", body: [:], token: token)
        clearLocalSyncedData(BreezeCloudSyncPreferences.collections)
        session = [:]
        preferences = BreezeCloudSyncPreferences()
        syncState = BreezeCloudSyncState()
        try? FileManager.default.removeItem(at: syncStateURL)
        try saveKeychain()
        setStatus("Breeze account deleted")
    }

    func exportCloudData() async throws -> [String: Any] {
        try requireSignedIn()
        let token = try await validAccessToken()
        var collections: [String: Any] = [:]
        for name in BreezeCloudSyncPreferences.collections {
            let rows = try await request("GET", projectURL + "/rest/v1/breeze_sync_collections?select=payload&user_id=eq.\(userID)&collection=eq.\(name)&limit=1", token: token)
            let values = rows as? [[String: Any]] ?? []
            collections[name] = values.first?["payload"] ?? ["formatVersion": 1, "entries": [], "deletedIds": []]
        }
        return ["format": "Breeze Cloud export", "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "account": email, "collections": collections,
                "note": "Passwords and private browsing data are not included."]
    }

    func scheduleSync(collection: String) {
        guard signedIn, preferences.enabled(collection), BreezeCloudSyncPreferences.collections.contains(collection) else { return }
        syncTasks[collection]?.cancel()
        syncTasks[collection] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                try await self.syncCollection(collection)
            } catch {
                guard !Task.isCancelled else { return }
                self?.setStatus("Sync paused until connected")
            }
        }
    }

    func resumeAndSync() async {
        guard signedIn else { return }
        do { try await syncNow() }
        catch { setStatus("Waiting for a connection") }
    }

    // MARK: - Sync protocol (formatVersion 1; compatible with Breeze Android)

    private func syncCollection(_ collection: String) async throws {
        guard preferences.enabled(collection) else { return }
        let token = try await validAccessToken()
        setStatus("Syncing \(collection)…")
        let remoteRows = try await request("GET", projectURL + "/rest/v1/breeze_sync_collections?select=payload&user_id=eq.\(userID)&collection=eq.\(collection)&limit=1", token: token) as? [[String: Any]] ?? []
        let remote = remoteRows.first?["payload"] as? [String: Any] ?? ["formatVersion": 1, "entries": [], "deletedIds": []]
        let merged = merge(collection: collection, remote: remote)
        if canonicalJSON(merged) != canonicalJSON(remote) {
            _ = try await request("POST", projectURL + "/rest/v1/breeze_sync_collections?on_conflict=user_id,collection",
                                  body: ["user_id": userID, "collection": collection, "payload": merged], token: token,
                                  prefer: "resolution=merge-duplicates,return=minimal")
        }
        setStatus("Synced just now")
    }

    private func merge(collection: String, remote: [String: Any]) -> [String: Any] {
        let local = snapshot(collection)
        var deleted = Set(local["deletedIds"] as? [String] ?? [])
        deleted.formUnion(remote["deletedIds"] as? [String] ?? [])
        var merged: [String: [String: Any]] = [:]
        func collect(_ entries: [[String: Any]]?) {
            for var entry in entries ?? [] {
                guard let id = entry["id"] as? String, !id.isEmpty, !deleted.contains(id), valid(entry, collection: collection) else { continue }
                if let old = merged[id] { entry = mergeEntry(collection, old, entry) }
                merged[id] = entry
            }
        }
        collect(local["entries"] as? [[String: Any]])
        collect(remote["entries"] as? [[String: Any]])
        deleted.forEach { merged.removeValue(forKey: $0); syncState.versions[collection]?.removeValue(forKey: $0) }
        let entries = merged.values.sorted { sortTime(collection, $0) > sortTime(collection, $1) }
        for entry in entries { recordVersion(collection, entry) }
        syncState.deletedIds[collection] = Array(deleted).sorted()
        apply(collection, entries: entries)
        saveSyncState()
        return ["formatVersion": 1, "entries": entries, "deletedIds": Array(deleted).sorted()]
    }

    private func snapshot(_ collection: String) -> [String: Any] {
        var rows = localEntries(collection)
        let ids = Set(rows.compactMap { $0["id"] as? String })
        var tombstones = Set(syncState.deletedIds[collection] ?? [])
        for known in syncState.versions[collection]?.keys ?? Dictionary<String, BreezeCloudVersion>().keys where !ids.contains(known) {
            tombstones.insert(known)
        }
        rows = rows.map { versioned(collection, $0) }
        syncState.deletedIds[collection] = Array(tombstones).sorted()
        saveSyncState()
        return ["formatVersion": 1, "entries": rows, "deletedIds": Array(tombstones).sorted()]
    }

    private func localEntries(_ collection: String) -> [[String: Any]] {
        let store = Store.shared
        switch collection {
        case "bookmarks", "history":
            let values = collection == "bookmarks" ? store.bookmarks : store.history
            return values.compactMap { entry in
                guard let url = entry["url"] as? String, isWebURL(url) else { return nil }
                let time = number(entry["time"]) ?? number(entry["ts"]) ?? Date().timeIntervalSince1970 * 1000
                let title = entry["title"] as? String ?? URL(string: url)?.host ?? url
                let id = entry["id"] as? String ?? stableID(collection + "|" + url + "|" + String(time))
                return ["id": id, "title": title, "url": url, "time": Int64(time)]
            }
        case "tabs":
            var used: [String: Int] = [:]
            return store.openTabs.compactMap { url in
                guard isWebURL(url) else { return nil }
                let occurrence = used[url, default: 0]
                used[url] = occurrence + 1
                var known = syncState.tabsByURL[url] ?? []
                let identity: BreezeCloudTabIdentity
                let deleted = Set(syncState.deletedIds["tabs"] ?? [])
                if occurrence < known.count, !deleted.contains(known[occurrence].id) {
                    identity = known[occurrence]
                } else {
                    let fresh = BreezeCloudTabIdentity(id: UUID().uuidString, title: URL(string: url)?.host ?? url,
                                                      lastAccessedAt: Int64(Date().timeIntervalSince1970 * 1000))
                    if occurrence < known.count { known[occurrence] = fresh }
                    else { known.append(fresh) }
                    identity = fresh
                    syncState.tabsByURL[url] = known
                }
                return ["id": identity.id, "title": identity.title, "url": url, "lastAccessedAt": identity.lastAccessedAt]
            }
        case "chats":
            return store.chats.compactMap { chat in
                guard let localID = number(chat["id"]) else { return nil }
                let localKey = String(format: "%.0f", localID)
                let cloudID = syncState.cloudChatIDByLocalID[localKey] ?? "mac-chat-\(localKey)"
                syncState.cloudChatIDByLocalID[localKey] = cloudID
                syncState.localChatIDByCloudID[cloudID] = localID
                let messages = (chat["messages"] as? [[String: Any]] ?? []).compactMap { item -> [String: String]? in
                    guard let role = item["role"] as? String, let text = item["text"] as? String else { return nil }
                    return ["role": role, "text": String(text.prefix(24_000))]
                }
                let time = number(chat["time"]) ?? localID * 1000
                var row: [String: Any] = ["id": cloudID, "title": chat["title"] as? String ?? "Conversation",
                                          "time": Int64(time), "messages": messages]
                if let sources = chat["sources"] as? [[String: Any]] {
                    row["sources"] = Array(sources.compactMap { source -> [String: String]? in
                        guard let url = source["url"] as? String, isWebURL(url) else { return nil }
                        return ["title": String((source["title"] as? String ?? "").prefix(500)),
                                "url": String(url.prefix(4096))]
                    }.suffix(100))
                }
                if let finished = chat["finishedReplies"] as? [Int] { row["finishedReplies"] = finished }
                if let prompt = chat["pendingReminderPrompt"] as? String { row["pendingReminderPrompt"] = prompt }
                return row
            }
        case "reminders":
            return (store.settings["reminders"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                let title = item["title"] as? String ?? item["label"] as? String ?? ""
                let due = number(item["dueAt"]) ?? number(item["fireAt"]) ?? 0
                guard !title.isEmpty, due > 0 else { return nil }
                return ["id": id, "title": title, "dueAt": Int64(due),
                        "repeat": item["repeat"] as? String ?? "NONE",
                        "repeatDayOfMonth": item["repeatDayOfMonth"] ?? NSNull(),
                        "deliveredAt": item["deliveredAt"] ?? NSNull()]
            }
        default: return []
        }
    }

    private func apply(_ collection: String, entries: [[String: Any]]) {
        Store.shared.suppressCloudSync = true
        defer { Store.shared.suppressCloudSync = false }
        switch collection {
        case "bookmarks", "history":
            let rows = entries.compactMap { entry -> [String: Any]? in
                guard let id = entry["id"] as? String, let url = entry["url"] as? String, isWebURL(url) else { return nil }
                return ["id": id, "url": url, "title": entry["title"] as? String ?? URL(string: url)?.host ?? url,
                        "ts": number(entry["time"]) ?? Date().timeIntervalSince1970 * 1000]
            }
            if collection == "bookmarks" { Store.shared.bookmarks = rows; Store.shared.saveBookmarks() }
            else { Store.shared.history = Array(rows.prefix(5000)); Store.shared.saveHistory() }
        case "tabs":
            var byURL: [String: [BreezeCloudTabIdentity]] = [:]
            for entry in entries {
                guard let id = entry["id"] as? String, let url = entry["url"] as? String, isWebURL(url) else { continue }
                let identity = BreezeCloudTabIdentity(id: id, title: entry["title"] as? String ?? URL(string: url)?.host ?? url,
                                                      lastAccessedAt: Int64(number(entry["lastAccessedAt"]) ?? 0))
                byURL[url, default: []].append(identity)
            }
            syncState.tabsByURL = byURL
            Store.shared.openTabs = entries.sorted { sortTime("tabs", $0) < sortTime("tabs", $1) }
                .compactMap { $0["url"] as? String }.filter(isWebURL)
            Store.shared.saveOpenTabs()
        case "chats":
            let chats: [[String: Any]] = entries.compactMap { entry in
                guard let cloudID = entry["id"] as? String else { return nil }
                let localID: Double
                if let saved = syncState.localChatIDByCloudID[cloudID] { localID = saved }
                else if cloudID.hasPrefix("mac-chat-"), let value = Double(cloudID.dropFirst("mac-chat-".count)) { localID = value }
                else { localID = stableNumericID(cloudID) }
                syncState.localChatIDByCloudID[cloudID] = localID
                syncState.cloudChatIDByLocalID[String(format: "%.0f", localID)] = cloudID
                let messages = (entry["messages"] as? [[String: Any]] ?? []).compactMap { item -> [String: String]? in
                    guard let role = item["role"] as? String, let text = item["text"] as? String else { return nil }
                    return ["role": role, "text": String(text.prefix(24_000))]
                }
                var row: [String: Any] = ["id": localID, "title": entry["title"] as? String ?? "Conversation",
                                          "time": number(entry["time"]) ?? localID * 1000, "messages": messages]
                if let sources = entry["sources"] { row["sources"] = sources }
                if let finished = entry["finishedReplies"] { row["finishedReplies"] = finished }
                if let prompt = entry["pendingReminderPrompt"] { row["pendingReminderPrompt"] = prompt }
                return row
            }
            Store.shared.chats = chats.sorted { (number($0["time"]) ?? 0) > (number($1["time"]) ?? 0) }
            Store.shared.saveChats()
        case "reminders":
            let values: [[String: Any]] = entries.compactMap { entry in
                guard let id = entry["id"] as? String, let title = entry["title"] as? String,
                      let due = number(entry["dueAt"]), due > 0 else { return nil }
                return ["id": id, "label": title, "fireAt": due,
                        "repeat": entry["repeat"] as? String ?? "NONE",
                        "repeatDayOfMonth": entry["repeatDayOfMonth"] ?? NSNull(),
                        "deliveredAt": entry["deliveredAt"] ?? NSNull()]
            }
            Store.shared.settings["reminders"] = values
            Store.shared.saveSettings()
            let center = UNUserNotificationCenter.current()
            for reminder in values {
                guard let id = reminder["id"] as? String, let due = number(reminder["fireAt"]), due > Date().timeIntervalSince1970 * 1000 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Breeze reminder"
                content.body = reminder["label"] as? String ?? "Reminder"
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, (due - Date().timeIntervalSince1970 * 1000) / 1000), repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        default: break
        }
        saveSyncState()
    }

    private func versioned(_ collection: String, _ entry: [String: Any]) -> [String: Any] {
        guard let id = entry["id"] as? String else { return entry }
        let fingerprint = digest(canonicalJSON(entry))
        let previous = syncState.versions[collection]?[id]
        let updatedAt = previous?.fingerprint == fingerprint ? previous!.updatedAt : Int64(Date().timeIntervalSince1970 * 1000)
        syncState.versions[collection, default: [:]][id] = BreezeCloudVersion(fingerprint: fingerprint, updatedAt: updatedAt)
        var result = entry
        result["_updatedAt"] = updatedAt
        return result
    }

    private func recordVersion(_ collection: String, _ entry: [String: Any]) {
        guard let id = entry["id"] as? String else { return }
        var raw = entry
        raw.removeValue(forKey: "_updatedAt")
        syncState.versions[collection, default: [:]][id] = BreezeCloudVersion(
            fingerprint: digest(canonicalJSON(raw)), updatedAt: Int64(number(entry["_updatedAt"]) ?? Date().timeIntervalSince1970 * 1000))
    }

    private func mergeEntry(_ collection: String, _ local: [String: Any], _ remote: [String: Any]) -> [String: Any] {
        let localVersion = number(local["_updatedAt"]) ?? 0
        let remoteVersion = number(remote["_updatedAt"]) ?? 0
        var result = remoteVersion > localVersion ? remote : local
        guard collection == "chats" else { return result }
        result["messages"] = mergeArray(local["messages"], remote["messages"], key: { "\($0["role"] as? String ?? "")\u{1f}\($0["text"] as? String ?? "")" })
        result["sources"] = mergeArray(local["sources"], remote["sources"], key: { "\($0["title"] as? String ?? "")\u{1f}\($0["url"] as? String ?? "")" })
        let finished = Set((local["finishedReplies"] as? [Int] ?? []) + (remote["finishedReplies"] as? [Int] ?? [])).sorted()
        result["finishedReplies"] = finished
        if (result["pendingReminderPrompt"] as? String ?? "").isEmpty {
            result["pendingReminderPrompt"] = local["pendingReminderPrompt"] ?? remote["pendingReminderPrompt"]
        }
        result["_updatedAt"] = max(localVersion, remoteVersion)
        return result
    }

    private func mergeArray(_ local: Any?, _ remote: Any?, key: ([String: Any]) -> String) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var seen = Set<String>()
        for item in (local as? [[String: Any]] ?? []) + (remote as? [[String: Any]] ?? []) {
            let id = key(item)
            if !id.isEmpty && seen.insert(id).inserted { result.append(item) }
        }
        return result
    }

    private func valid(_ entry: [String: Any], collection: String) -> Bool {
        guard let id = entry["id"] as? String, !id.isEmpty, id.count <= 128 else { return false }
        if ["bookmarks", "history", "tabs"].contains(collection) {
            let url = entry["url"] as? String ?? ""
            return url.isEmpty && collection == "tabs" || isWebURL(url)
        }
        if collection == "reminders" { return !(entry["title"] as? String ?? "").isEmpty && (number(entry["dueAt"]) ?? 0) > 0 }
        if collection == "chats" { return (entry["messages"] as? [[String: Any]] ?? []).count <= 2000 }
        return false
    }

    private func sortTime(_ collection: String, _ entry: [String: Any]) -> Double {
        switch collection {
        case "tabs": number(entry["lastAccessedAt"]) ?? 0
        case "reminders": number(entry["dueAt"]) ?? 0
        default: number(entry["time"]) ?? 0
        }
    }

    // MARK: - Supabase requests and session

    private func loadPreferences() async throws {
        try requireSignedIn()
        let token = try await validAccessToken()
        let rows = try await request("GET", projectURL + "/rest/v1/breeze_sync_preferences?select=*&user_id=eq.\(userID)&limit=1", token: token) as? [[String: Any]] ?? []
        if let row = rows.first {
            preferences = BreezeCloudSyncPreferences(
                bookmarks: row["bookmarks"] as? Bool ?? false, tabs: row["tabs"] as? Bool ?? false,
                history: row["history"] as? Bool ?? false, chats: row["chats"] as? Bool ?? false,
                reminders: row["reminders"] as? Bool ?? false)
        } else {
            preferences = BreezeCloudSyncPreferences()
            _ = try await request("POST", projectURL + "/rest/v1/breeze_sync_preferences?on_conflict=user_id",
                                  body: preferences.dictionary.merging(["user_id": userID]) { _, new in new }, token: token,
                                  prefer: "resolution=merge-duplicates,return=minimal")
        }
        session["sync_preferences"] = preferences.dictionary
        try saveKeychain()
        postStateChange()
    }

    private func validAccessToken() async throws -> String {
        try requireSignedIn()
        if expiresAt > Date().timeIntervalSince1970 + 60 { return accessToken }
        guard !refreshToken.isEmpty else { throw cloudError("Your sign-in expired. Sign in again.") }
        let value = try await request("POST", projectURL + "/auth/v1/token?grant_type=refresh_token", body: ["refresh_token": refreshToken])
        guard let payload = value as? [String: Any] else { throw cloudError("Breeze could not refresh your sign-in.") }
        try persistSession(payload)
        return accessToken
    }

    private func persistSession(_ value: [String: Any]) throws {
        let user = value["user"] as? [String: Any] ?? value
        let seconds = number(value["expires_in"]) ?? 3600
        session["access_token"] = value["access_token"] as? String ?? ""
        session["refresh_token"] = value["refresh_token"] as? String ?? ""
        session["expires_at"] = Date().timeIntervalSince1970 + seconds
        session["user_id"] = user["id"] as? String ?? ""
        session["email"] = user["email"] as? String ?? ""
        session.removeValue(forKey: "pending_verifier")
        session["sync_preferences"] = preferences.dictionary
        try saveKeychain()
        setStatus("Signed in")
    }

    private func request(_ method: String, _ rawURL: String, body: [String: Any]? = nil,
                         token: String? = nil, prefer: String? = nil) async throws -> Any {
        guard let url = URL(string: rawURL) else { throw cloudError("Breeze could not build a cloud request.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpMethod = method
        request.setValue(publicKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .fragmentsAllowed]) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw cloudError("Could not reach Breeze Cloud. Check your connection and try again.") }
        guard let http = response as? HTTPURLResponse else { throw cloudError("Breeze Cloud returned an invalid response.") }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let message = (object["msg"] as? String) ?? (object["message"] as? String)
                ?? (object["error_description"] as? String) ?? (object["error"] as? String)
            let safe = message.map { String($0.prefix(220)) } ?? "Request failed (\(http.statusCode))."
            throw cloudError(safe)
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) ?? [:]
    }

    private func requireConfigured() throws {
        guard configured else { throw cloudError("Breeze Cloud sign-in is not configured in this build.") }
    }

    private func requireSignedIn() throws {
        try requireConfigured()
        guard signedIn else { throw cloudError("Sign in to your Breeze account first.") }
    }

    private func clearLocalSyncedData(_ collections: [String]) {
        for collection in collections {
            switch collection {
            case "bookmarks": Store.shared.bookmarks = []; Store.shared.saveBookmarks()
            case "history": Store.shared.history = []; Store.shared.saveHistory()
            case "chats": Store.shared.chats = []; Store.shared.saveChats()
            case "tabs": Store.shared.openTabs = []; Store.shared.saveOpenTabs()
            case "reminders":
                let reminders = Store.shared.settings["reminders"] as? [[String: Any]] ?? []
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: reminders.compactMap { $0["id"] as? String })
                Store.shared.settings["reminders"] = []
                Store.shared.saveSettings()
            default: break
            }
            syncState.versions[collection] = [:]
            syncState.deletedIds[collection] = []
            if collection == "tabs" { syncState.tabsByURL = [:] }
            if collection == "chats" { syncState.cloudChatIDByLocalID = [:]; syncState.localChatIDByCloudID = [:] }
        }
        saveSyncState()
    }

    private func setStatus(_ value: String) { statusText = value; postStateChange() }
    private func postStateChange() {
        NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        (NSApp.delegate as? AppDelegate)?.broadcastCloudState()
    }
    private func saveSyncState() {
        guard let data = try? JSONEncoder().encode(syncState) else { return }
        try? data.write(to: syncStateURL, options: .atomic)
    }
    private func saveKeychain() throws {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: session, options: [.sortedKeys]) }
        catch { throw cloudError("Breeze could not secure your account session.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "session",
                                    kSecValueData as String: data]
        let status = SecItemUpdate([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: "session"] as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound, SecItemAdd(query as CFDictionary, nil) != errSecSuccess {
            throw cloudError("Breeze could not save your account session to Keychain.")
        } else if status != errSecSuccess && status != errSecItemNotFound {
            throw cloudError("Breeze could not update your Keychain session.")
        }
    }
    private static func readKeychain(service: String) -> [String: Any] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "session",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private func deleteKeychain() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: keychainService,
                       kSecAttrAccount as String: "session"] as CFDictionary)
    }

    private func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
    private func makeChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }
    private func stableID(_ value: String) -> String { digest(value).prefix(32).description }
    private func stableNumericID(_ value: String) -> Double {
        let hex = String(digest(value).prefix(13))
        return Double(UInt64(hex, radix: 16) ?? UInt64(Date().timeIntervalSince1970 * 1000))
    }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func canonicalJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    private func isWebURL(_ value: String) -> Bool {
        guard value.count <= 4096, let url = URL(string: value), let host = url.host, !host.isEmpty else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }
    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        if let number = value as? Int64 { return Double(number) }
        if let string = value as? String { return Double(string) }
        return nil
    }
    private func cloudError(_ message: String) -> NSError { NSError(domain: "BreezeCloud", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private extension BreezeCloudSyncPreferences {
    var dictionary: [String: Any] {
        ["bookmarks": bookmarks, "tabs": tabs, "history": history, "chats": chats, "reminders": reminders]
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
