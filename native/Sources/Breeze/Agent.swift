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
    case click(String)         // click on a button/link/element matching text or selector
    case type(String, String)  // type text into a field matching text or selector
}

enum Agent {
    /// System prompt shared by both backends. Strong, explicit, anti-refusal.
    static func systemPrompt(extra: String = "") -> String {
        let df = DateFormatter(); df.dateStyle = .full; df.timeStyle = .short
        let custom = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        
        var remindersList = ""
        if let rems = Store.shared.settings["reminders"] as? [[String: Any]], !rems.isEmpty {
            remindersList = "\nActive Reminders:\n"
            for r in rems {
                let label = r["label"] as? String ?? "Reminder"
                if let fireAt = r["fireAt"] as? Double {
                    let date = Date(timeIntervalSince1970: fireAt / 1000.0)
                    remindersList += "- \"\(label)\" scheduled at \(df.string(from: date))\n"
                }
            }
        }

        return """
        You are Breeze, the AI assistant built into the Breeze web browser. You run \
        privately on the user's Mac. Right now it is \(df.string(from: Date())).

        YOUR DEFAULT BEHAVIOR IS TO ANSWER DIRECTLY. Most questions do not need a web \
        search. You are a knowledgeable AI — just answer the user.

        CHAT FIRST. Greetings, small talk, opinions, jokes, and general/coding/math \
        questions get a plain conversational reply with NO action line. Only reach for a \
        tool when the user clearly needs it. NEVER narrate, summarize, or act on the \
        current page or open tabs unless the user's message is about them — but when it \
        IS (e.g. "this page", "this tab", "this video", "this article", "summarize this", \
        "what is this about", "what does it say", "who is in this"), answer directly from \
        the current-page text provided below; do NOT ask which page they mean — you are \
        given it. When the user \
        clearly says to go to / open / visit a site, use OPEN (e.g. "go to facebook" → \
        OPEN: facebook.com). Do not open random pages or run searches for a simple chat.

        DON'T FLAIL. If you can't tell what the user wants, or you can't find a clear, \
        deliberate action that moves their request forward, STOP — do NOT click or type \
        on random elements hoping something works. Instead, pick ONE of:
        • Unclear/ambiguous request → just ask, briefly and casually (e.g. "Not sure what \
        you mean — want me to search that?" or "Hm, say more?"). One short line, no action.
        • A real question with nothing to do on this page → SEARCH: <query> for it.
        • An action failed or you got stuck → tell the user what you see and where you \
        stopped, in plain language. Do NOT keep clicking around.
        Every CLICK/TYPE must be a deliberate step toward the user's EXPLICIT request — \
        never act on an element "just because it exists."

        You CAN control the browser when needed. Reply with ONE action line (nothing else on that line):
          OPEN: <url>           — open a website (e.g. OPEN: apple.com). Use when the \
        user asks to go to / open / visit a site.
          SEARCH: <query>       — web search. Use ONLY when you truly lack the answer \
        and it requires real-time or very specific factual data (see rules below).
          READ                  — read the page the user is viewing. Use when they ask \
        about "this page" / "this article".
          REMIND: <minutes> | <text>  — set a reminder.
          CLICK: <ID or selector>   — click on a link, button, input field, or element. Prefer using the ID in brackets (e.g. CLICK: 3 or CLICK: [3]) from the Interactive Elements list.
          TYPE: <ID or selector> | <value> — type a value into an input field, text area, or textbox. Prefer using the ID in brackets (e.g. TYPE: 2 | value or TYPE: [2] | value) from the Interactive Elements list.

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
        • "OPEN" is only for navigating to actual web addresses or domains in the browser. Do NOT use OPEN to "open" page elements like menus, dialogs, dropdowns, or input/text boxes on the current page — use CLICK or TYPE for those.
        • If you need to navigate to a specific URL or domain name (e.g. weather.com), ALWAYS use OPEN: <url>, do NOT use SEARCH.
        • You have access to a list of Interactive Elements at the beginning of the page content. ALWAYS use the ID in brackets (e.g. CLICK: 3 or TYPE: 2 | value) to click or type into elements. This is 100% reliable. ONLY fall back to text matching or CSS selectors if you cannot find the element in the list.
        • NEVER invent map search URLs or Apple Maps URLs like maps.apple.com or maps.google.com/maps/search. If the user asks to navigate, search, or find an address, OPEN google.com first, then use the Search field to enter the address, click search, and read the results.
        • DO NOT just say "I opened it for you" or "Done." when you finish. Summarize exactly what is visible on the page (from the page text and elements), explain where you stopped, what the current state is, and how it answers the user's request.
        • You can perform MULTIPLE steps (up to 8 actions). If a search or page does not give you enough information, do not give up — search again with a better query, search alternative terms, or use OPEN: <url> to visit a specific link from the results to get more details.
        • When asked to write a post, comment, or interact with text fields, use the interactive element IDs to find the input/textarea (e.g. searching for text like "What's on your mind", "Add a comment", or CSS selectors) and enter the text. If you cannot find the element or if the page requires you to be logged in to comment/post, explain that to the user.
        • You have access to a Plan Mode: since you run locally with no API limits, for complex tasks (e.g. "do some research, write a blog post, then create a new post on my wordpress site that is logged in"), formulate a multi-step plan, navigate, and perform sequential form fills, button clicks, and search queries across websites to complete the task.
        • You are aware of the user's active reminders. You can read, inspect, or suggest new reminders based on this state.
        • NEVER invent facts, URLs, prices, or sources. SEARCH if truly unsure.
        • Don't describe your own model, architecture, or training.
        • Use the user's open-tab context below when it's relevant.

        CRITICAL: Default to answering directly. Only use SEARCH as a last resort when \
        you genuinely cannot answer without real-time data. If in doubt, answer directly.
        \(remindersList)
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
                let v = clean(String(l.dropFirst(7)))
                if !v.isEmpty {
                    if isURL(v) {
                        return .open(v)
                    } else {
                        return .search(v)
                    }
                }
            } else if up.hasPrefix("CLICK:") || up.hasPrefix("CLICK ") {
                let v = clean(String(l.dropFirst(6))); if !v.isEmpty { return .click(v) }
            } else if up.hasPrefix("TYPE:") || up.hasPrefix("TYPE ") {
                let body = String(l.dropFirst(5))
                let parts = body.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count > 1 {
                    return .type(clean(parts[0]), clean(parts[1]))
                }
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

    private static func isURL(_ q: String) -> Bool {
        let cleanQ = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleanQ.hasPrefix("http://") || cleanQ.hasPrefix("https://") {
            return true
        }
        if cleanQ.contains(".") && !cleanQ.contains(" ") {
            return true
        }
        return false
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " `\"'*"))
    }

    /// Run the loop. `ask` sends one turn to the model (which keeps conversation
    /// memory). `askFresh` resets the model's context and answers a single
    /// self-contained prompt — used to recover from a context-window overflow so
    /// the assistant never hard-fails. Returns the final answer + tool chips.
    static func run(userText: String, contexts: [AIContext], tools: any BrowserAITools,
                    maxSteps: Int = 8, contextBudget: Int = 8000,
                    ask: (String) async throws -> String,
                    askFresh: (String) async throws -> String) async throws -> (answer: String, chips: [String]) {
        // The page the user is actively viewing is presented FIRST and labelled as
        // such, so "what is this about / this page / this video" resolves to it.
        // Everything else (history, bookmarks, other tabs) is reference-only.
        var currentCtx = ""
        var refCtx = ""
        for c in contexts {
            let block = "[\(c.label)]\n\(String(c.text.prefix(contextBudget)))\n\n"
            if c.isCurrent { currentCtx += block } else { refCtx += block }
        }
        var prompt = ""
        if !currentCtx.isEmpty {
            prompt += "The page the user is currently looking at — this is what they mean by \"this page\", \"this video\", \"this article\", \"this\", or \"what is this about\". Answer from it directly:\n\(currentCtx)"
        }
        if !refCtx.isEmpty {
            prompt += "(Reference only — do NOT mention or act on these unless the user's message is about them.)\nOther open tabs / recent history / bookmarks:\n\(refCtx)\n"
        }
        prompt += "User: \(userText)"
        var chips: [String] = []
        var lastFallback = "Done."
        // Most relevant info gathered, for overflow recovery. Seed it with the page
        // the user is viewing so that if the very first turn overflows the model's
        // context, the recovery window can still answer about the current page
        // instead of replying blind ("not sure which video you mean").
        var lastResult = currentCtx
        // Restated on every continuation step. The FM backend uses a fresh session per
        // message and a tiny context window, so without this the model loses sight of
        // the user's goal mid-task and just describes the page instead of finishing it
        // (e.g. it found the first result but never clicked it).
        let goal = "Remember the user's original request: \"\(userText)\". Keep working until it is fully done."
        // Tool output is trimmed so the small on-device context window doesn't overflow.
        func cap(_ s: String, _ n: Int = 8000) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

        // If the model overflows its context (or errors), start a clean window
        // seeded only with the question + the most relevant info, and answer.
        func recover() async -> String {
            let seed = """
            The user asked: \(userText)
            \(lastResult.isEmpty ? "" : "\nThe most relevant information gathered so far:\n\(cap(lastResult, 6000))\n")
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
                prompt = "\(goal)\n\n\(cap(lastResult))\n\nThe page is now open. If finishing the request clearly needs a click or further reading, do it with CLICK: <ID> (use the Interactive Elements IDs above) or OPEN: <url>. If the request is already answered, or it's unclear what to do next, just answer or ask the user in plain language — do NOT click random elements."
            case .search(let q):
                if !chips.contains("🔎 Web search") { chips.append("🔎 Web search") }
                lastFallback = "Here's what I found about \"\(q)\"."
                lastResult = await tools.aiSearchWeb(q)
                prompt = "\(goal)\n\n\(cap(lastResult))\n\nThese are the search results. If the request needs a specific page's details, open one with CLICK: <ID> from the Interactive Elements list or OPEN: <url>. If the results already answer the question, just answer the user in plain language using them."
            case .click(let target):
                let chip = "🖱️ Click: \(target)"
                if !chips.contains(chip) { chips.append(chip) }
                lastFallback = "I've clicked on \(target) for you."
                lastResult = await tools.aiClick(target)
                prompt = "\(goal)\n\n\(cap(lastResult))\n\nThe click was executed; above is the updated page. If a clear next step is needed, continue with CLICK: <ID>, TYPE: <ID> | <value>, or OPEN: <url>. If you're unsure what to do next, or the click didn't help, STOP and tell the user what you see in plain language — do NOT keep clicking randomly."
            case .type(let target, let value):
                let chip = "⌨️ Type: \(target)"
                if !chips.contains(chip) { chips.append(chip) }
                lastFallback = "I've typed \"\(value)\" into \(target) for you."
                lastResult = await tools.aiType(target, text: value)
                prompt = "\(goal)\n\n\(cap(lastResult))\n\nThe text was entered. If you need to submit or continue, reply with CLICK: <ID>. Otherwise, tell the user what you did in plain language."
            case .read:
                if !chips.contains("📄 Page") { chips.append("📄 Page") }
                lastFallback = "Here's a summary of the page."
                lastResult = await tools.aiReadCurrentPage()
                prompt = "\(goal)\n\n\(cap(lastResult))\n\nUsing this, answer the user's question about the page now in plain language."
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
            return !(up.hasPrefix("OPEN:") || up.hasPrefix("SEARCH:") || up.hasPrefix("REMIND:") || up == "READ" || up.hasPrefix("OPEN ") || up.hasPrefix("SEARCH ") || up.hasPrefix("REMIND ") || up.hasPrefix("CLICK:") || up.hasPrefix("CLICK ") || up.hasPrefix("TYPE:") || up.hasPrefix("TYPE "))
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
