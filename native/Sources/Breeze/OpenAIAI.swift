// OpenAI backend (bring-your-own-key). Optional cloud alternative to the on-device
// Apple Foundation Models / Qwen backends, for stronger multi-step agent tasks
// (e.g. form filling) that the small on-device model struggles with.
//
// The user pastes their OWN API key in Settings; it's stored locally and used to call
// api.openai.com directly from the app. There is no Breeze server and no shared key —
// the user pays OpenAI for their own usage. Drives the same shared agentic loop in
// Agent.swift via the text protocol, so OPEN/SEARCH/READ/CLICK/TYPE all work.

import Foundation

final class OpenAIAI {
    weak var browser: (any BrowserAITools)?
    var apiKey: String
    var model: String

    init(tools: any BrowserAITools, apiKey: String, model: String) {
        self.browser = tools
        self.apiKey = apiKey
        self.model = model
    }

    func send(_ text: String, contexts: [AIContext],
              completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        guard let tools = browser else {
            completion(.failure(NSError(domain: "Breeze", code: 1))); return
        }
        guard !apiKey.isEmpty else {
            completion(.failure(NSError(domain: "OpenAI", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "No OpenAI API key set. Add one in Settings → AI."])))
            return
        }
        let system = Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))
        // Match the FM backend: the conversation memory lives within one agentic run
        // (across tool steps), and each user message starts a fresh transcript.
        var messages: [[String: String]] = [["role": "system", "content": system]]
        Task {
            do {
                let (answer, chips) = try await Agent.run(
                    userText: text, contexts: contexts, tools: tools,
                    ask: { msg in
                        messages.append(["role": "user", "content": msg])
                        let reply = try await self.complete(messages)
                        messages.append(["role": "assistant", "content": reply])
                        return reply
                    },
                    askFresh: { msg in
                        let fresh: [[String: String]] = [["role": "system", "content": system],
                                                         ["role": "user", "content": msg]]
                        return try await self.complete(fresh)
                    })
                await MainActor.run { completion(.success((answer, chips))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// One Chat Completions call. Surfaces OpenAI's own error message on failure.
    private func complete(_ msgs: [[String: String]]) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": model, "messages": msgs, "temperature": 0.3]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                throw NSError(domain: "OpenAI", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
            throw NSError(domain: "OpenAI", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "OpenAI API error (\(http.statusCode))."])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "OpenAI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected response from OpenAI."])
        }
        return content
    }
}
