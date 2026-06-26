// Breeze Cloud backend. Provider selection lives server-side so the app does
// not expose model IDs or provider credentials.

import AppKit
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

    /// The in-flight chat turn, so Nav has a global kill switch.
    private var currentTask: Task<Void, Never>?
    func cancel() { currentTask?.cancel(); currentTask = nil }

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
        currentTask = Task {
            do {
                try Task.checkCancellation()
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
            body["max_completion_tokens"] = 2000
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

    // MARK: - Images

    func generateImage(prompt: String, contexts: [AIContext], attachments: [AIImageAttachment],
                       completion: @escaping (Result<NSImage, Error>) -> Void) {
        guard usingCloud else {
            completion(.failure(Self.error("Nav is not configured in this build.")))
            return
        }

        let requestID = UUID().uuidString
        let finalPrompt = imagePrompt(userPrompt: prompt, contexts: contexts)
        Task {
            do {
                let image: NSImage
                if attachments.isEmpty {
                    image = try await createImage(prompt: finalPrompt, requestID: requestID)
                } else {
                    image = try await editImage(prompt: finalPrompt, attachments: attachments, requestID: requestID)
                }
                await MainActor.run { completion(.success(image)) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private func createImage(prompt: String, requestID: String) async throws -> NSImage {
        guard let url = endpoint(path: "/v1/images/generations") else {
            throw Self.error("Nav is not configured in this build.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req, requestID: requestID)
        req.timeoutInterval = 240
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "quality": "low",
            "size": "1024x1024",
            "n": 1,
            "output_format": "png",
        ])
        return try await decodeImageResponse(req)
    }

    private func editImage(prompt: String, attachments: [AIImageAttachment], requestID: String) async throws -> NSImage {
        guard let url = endpoint(path: "/v1/images/edits") else {
            throw Self.error("Nav is not configured in this build.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(to: &req, requestID: requestID)
        req.timeoutInterval = 240

        let files = attachments.prefix(4).map {
            MultipartFile(field: "image", filename: $0.filename, mime: "image/png", data: $0.data)
        }
        let multipart = makeMultipart(fields: [
            "prompt": prompt,
            "quality": "low",
            "size": "1024x1024",
            "n": "1",
            "output_format": "png",
        ], files: files)
        req.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipart.body
        return try await decodeImageResponse(req)
    }

    private func decodeImageResponse(_ req: URLRequest) async throws -> NSImage {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw Self.error("No response from Breeze Cloud.")
        }
        guard http.statusCode == 200 else {
            throw Self.error(Self.friendlyError(status: http.statusCode, data: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]],
              let first = items.first else {
            throw Self.error("Unexpected image response.")
        }
        if let b64 = first["b64_json"] as? String,
           let imageData = Data(base64Encoded: b64),
           let image = NSImage(data: imageData) {
            return image
        }
        if let urlString = first["url"] as? String, let url = URL(string: urlString) {
            let (imageData, _) = try await URLSession.shared.data(from: url)
            if let image = NSImage(data: imageData) { return image }
        }
        throw Self.error("Breeze Cloud returned no image data.")
    }

    private func imagePrompt(userPrompt: String, contexts: [AIContext]) -> String {
        let relevant = contexts.map { "[\($0.label)]\n\(String($0.text.prefix(2000)))" }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if relevant.isEmpty { return userPrompt }
        return """
        Use this Breeze context only if it is relevant to the user's image request:
        \(relevant)

        User image request:
        \(userPrompt)
        """
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

private struct MultipartFile {
    let field: String
    let filename: String
    let mime: String
    let data: Data
}

private func makeMultipart(fields: [String: String], files: [MultipartFile]) -> (body: Data, boundary: String) {
    let boundary = "BreezeBoundary-\(UUID().uuidString)"
    var body = Data()

    func append(_ string: String) {
        if let data = string.data(using: .utf8) { body.append(data) }
    }

    for (key, value) in fields {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    for file in files {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
        append("Content-Type: \(file.mime)\r\n\r\n")
        body.append(file.data)
        append("\r\n")
    }

    append("--\(boundary)--\r\n")
    return (body, boundary)
}
