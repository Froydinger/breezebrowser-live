// OpenAI BYOK backend. Breeze AI is powered by OpenAI's gpt-5.4-mini through the
// user's OWN API key (stored in the macOS Keychain). There is no local model and
// no bundled runtime. Agentic: the model drives the browser via the tiny text
// protocol in Agent.swift (OPEN/SEARCH/READ/CLICK/TYPE/REMIND) — we run each
// action and feed the result back until it returns a plain-language answer.
//
// Keychain hygiene: this backend NEVER reads the keychain just to report status.
// `ready` reflects the non-secret `aiKeyConnected` flag in settings; the actual
// key is only read from the keychain when the user actually sends a message. That
// keeps the macOS keychain password prompt from firing when Settings merely opens.

import Foundation

final class OpenAILLM: NSObject {
    weak var browser: (any BrowserAITools)?
    var onStatus: ((String) -> Void)?

    // The single, gated model. Breeze AI is BYOK-only and locked to gpt-5.4-mini.
    private let model = "gpt-5.4-mini"
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let keychainAccount = "openaiKey"

    private(set) var lastStatus = "Add your OpenAI API key in Settings → Breeze AI to start."

    /// "Ready" means a key has been connected. We read the cached, non-secret flag
    /// instead of the keychain so opening Settings never triggers a password prompt.
    var ready: Bool { Store.shared.bool("aiKeyConnected") }

    init(tools: any BrowserAITools) {
        super.init()
        browser = tools
    }

    // Kept for interface parity with the old local backend. Nothing to reset
    // (each send rebuilds the conversation) and nothing to shut down (no process).
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
        let key = Keychain.get(keychainAccount)
        guard !key.isEmpty else {
            completion(.failure(Self.error("Breeze AI needs your OpenAI API key. Add it in Settings → Breeze AI — there's a link there to create one.")))
            return
        }
        guard let tools = browser else {
            completion(.failure(Self.error("Breeze AI isn't ready yet.")))
            return
        }
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
                        let reply = try await self.complete(history: turnHistory, apiKey: key)
                        turnHistory.append(["role": "assistant", "content": reply])
                        return reply
                    },
                    askFresh: { msg in
                        let freshHistory: [[String: String]] = [
                            ["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))],
                            ["role": "user", "content": msg]
                        ]
                        return try await self.complete(history: freshHistory, apiKey: key)
                    })
                await MainActor.run { completion(.success((answer, chips))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// One round-trip to OpenAI. gpt-5.4-mini is a reasoning model: we send a lean
    /// body (no temperature/top_p — reasoning models reject non-default values) and
    /// cap output with max_completion_tokens. If OpenAI rejects an optional param
    /// (400), we retry once with the bare minimum so a future API tweak can't brick
    /// the assistant.
    private func complete(history: [[String: String]], apiKey: String, minimal: Bool = false) async throws -> String {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        var body: [String: Any] = ["model": model, "messages": history]
        if !minimal {
            body["max_completion_tokens"] = 2000
            body["reasoning_effort"] = "low"   // keep agentic steps snappy
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Self.error("No response from OpenAI.")
        }
        if http.statusCode == 400 && !minimal {
            // An optional parameter wasn't accepted — retry with model + messages only.
            return try await complete(history: history, apiKey: apiKey, minimal: true)
        }
        guard http.statusCode == 200 else {
            throw Self.error(Self.friendlyError(status: http.statusCode, data: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw Self.error("Unexpected response from OpenAI.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendlyError(status: Int, data: Data) -> String {
        var apiMessage = ""
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let m = err["message"] as? String { apiMessage = m }
        switch status {
        case 401: return "Your OpenAI API key was rejected. Check it in Settings → Breeze AI."
        case 429: return "OpenAI rate limit or quota reached. Check your usage and billing on platform.openai.com."
        default:  return apiMessage.isEmpty ? "OpenAI request failed (HTTP \(status))." : apiMessage
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Breeze", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
