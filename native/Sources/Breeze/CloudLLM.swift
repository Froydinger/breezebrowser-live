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
            ? "Aero is ready."
            : "Aero is not configured in this build."
    }

    func cacheKey(_ key: String) {}

    func resetChat() {}
    func shutdown() { cancelCurrent() }
    private var currentTask: Task<Void, Never>?
    private var activeTurnID: String?

    private func setStatus(_ s: String) {
        lastStatus = s
        if Thread.isMainThread { onStatus?(s) }
        else { DispatchQueue.main.async { self.onStatus?(s) } }
    }

    // MARK: - Chat

    func send(_ text: String, history: [[String: String]], contexts: [AIContext], images: [Data] = [],
              completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        guard Store.shared.settings["aeroEnabled"] as? Bool != false else {
            completion(.failure(Self.error("Aero is turned off in Settings.")))
            return
        }
        guard usingCloud else {
            completion(.failure(Self.error("Aero is not configured in this build.")))
            return
        }

        guard let tools = browser else {
            completion(.failure(Self.error("Aero isn't ready yet.")))
            return
        }

        let turnID = UUID().uuidString
        // Kept so Stop can cancel exactly this run and nothing else. Cancelling
        // the Task cancels the URLSession request it is awaiting, and Agent.run
        // checks for cancellation between steps so a multi-step research run
        // stops where it is instead of finishing the step it was on.
        currentTask?.cancel()
        activeTurnID = turnID
        currentTask = Task {
            defer {
                if self.activeTurnID == turnID { self.currentTask = nil; self.activeTurnID = nil }
            }
            do {
                let (answer, chips) = try await self.runDesktopAgent(text, history: history, contexts: contexts, images: images, tools: tools, requestID: turnID)
                if Task.isCancelled { return }
                await MainActor.run { completion(.success((answer, chips))) }
            } catch is CancellationError {
                // Stop is a user action, not a failure - the panel decides what to
                // show, and a late reply must never overwrite it.
                return
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    /// Stop the run in flight. Only this request: the backend, the chat and any
    /// later message are untouched.
    func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
        activeTurnID = nil
    }

    var isRunning: Bool { currentTask != nil && !(currentTask?.isCancelled ?? true) }

    private func agentRequest(_ body: [String: Any], requestID: String) async throws -> [String: Any] {
        if Store.shared.settings["aeroEnabled"] as? Bool == false && !["cancel", "close"].contains(body["operation"] as? String ?? "") { throw Self.error("Aero is turned off in Settings.") }
        guard let url = endpoint(path: "/v1/desktop/agents") else { throw Self.error("Aero is not configured.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req, requestID: requestID)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Self.error(Self.friendlyError(status: (response as? HTTPURLResponse)?.statusCode ?? 502, data: data))
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.error("Unexpected agent response.")
        }
        return result
    }

    private func runDesktopAgent(_ text: String, history: [[String: String]], contexts: [AIContext], images: [Data],
                                 tools: any BrowserAITools, requestID: String) async throws -> (String, [String]) {
        var prior = history
        // The panel records the submitted user message before invoking CloudLLM.
        if prior.last?["role"] != "ai", prior.last?["text"] == text { prior.removeLast() }
        // Agents session input contains user input blocks. Preserve earlier
        // roles as transcript labels, as in Arc's working Agents adapter.
        let transcript = prior.suffix(24).compactMap { message -> String? in
            guard let value = message["text"], !value.isEmpty else { return nil }
            return "[\(message["role"] == "ai" ? "Assistant" : "User")]:\n\(String(value.prefix(24000)))"
        }.joined(separator: "\n\n")
        var input: [[String: Any]] = []
        let context = contexts.map { "Attached context: \($0.label)\n\($0.text)" }.joined(separator: "\n\n")
        var content: [[String: Any]] = [["type": "input_text", "text": (transcript.isEmpty ? "" : "Conversation so far:\n" + transcript + "\n\n") + "[User]:\n" + text + (context.isEmpty ? "" : "\n\n" + context)]]
        content += images.map { ["type": "input_image", "image_url": "data:image/png;base64," + $0.base64EncodedString()] }
        input.append(["role": "user", "content": content])
        let lower = text.lowercased()
        let pendingTask = await tools.aiTakeTaskMode()
        let task = pendingTask ?? (lower.contains("youtube") || lower.contains("creator") ? "youtube" : lower.contains("research") ? "research" : lower.contains("fact-check") || lower.contains("factcheck") ? "factcheck" : "chat")
        let started = try await agentRequest(["operation": "start", "input": input, "task": task,
                                              "instructions": "Current local date/time: \(Date().formatted(date: .complete, time: .shortened)), timezone \(TimeZone.current.identifier).\n" + Store.shared.string("aiInstructions")], requestID: requestID)
        guard let handle = started["handle"] as? String else { throw Self.error("Aero could not start this request.") }
        let progress = Task { await self.watchAgentProgress(handle: handle, requestID: requestID) }
        var finished = false
        defer {
            progress.cancel()
            // Independent cleanup still runs when Stop cancelled the parent task.
            let operation = finished ? "close" : "cancel"
            Task {
                let result = try? await self.agentRequest(["operation": operation, "handle": handle], requestID: requestID + "-cleanup")
                if result?["cleanup_pending"] as? Bool == true {
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if (try? await self.agentRequest(["operation": "close", "handle": handle], requestID: requestID + "-cleanup")) != nil { break }
                    }
                }
            }
        }
        var chips: [String] = []
        var executed: [String: [String: Any]] = [:]
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = try await agentRequest(["operation": "poll", "handle": handle], requestID: requestID)
            switch state["status"] as? String {
            case "completed":
                guard let answer = state["text"] as? String, !answer.isEmpty else { throw Self.error("Aero finished without an answer.") }
                if let usage = state["usage"] as? [String: Any] {
                    let inputTokens = usage["input_tokens"] as? Int ?? 0
                    let outputTokens = usage["output_tokens"] as? Int ?? 0
                    if inputTokens > 0 || outputTokens > 0 {
                        await MainActor.run { Store.shared.addAIUsage(input: inputTokens, output: outputTokens) }
                    }
                }
                let sources = state["sources"] as? [[String: String]] ?? []
                let unique = sources.reduce(into: [[String: String]]()) { result, source in
                    if !result.contains(where: { $0["url"] == source["url"] }) { result.append(source) }
                }
                let links = unique.compactMap { source -> String? in
                    guard let url = source["url"], let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme) else { return nil }
                    let title = (source["title"] ?? parsed.host ?? "Source").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                    return "- [\(title)](\(url))"
                }
                finished = true
                return (answer + (links.isEmpty ? "" : "\n\nSources\n" + links.joined(separator: "\n")), chips)
            case "requires_action":
                var results: [[String: Any]] = []
                for call in state["actions"] as? [[String: Any]] ?? [] {
                    try Task.checkCancellation()
                    guard let id = call["call_id"] as? String, let turn = call["turn_id"] as? String,
                          let name = call["name"] as? String else { throw Self.error("Unsupported browser action.") }
                    if let cached = executed[id] { results.append(cached); continue }
                    if executed.count >= 24 { throw Self.error("Aero reached the browser action limit. Please continue in a new request.") }
                    let args: [String: Any]
                    if let object = call["arguments"] as? [String: Any] { args = object }
                    else if let raw = call["arguments"] as? String, let data = raw.data(using: .utf8),
                            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { args = object }
                    else { throw Self.error("Invalid browser action arguments.") }
                    let result: String
                    let chip: String
                    switch name {
                    case "open_page": setStatus("Opening page…"); result = await tools.aiOpenURL(args["url"] as? String ?? ""); chip = "Opened page"
                    case "read_page": setStatus("Reading page…"); result = await tools.aiReadCurrentPage(); chip = "Current page"
                    case "look_page": setStatus("Inspecting page…"); result = await tools.aiLookAtPage(); chip = "Page screenshot"
                    case "click": setStatus("Clicking…"); result = await tools.aiClick(args["target"] as? String ?? ""); chip = "Browser action"
                    case "type": setStatus("Typing…"); result = await tools.aiType(args["target"] as? String ?? "", text: args["text"] as? String ?? ""); chip = "Browser action"
                    case "reminder": result = await tools.aiSetReminder(args["text"] as? String ?? "", minutes: max(1, min(525600, args["minutes"] as? Int ?? 1))); chip = "Reminder"
                    case "spectra_search": setStatus("Searching with Spectra…"); result = await tools.aiSearchWeb(args["query"] as? String ?? ""); chip = "Spectra search"
                    case "browser_context":
                        let kind = args["kind"] as? String ?? ""
                        result = await tools.aiBrowserContext(kind); chip = kind.capitalized
                    default: throw Self.error("Unknown browser action: \(name)")
                    }
                    if !chips.contains(chip) && !result.hasPrefix("Access disabled") { chips.append(chip) }
                    let value: [String: Any] = ["call_id": id, "turn_id": turn, "success": true, "output": result]
                    executed[id] = value; results.append(value)
                }
                guard !results.isEmpty else { throw Self.error("Aero requested an unsupported tool.") }
                _ = try await agentRequest(["operation": "tool_results", "handle": handle, "results": results], requestID: requestID + "-" + String(executed.count))
            case "failed", "cancelled": throw Self.error("Aero's request stopped before completing. Please try again.")
            default:
                setStatus(state["progress"] as? String ?? "Thinking…")
                try await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw Self.error("Aero took too long to finish this request. Please try again.")
    }

    private func watchAgentProgress(handle: String, requestID: String) async {
        guard let url = endpoint(path: "/v1/desktop/agents") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"; req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &req, requestID: requestID)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["operation": "events", "handle": handle])
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["subagent_id"] == nil, let type = event["type"] as? String else { continue }
                if type.contains("web_search") { setStatus("Searching the web…") }
                else if type == "agent.session.turn.item.added", let item = event["item"] as? [String: Any] {
                    if item["type"] as? String == "web_search_call" { setStatus("Searching the web…") }
                    else if item["phase"] as? String == "final_answer" { setStatus("Writing answer…") }
                }
                // Reasoning and commentary text are deliberately not rendered as answers.
            }
        } catch { /* Polling confirms terminal state even if the progress stream disconnects. */ }
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
