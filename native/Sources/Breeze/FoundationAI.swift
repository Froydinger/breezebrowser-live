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

    func send(_ text: String, contexts: [AIContext], completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        guard let tools = browser else {
            completion(.failure(NSError(domain: "Breeze", code: 1))); return
        }
        // Apple's on-device model has a small context window, and an agentic loop
        // feeds it large page/search text. Start each message from a fresh session
        // so a prior turn's tool output can't overflow the transcript.
        session = LanguageModelSession(instructions: Agent.systemPrompt(extra: Store.shared.string("aiInstructions")))
        Task {
            do {
                let (answer, chips) = try await Agent.run(
                    userText: text, contexts: contexts, tools: tools,
                    ask: { msg in try await self.session.respond(to: msg).content },
                    askFresh: { msg in
                        // brand-new context window (recovers from an overflow)
                        self.session = LanguageModelSession(instructions: Agent.systemPrompt(extra: Store.shared.string("aiInstructions")))
                        return try await self.session.respond(to: msg).content
                    })
                await MainActor.run { completion(.success((answer, chips))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}
