// Apple Foundation Models assistant — fully on-device (no third-party cloud).
// Agentic page-context + web search. We drive the "tool" loop ourselves in text
// (a SEARCH: protocol) rather than FM tool-calling, because the @Generable macro
// plugin ships only with Xcode (not the Command Line Tools) — the effect matches
// the old Qwen function-calling build. Requires macOS 26 + Apple Intelligence.

import Foundation
import FoundationModels

/// Browser capabilities the AI calls back into (main-actor UI work).
protocol BrowserAITools: AnyObject {
    @MainActor func aiReadCurrentPage() async -> String
    @MainActor func aiSearchWeb(_ query: String) async -> String
    @MainActor func aiSetReminder(_ text: String, minutes: Int) async -> String
}

@available(macOS 26.0, *)
final class FoundationAI {
    private let session: LanguageModelSession
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
        let df = DateFormatter(); df.dateStyle = .full
        let instructions = """
        You are Breeze, a private assistant inside a web browser, running entirely \
        on the user's Mac. Today is \(df.string(from: Date())). Give complete, genuinely \
        helpful answers in a friendly, natural tone. You may be given the text of one or \
        more open tabs as context — use it to ground your answer when relevant. When a \
        question needs current or factual information you're unsure of, you can request a \
        web search. Never invent facts.
        """
        session = LanguageModelSession(instructions: instructions)
    }

    func send(_ text: String, contexts: [AIContext], completion: @escaping (Result<(String, Bool), Error>) -> Void) {
        Task {
            do {
                var ctx = ""
                for c in contexts { ctx += "[\(c.label)]\n\(String(c.text.prefix(1500)))\n\n" }
                let first = """
                \(ctx.isEmpty ? "" : "Context from the user's open tabs:\n\(ctx)")The user asks: \(text)

                If answering this needs current or live web information you don't already \
                know, reply with ONLY one line: SEARCH: <query>. Otherwise answer fully now.
                """
                var out = try await session.respond(to: first).content
                var usedSearch = false
                if let query = Self.extractSearch(out), let b = browser {
                    usedSearch = true
                    let results = await b.aiSearchWeb(query)
                    let second = """
                    Web search results for "\(query)":
                    \(String(results.prefix(2600)))

                    Using these results and any tab context, answer the user's question fully.
                    """
                    out = try await session.respond(to: second).content
                }
                let final = out
                await MainActor.run { completion(.success((final, usedSearch))) }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }

    private static func extractSearch(_ s: String) -> String? {
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("SEARCH:") {
                let q = t.dropFirst(7).trimmingCharacters(in: .whitespaces)
                return q.isEmpty ? nil : q
            }
        }
        return nil
    }
}
