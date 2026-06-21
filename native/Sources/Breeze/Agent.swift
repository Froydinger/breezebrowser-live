// Shared agentic loop for both AI backends (Apple Foundation Models + Qwen).
// The model drives the browser through a tiny text protocol: it replies with a
// single ACTION line (OPEN/SEARCH/READ/REMIND), we run it against BrowserAITools,
// feed the result back, and loop until the model gives a plain-language answer.
// This is the native equivalent of the Electron Qwen function-calling build.

import Foundation

enum AgentAction {
    case open(String)          // navigate the browser to a site
    case search(String)        // web search + read the results
    case read                  // read the page the user is viewing
    case remind(Int, String)   // set a reminder in N minutes
}

enum Agent {
    /// System prompt shared by both backends. Strong, explicit, anti-refusal.
    static func systemPrompt(extra: String = "") -> String {
        let df = DateFormatter(); df.dateStyle = .full; df.timeStyle = .short
        let custom = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You are Breeze, the AI assistant built into the Breeze web browser. You run \
        privately on the user's Mac. Right now it is \(df.string(from: Date())).

        YOUR DEFAULT BEHAVIOR IS TO ANSWER DIRECTLY. Most questions do not need a web \
        search. You are a knowledgeable AI — just answer the user.

        You CAN control the browser when needed. Reply with ONE action line (nothing else on that line):
          OPEN: <url>           — open a website (e.g. OPEN: apple.com). Use when the \
        user asks to go to / open / visit a site.
          SEARCH: <query>       — web search. Use ONLY when you truly lack the answer \
        and it requires real-time or very specific factual data (see rules below).
          READ                  — read the page the user is viewing. Use when they ask \
        about "this page" / "this article".
          REMIND: <minutes> | <text>  — set a reminder.

        WHEN TO SEARCH (the ONLY cases):
        • Today's news, live scores, current weather, stock prices
        • Events happening right now or very recently
        • A specific product price, store hours, or local business info
        • Something you genuinely do not know and cannot reason about

        WHEN NOT TO SEARCH (answer directly instead):
        • General knowledge, science, history, geography, definitions
        • Math, calculations, unit conversions
        • Coding help, debugging, explaining code
        • Writing, translation, grammar, creative tasks
        • Explaining concepts, how things work, comparisons
        • Opinions, recommendations based on common knowledge
        • Anything you can confidently answer from training

        After an action you'll get the result, then you can act again or answer. When \
        ready, reply normally (NO action keyword) with a helpful answer.

        Hard rules:
        • You DO have web access. NEVER say you can't browse — just OPEN it.
        • NEVER invent facts, URLs, prices, or sources. SEARCH if truly unsure.
        • Don't describe your own model, architecture, or training.
        • Use the user's open-tab context below when it's relevant.

        CRITICAL: Default to answering directly. Only use SEARCH as a last resort when \
        you genuinely cannot answer without real-time data. If in doubt, answer directly.
        \(custom.isEmpty ? "" : "\nUser preferences: \(custom)")
        """
    }

    /// Parse a model reply into an action, scanning for the first action line.
    static func parse(_ reply: String) -> AgentAction? {
        for raw in reply.split(separator: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            // strip common markdown/bullet noise the small model sometimes adds
            while l.hasPrefix("`") || l.hasPrefix("*") || l.hasPrefix("-") || l.hasPrefix(">") {
                l.removeFirst()
            }
            l = l.trimmingCharacters(in: .whitespaces)
            var up = l.uppercased()
            if up.hasPrefix("ACTION: ") { l = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces); up = l.uppercased() }
            else if up.hasPrefix("ACTION ") { l = String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces); up = l.uppercased() }

            if up.hasPrefix("OPEN:") || up.hasPrefix("OPEN ") {
                let v = clean(String(l.dropFirst(5))); if !v.isEmpty { return .open(v) }
            } else if up.hasPrefix("SEARCH:") || up.hasPrefix("SEARCH ") {
                let v = clean(String(l.dropFirst(7))); if !v.isEmpty { return .search(v) }
            } else if up.hasPrefix("REMIND:") || up.hasPrefix("REMIND ") {
                let body = String(l.dropFirst(7))
                let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let mins = Int(parts.first?.filter { $0.isNumber } ?? "") ?? 5
                let txt = parts.count > 1 ? parts[1] : "Reminder"
                return .remind(mins, clean(txt))
            } else if up == "READ" || up == "READ:" || up.hasPrefix("READ ") {
                return .read
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " `\"'*"))
    }

    /// Run the loop. `ask` sends one turn to the model (which keeps conversation
    /// memory). `askFresh` resets the model's context and answers a single
    /// self-contained prompt — used to recover from a context-window overflow so
    /// the assistant never hard-fails. Returns the final answer + tool chips.
    static func run(userText: String, contexts: [AIContext], tools: any BrowserAITools,
                    maxSteps: Int = 8,
                    ask: (String) async throws -> String,
                    askFresh: (String) async throws -> String) async throws -> (answer: String, chips: [String]) {
        var ctx = ""
        for c in contexts { ctx += "[\(c.label)]\n\(String(c.text.prefix(1200)))\n\n" }
        var prompt = (ctx.isEmpty ? "" : "Context from the user's open tabs:\n\(ctx)\n") + "User: \(userText)"
        var chips: [String] = []
        var lastFallback = "Done."
        var lastResult = ""            // most relevant info gathered, for overflow recovery
        // Tool output is trimmed so the small on-device context window doesn't overflow.
        func cap(_ s: String, _ n: Int = 1500) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

        // If the model overflows its context (or errors), start a clean window
        // seeded only with the question + the most relevant info, and answer.
        func recover() async -> String {
            let seed = """
            The user asked: \(userText)
            \(lastResult.isEmpty ? "" : "\nThe most relevant information gathered so far:\n\(cap(lastResult, 1200))\n")
            Now give the user a complete, helpful answer in plain language. Do not use any action keywords.
            """
            if let r = try? await askFresh(seed) {
                let s = stripActionLines(r)
                if !s.isEmpty { return s }
            }
            return lastFallback
        }

        for step in 0..<maxSteps {
            let reply: String
            do { reply = try await ask(prompt) }
            catch { return (await recover(), chips) }      // self-heal on overflow / model error
            // On the last allowed step, force a plain answer (ignore any action).
            if step == maxSteps - 1 { return (finalize(reply, fallback: lastFallback), chips) }
            guard let action = parse(reply) else { return (finalize(reply, fallback: lastFallback), chips) }
            switch action {
            case .open(let u):
                let host = u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                let chip = "🌐 " + String(host.prefix(28))
                if !chips.contains(chip) { chips.append(chip) }
                lastFallback = "I've opened \(host) for you."
                lastResult = await tools.aiOpenURL(u)
                prompt = "\(cap(lastResult))\n\nThe page is now open in the user's browser. In one or two sentences, tell them it's open and what's on it (or answer their question). Do NOT take another action unless it's truly required."
            case .search(let q):
                if !chips.contains("🔎 Web search") { chips.append("🔎 Web search") }
                lastFallback = "Here's what I found about \"\(q)\"."
                lastResult = await tools.aiSearchWeb(q)
                prompt = "\(cap(lastResult))\n\nUsing these results, answer the user's question now in plain language. Only search again if you genuinely cannot answer yet."
            case .read:
                if !chips.contains("📄 Page") { chips.append("📄 Page") }
                lastFallback = "Here's a summary of the page."
                lastResult = await tools.aiReadCurrentPage()
                prompt = "\(cap(lastResult))\n\nUsing this, answer the user's question about the page now in plain language."
            case .remind(let m, let t):
                chips.append("⏰ Reminder")
                lastFallback = "Reminder set."
                lastResult = await tools.aiSetReminder(t, minutes: m)
                prompt = "\(cap(lastResult))\n\nTell the user, briefly and warmly, that this is done."
            }
        }
        return (lastFallback, chips)
    }

    /// Strip stray action lines; fall back to a sensible line if nothing's left.
    private static func finalize(_ reply: String, fallback: String) -> String {
        let s = stripActionLines(reply)
        return s.isEmpty ? fallback : s
    }

    /// Remove any stray action lines from a final answer (defensive).
    private static func stripActionLines(_ s: String) -> String {
        let kept = s.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            var up = line.trimmingCharacters(in: .whitespaces).uppercased()
            if up.hasPrefix("ACTION: ") { up = String(up.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if up.hasPrefix("ACTION ") { up = String(up.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            return !(up.hasPrefix("OPEN:") || up.hasPrefix("SEARCH:") || up.hasPrefix("REMIND:") || up == "READ" || up.hasPrefix("OPEN ") || up.hasPrefix("SEARCH ") || up.hasPrefix("REMIND "))
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
