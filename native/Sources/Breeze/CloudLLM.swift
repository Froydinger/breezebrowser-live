// Breeze Cloud backend. Provider selection lives server-side so the app does
// not expose model IDs or provider credentials.

import Foundation

final class CloudLLM: NSObject {
    weak var browser: (any BrowserAITools)?
    var onStatus: ((String) -> Void)?

    private let cloudBaseURL = CloudLLM.configuredURL("BREEZE_CLOUD_AI_BASE_URL", plistKey: "BreezeCloudAIBaseURL")
    private let cloudClientToken = CloudLLM.configuredString("BREEZE_CLOUD_CLIENT_TOKEN", plistKey: "BreezeCloudClientToken")

    private(set) var lastStatus = ""

    var usingCloud: Bool { cloudBaseURL != nil }

    /// "Ready" means this build has Breeze Cloud configured.
    var ready: Bool { usingCloud }

    init(tools: any BrowserAITools) {
        super.init()
        browser = tools
        lastStatus = usingCloud
            ? "Nav is ready."
            : "Nav is not configured in this build."
    }

    func cacheKey(_ key: String) {}

    func resetChat() {}
    func shutdown() {}

    private func setStatus(_ s: String) {
        lastStatus = s
        if Thread.isMainThread { onStatus?(s) }
        else { DispatchQueue.main.async { self.onStatus?(s) } }
    }

    // MARK: - Chat

    func send(_ text: String, history: [[String: String]], contexts: [AIContext],
              completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        guard usingCloud else {
            completion(.failure(Self.error("Nav is not configured in this build.")))
            return
        }

        guard let tools = browser else {
            completion(.failure(Self.error("Nav isn't ready yet.")))
            return
        }

        let turnID = UUID().uuidString
        Task {
            do {
                var turnHistory: [[String: String]] = [
                    ["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))]
                ]
                for msg in history {
                    let role = msg["role"] == "ai" ? "assistant" : "user"
                    if let content = msg["text"] { turnHistory.append(["role": role, "content": content]) }
                }
                let (answer, chips) = try await Agent.run(
                    userText: text, contexts: contexts, tools: tools,
                    ask: { msg in
                        turnHistory.append(["role": "user", "content": msg])
                        let reply = try await self.complete(history: turnHistory, requestID: turnID)
                        turnHistory.append(["role": "assistant", "content": reply])
                        return reply
                    },
                    askFresh: { msg in
                        let freshHistory: [[String: String]] = [
                            ["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))],
                            ["role": "user", "content": msg]
                        ]
                        return try await self.complete(history: freshHistory, requestID: turnID)
                    })
                await MainActor.run { completion(.success((answer, chips))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func complete(history: [[String: String]], minimal: Bool = false, requestID: String) async throws -> String {
        guard let url = endpoint(path: "/v1/chat/completions") else {
            throw Self.error("Nav is not configured in this build.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req, requestID: requestID)
        req.timeoutInterval = 120

        var body: [String: Any] = ["messages": history]
        if !minimal {
            body["max_completion_tokens"] = 2400
            body["reasoning_effort"] = "low"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Self.error("No response from Breeze Cloud.")
        }
        if http.statusCode == 400 && !minimal {
            return try await complete(history: history, minimal: true, requestID: requestID)
        }
        guard http.statusCode == 200 else {
            throw Self.error(Self.friendlyError(status: http.statusCode, data: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw Self.error("Unexpected response from Breeze Cloud.")
        }
        if let usage = json["usage"] as? [String: Any] {
            let inTok = usage["prompt_tokens"] as? Int ?? 0
            let outTok = usage["completion_tokens"] as? Int ?? 0
            if inTok > 0 || outTok > 0 {
                await MainActor.run { Store.shared.addAIUsage(input: inTok, output: outTok) }
            }
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Auth/config helpers

    private func endpoint(path: String) -> URL? {
        guard let cloudBaseURL else { return nil }
        return cloudBaseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func applyAuth(to req: inout URLRequest, requestID: String) {
        if let token = cloudClientToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(cloudClientId(), forHTTPHeaderField: "X-Breeze-Client-Id")
        req.setValue(requestID, forHTTPHeaderField: "X-Breeze-Request-Id")
    }

    private func cloudClientId() -> String {
        let key = "aiCloudClientId"
        let existing = Store.shared.string(key)
        if !existing.isEmpty { return existing }
        let created = UUID().uuidString
        Store.shared.settings[key] = created
        Store.shared.saveSettings()
        return created
    }

    private static func configuredURL(_ envKey: String, plistKey: String) -> URL? {
        guard let value = configuredString(envKey, plistKey: plistKey), !value.isEmpty else { return nil }
        return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func configuredString(_ envKey: String, plistKey: String) -> String? {
        if let env = ProcessInfo.processInfo.environment[envKey], !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Bundle.main.object(forInfoDictionaryKey: plistKey) as? String
    }

    private static func friendlyError(status: Int, data: Data) -> String {
        var apiMessage = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = json["error"] as? [String: Any],
               let m = err["message"] as? String { apiMessage = m }
            else if let err = json["error"] as? String { apiMessage = err }
        }
        if status == 401 {
            return "Breeze Cloud rejected this app build."
        }
        if status == 429 {
            return apiMessage.isEmpty ? "Daily AI limit reached. Try again tomorrow." : apiMessage
        }
        return apiMessage.isEmpty ? "Breeze Cloud request failed (HTTP \(status))." : apiMessage
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Breeze", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
