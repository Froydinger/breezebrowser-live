// Apple Foundation Models assistant — fully on-device (no third-party cloud).
// Agentic via the shared text protocol in Agent.swift (OPEN/SEARCH/READ/REMIND):
// the @Generable tool-calling macro ships only with Xcode, so we drive the loop
// ourselves — the effect matches the Electron Qwen function-calling build.
// Requires macOS 26 + Apple Intelligence.

import Foundation
import FoundationModels

/// Browser capabilities the AI calls back into (main-actor UI work).
protocol BrowserAITools: AnyObject {
    @MainActor func aiOpenURL(_ url: String) async -> String
    @MainActor func aiReadCurrentPage() async -> String
    @MainActor func aiSearchWeb(_ query: String) async -> String
    @MainActor func aiSetReminder(_ text: String, minutes: Int) async -> String
    @MainActor func aiClick(_ target: String) async -> String
    @MainActor func aiType(_ target: String, text: String) async -> String
}

@available(macOS 26.0, *)
final class FoundationAI {
    private var session: LanguageModelSession
    weak var browser: (any BrowserAITools)?

    static func available() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
    static func unavailableReason() -> String {
        switch SystemLanguageModel.default.availability {
        case .available: return ""
        case .unavailable(let r):
            switch r {
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings to use Breeze AI."
            case .modelNotReady: return "Apple's on-device model is still downloading. Try again shortly."
            @unknown default: return "Apple's on-device model isn't available right now."
            }
        }
    }

    init(tools: any BrowserAITools) {
        browser = tools
        let extra = Store.shared.string("aiInstructions")
        session = LanguageModelSession(instructions: Agent.systemPrompt(extra: extra))
    }

    func send(_ text: String, history: [[String: String]], contexts: [AIContext], completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        guard let tools = browser else {
            completion(.failure(NSError(domain: "Breeze", code: 1))); return
        }
        session = LanguageModelSession(instructions: Agent.systemPrompt(extra: Store.shared.string("aiInstructions")))
        
        var histStr = ""
        for msg in history {
            let role = msg["role"] == "ai" ? "Assistant" : "User"
            if let txt = msg["text"] {
                histStr += "\(role): \(txt)\n"
            }
        }
        let promptText = histStr.isEmpty ? text : "Prior conversation:\n\(histStr)\nUser: \(text)"
        
        Task {
            do {
                let (answer, chips) = try await Agent.run(
                    userText: promptText, contexts: contexts, tools: tools,
                    ask: { msg in try await self.session.respond(to: msg).content },
                    askFresh: { msg in
                        self.session = LanguageModelSession(instructions: Agent.systemPrompt(extra: Store.shared.string("aiInstructions")))
                        return try await self.session.respond(to: msg).content
                    })
                
                var finalAns = answer
                var finalChips = chips
                let lowerAns = answer.lowercased()
                if lowerAns.contains("clarify") || lowerAns.contains("i can't") || lowerAns.contains("cannot") || lowerAns.contains("sorry") {
                    finalAns = "Hmmm, can you clarify? I can search the web and perform quick tasks, but for full browser actions and deep reasoning, please download the local Qwen model."
                    if !finalChips.contains("📥 Download Qwen 8B") {
                        finalChips.append("📥 Download Qwen 8B")
                    }
                }
                
                let resultAns = finalAns
                let resultChips = finalChips
                await MainActor.run { completion(.success((resultAns, resultChips))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}
