// Research mode: an actual browse-and-read pipeline instead of "ask the model
// nicely to read 3–4 pages and hope". The old loop fed each page through a
// 4,000-char cap that, after the ~80-entry interactive-element dump, left only
// site navigation (Wikipedia's sidebar, never the article), and any prose reply
// ended the run — so one page of nav links became "I can't find the credits".
//
// Here the app drives the steps and the model only plans, picks and reads:
//   1. plan    — restate the question, write 2–3 plain search queries
//   2. search  — run each in the research tab, collect result links
//   3. pick    — model ranks the candidates worth reading
//   4. read    — open each in the research tab, extract the MAIN content
//                (nav/footer/sidebars stripped, tables kept as rows), take notes;
//                a page can hand us one of its own links to FOLLOW (poke around)
//   5. gaps    — one follow-up search if the notes are missing something
//   6. write   — synthesize from the notes only, citing the pages actually read

import Foundation

struct ResearchLink {
    let title: String
    let url: String
    let snippet: String
}

struct ResearchPage {
    let title: String
    let url: String
    let text: String
    let links: [ResearchLink]
}

enum Research {
    enum Mode { case research, factcheck }

    static let maxReads = 8          // pages opened, follows included
    static let maxFollows = 2        // links taken from inside a page
    static let targetSources = 4     // useful sources before the gap check
    static let pageChars = 40_000    // per-page text handed to the note-taker (a full discography table fits)
    static let noteChars = 6_000     // per-source notes kept for the write-up

    /// Word "research" in the request, and not a do-something-on-a-site task
    /// (those still go through the general agent loop).
    static func wants(_ text: String) -> Bool {
        let q = text.lowercased()
        guard q.contains("research") else { return false }
        let transactional = ["log in", "sign in", "submit", "fill out", "fill in", "wordpress", "send an email", "send email"]
        return !transactional.contains { q.contains($0) }
    }

    static func run(userText: String, contexts: [AIContext], tools: any BrowserAITools, mode: Mode = .research,
                    ask: (String) async throws -> String,
                    askFresh: @escaping @Sendable (String) async throws -> String) async throws -> (answer: String, chips: [String]) {
        await tools.aiResearchBegin()
        await tools.aiResearchStatus("Planning the research…")

        // 1. Plan. `ask` carries the chat history, so "research every song HE
        // produced" resolves to whoever the conversation was about.
        let current = contexts.first { $0.isCurrent }
        var planPrompt = ""
        if let current {
            // The article itself, not the nav-heavy per-message snippet — matters for
            // "fact-check the claim on this page" / "research this page".
            let main = await tools.aiReadCurrentMain()
            let text = (main?.text.count ?? 0) >= 400 ? main!.text : current.text
            planPrompt += "The page the user is viewing:\n[\(current.label)]\n\(String(text.prefix(6000)))\n\n"
        }
        planPrompt += """
        User: \(userText)

        RESEARCH PLANNING — do not answer yet and do not ask questions. Reply with \
        ONLY these lines:
        QUESTION: <\(mode == .factcheck
            ? "the exact claim to verify, quoted or precisely paraphrased (taken from the viewed page if the user means a claim on it), phrased as: Is it true that …?"
            : "the user's request restated as one standalone question, with pronouns resolved from the conversation")>
        SEARCH: <plain keyword query>
        SEARCH: <a differently-worded plain keyword query>
        SEARCH: <optional third query aimed at a comprehensive/primary source, e.g. a list, database or official page>
        Keep queries short and plain: no quotes, site:, OR, or years.
        \(current.map { _ in "If the viewed page itself is what should be researched, also add a line: OPEN: <its URL>" } ?? "")
        """
        let planReply = (try? await ask(planPrompt)) ?? ""
        try Task.checkCancellation()
        var question = userText
        var queries: [String] = []
        var seeds: [String] = []
        for raw in planReply.split(separator: "\n") {
            let line = stripBullet(String(raw))
            if let v = value(line, "QUESTION:") { if !v.isEmpty { question = v } }
            else if let v = value(line, "SEARCH:") { if !v.isEmpty, queries.count < 2 { queries.append(v) } }
            else if let v = value(line, "OPEN:") { if v.lowercased().hasPrefix("http") { seeds.append(v) } }
        }
        if queries.isEmpty {
            let bare = userText.replacingOccurrences(of: "research", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            queries = [bare.isEmpty ? userText : bare]
        }
        let focus = focusTerms(question + " " + userText)
        var chips: [String] = ["🔎 Web search"]

        // 2. Search.
        var candidates: [ResearchLink] = seeds.map { ResearchLink(title: "Page you were viewing", url: $0, snippet: "") }
        var seen = Set(candidates.map { normalize($0.url) })
        for (i, q) in queries.enumerated() {
            try Task.checkCancellation()
            await tools.aiResearchStatus("Searching (\(i + 1)/\(queries.count)): \(q)")
            for link in await tools.aiResearchSearch(q) where usable(link.url) {
                if seen.insert(normalize(link.url)).inserted { candidates.append(link) }
            }
        }

        // 3. Pick.
        var queue = seeds + (await pick(candidates.filter { !seeds.contains($0.url) }, count: 5,
                                         question: question, askFresh: askFresh))
        var backups = candidates.map(\.url).filter { !queue.contains($0) }

        // 4. Read in rounds. Pages open one after another in the research tab (the
        // quick, visible part); then notes for the whole round are taken IN
        // PARALLEL. Taking notes serially — one model call per page before the
        // next page could even open — was most of a 3-minute run.
        var notes: [(title: String, url: String, text: String)] = []
        var reads = 0, follows = 0
        var readURLs = Set<String>()
        var gapChecked = false
        var round = queue
        while reads < maxReads {
            try Task.checkCancellation()
            var pages: [ResearchPage] = []
            var pending = round
            round = []
            while !pending.isEmpty, reads < maxReads {
                let url = pending.removeFirst()
                guard readURLs.insert(normalize(url)).inserted else { continue }
                reads += 1
                await tools.aiResearchStatus("Reading source \(reads): \(host(url))")
                var read = await tools.aiResearchRead(url, focus: focus)
                if let r = read, r.text.count < 400, let seen = await tools.aiResearchLook(), seen.text.count >= 400 {
                    read = seen   // no usable DOM text — read the page off the screen instead
                }
                guard let page = read, page.text.count >= 400 else {
                    // Blocked, paywalled, empty or a video — swap in the next best result.
                    if !backups.isEmpty { pending.append(backups.removeFirst()) }
                    continue
                }
                pages.append(page)
            }
            if !pages.isEmpty {
                await tools.aiResearchStatus("Taking notes on \(pages.count) page\(pages.count == 1 ? "" : "s")…")
                let allowFollow = follows < maxFollows
                let base = notes.count
                let results = await withTaskGroup(of: (Int, String?, String?).self) { group in
                    for (i, page) in pages.enumerated() {
                        group.addTask {
                            let (n, f) = await takeNotes(page: page, question: question, index: base + i + 1,
                                                         allowFollow: allowFollow, askFresh: askFresh)
                            return (i, n, f)
                        }
                    }
                    var out: [(Int, String?, String?)] = []
                    for await r in group { out.append(r) }
                    return out.sorted { $0.0 < $1.0 }
                }
                try Task.checkCancellation()
                for (i, pageNotes, follow) in results {
                    let page = pages[i]
                    if let pageNotes {
                        notes.append((page.title, page.url, String(pageNotes.prefix(noteChars))))
                        await tools.aiResearchKeepSource(title: page.title, url: page.url)
                    }
                    // Poke around: a page pointed at a fuller source on the topic.
                    if let follow, follows < maxFollows, !readURLs.contains(normalize(follow)), usable(follow) {
                        follows += 1
                        round.append(follow)
                    }
                }
            }
            if !round.isEmpty { continue }
            // Too few useful sources → read the next-best results.
            if notes.count < 3, !backups.isEmpty {
                while round.count < 3 - notes.count, !backups.isEmpty { round.append(backups.removeFirst()) }
                continue
            }
            // 5. Gap check (only when coverage is thin): one more targeted search.
            if notes.count < targetSources, !gapChecked {
                gapChecked = true
                if let q = await gapQuery(question: question, notes: notes, askFresh: askFresh) {
                    await tools.aiResearchStatus("Digging further: \(q)")
                    var fresh: [ResearchLink] = []
                    for link in await tools.aiResearchSearch(q) where usable(link.url) {
                        if seen.insert(normalize(link.url)).inserted { fresh.append(link) }
                    }
                    round = await pick(fresh, count: 2, question: question, askFresh: askFresh)
                    if !round.isEmpty { continue }
                }
            }
            break
        }
        chips.append("📖 \(notes.count) source\(notes.count == 1 ? "" : "s") read")

        // 6. Write.
        try Task.checkCancellation()
        guard !notes.isEmpty else {
            return ("I searched and tried \(reads) page\(reads == 1 ? "" : "s"), but none of them had readable content on this. Try rewording, or open a page you trust and run /research on it.", chips)
        }
        await tools.aiResearchStatus("Writing it up from \(notes.count) sources…")
        let answer = try await synthesize(question: question, userText: userText, notes: notes, mode: mode,
                                          ask: ask, askFresh: askFresh)
        return (answer, chips)
    }

    /// /summarize: read the page's main content (the article, not the nav), fall
    /// back to reading the screen when there's no DOM text, then one model call.
    static func summarize(userText: String, tools: any BrowserAITools,
                          askFresh: (String) async throws -> String) async throws -> (answer: String, chips: [String]) {
        await tools.aiResearchStatus("Reading the page…")
        var chips = ["📄 Page"]
        var source = ""
        if let page = await tools.aiReadCurrentMain(), page.text.count >= 400 {
            source = "Page: \(page.title) — \(page.url)\n\n\(page.text)"
        }
        if source.count < 600 {
            // Image-heavy, canvas or PDF page: read what's on screen instead / too.
            let seen = await tools.aiLookAtPage()
            chips.append("👁️ Looked")
            source += (source.isEmpty ? "" : "\n\n") + seen
        }
        try Task.checkCancellation()
        guard !source.isEmpty else {
            return ("There's no page open for me to summarize — open one and run /summarize again.", chips)
        }
        await tools.aiResearchStatus("Summarizing…")
        let reply = try await askFresh("""
        \(userText)

        \(source)

        Write the summary from this content only. No action lines, no process narration.
        """)
        return (Agent.stripActionLinesPublic(reply), chips)
    }

    // MARK: - Model steps

    /// Rank candidate links; falls back to search order if the reply is unusable.
    private static func pick(_ links: [ResearchLink], count: Int, question: String,
                             askFresh: (String) async throws -> String) async -> [String] {
        guard !links.isEmpty else { return [] }
        let list = links.prefix(20).enumerated().map { i, l in
            "\(i + 1). \(l.title) — \(l.url)\(l.snippet.isEmpty ? "" : "\n   \(l.snippet.prefix(180))")"
        }.joined(separator: "\n")
        let prompt = """
        Research question: \(question)

        Search results:
        \(list)

        Pick the \(count) results most worth reading to answer the question thoroughly. \
        Prefer comprehensive, authoritative pages (encyclopedias, full lists and \
        databases, official sources, reputable outlets) and a mix of different sites. \
        Skip videos, social posts, shops and thin listicles when better options exist. \
        Reply with ONLY the numbers, best first, comma-separated (e.g. 4, 1, 7).
        """
        let reply = (try? await askFresh(prompt)) ?? ""
        var picked: [String] = []
        for token in reply.split(whereSeparator: { !$0.isNumber }) {
            if let n = Int(token), (1...min(20, links.count)).contains(n) {
                let u = links[n - 1].url
                if !picked.contains(u) { picked.append(u) }
            }
            if picked.count >= count { break }
        }
        if picked.isEmpty { picked = Array(links.prefix(count).map(\.url)) }
        return picked
    }

    private static func takeNotes(page: ResearchPage, question: String, index: Int, allowFollow: Bool,
                                  askFresh: (String) async throws -> String) async -> (String?, String?) {
        let links = page.links.prefix(40).map { "- \($0.title) — \($0.url)" }.joined(separator: "\n")
        let prompt = """
        You are reading source #\(index) for this research question: \(question)

        Source: \(page.title) — \(page.url)
        Content:
        \(page.text)

        Extract every fact on this page that helps answer the question, as terse \
        bullets: names, titles, numbers, dates, roles, direct claims. If the question \
        asks for a list ("every", "all", "list"), copy EVERY matching item on the page — \
        do not sample or summarize the list. Note what this page says about how \
        complete or current it is. Do not add anything the page doesn't say.
        If nothing on the page is relevant, reply with just: IRRELEVANT
        \(allowFollow && !links.isEmpty ? """

        Links on this page:
        \(links)
        If ONE of these links would clearly add important missing information (a fuller \
        list, the primary source, a dedicated page on the topic), end with a line \
        FOLLOW: <url> using a URL from that list exactly. Otherwise don't add it.
        """ : "")
        """
        guard let reply = try? await askFresh(prompt) else {
            // Model hiccup: keep a raw excerpt so the source still counts.
            return (String(page.text.prefix(noteChars)), nil)
        }
        var follow: String?
        var kept: [Substring] = []
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            if let v = value(stripBullet(String(line)), "FOLLOW:") {
                let u = v.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                if allowFollow, page.links.contains(where: { $0.url == u }) { follow = u }
            } else {
                kept.append(line)
            }
        }
        let body = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty || body.uppercased().hasPrefix("IRRELEVANT") { return (nil, follow) }
        return (body, follow)
    }

    private static func gapQuery(question: String, notes: [(title: String, url: String, text: String)],
                                 askFresh: (String) async throws -> String) async -> String? {
        let digest = notes.map { "From \($0.title):\n\($0.text.prefix(1500))" }.joined(separator: "\n\n")
        let prompt = """
        Research question: \(question)

        Notes gathered so far:
        \(digest.isEmpty ? "(nothing useful yet)" : digest)

        Is something important still missing to answer the question fully and \
        accurately? If yes, reply with ONLY one line: SEARCH: <plain keyword query \
        that would find it> (no quotes, site:, OR, or years). If the notes already \
        cover it, reply with ONLY: DONE
        """
        guard let reply = try? await askFresh(prompt) else { return nil }
        for raw in reply.split(separator: "\n") {
            if let v = value(stripBullet(String(raw)), "SEARCH:"), !v.isEmpty { return v }
        }
        return nil
    }

    private static func synthesize(question: String, userText: String,
                                   notes: [(title: String, url: String, text: String)], mode: Mode,
                                   ask: (String) async throws -> String,
                                   askFresh: (String) async throws -> String) async throws -> String {
        let sources = notes.enumerated().map { i, n in
            "[\(i + 1)] \(n.title) — \(n.url)\n\(n.text)"
        }.joined(separator: "\n\n")
        let prompt = """
        The user asked: \(userText)
        Research question: \(question)

        You opened and read these \(notes.count) sources in the browser. Your notes:

        \(sources)

        \(mode == .factcheck ? """
        Write the fact-check from these notes ONLY — no outside facts, no guessing. Format:
        - First line: **Verdict: TRUE**, **FALSE**, **MIXED** or **UNVERIFIED** (use \
        UNVERIFIED when the sources don't settle it — never guess).
        - Then 2–3 sentences on why, naming what's right and what's wrong in the claim.
        - Then "Evidence" as short bullets, each citing its source as a markdown link \
        with the exact URL above, e.g. [Reuters](https://…).
        Keep it tight. No action lines, no mention of "notes", no process narration.
        """ : """
        Write the research answer from these notes ONLY — no outside facts, no \
        guessing. Format:
        - Open with a one or two sentence direct answer.
        - Then the findings in detail. If the user asked for a list, give the COMPLETE \
        merged list (deduplicated, each item once) rather than highlights.
        - Cite sources inline as markdown links, e.g. [Wikipedia](https://…), using the \
        exact URLs above.
        - End with a short "Gaps & disagreements" note if sources conflict or coverage \
        may be incomplete.
        No action lines, no mention of "notes", no process narration.
        """)
        """
        do {
            let reply = try await askFresh(prompt)
            let s = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        } catch is CancellationError { throw CancellationError() }
        catch {}
        // Fall back to the conversational window rather than failing the run.
        return try await ask(prompt)
    }

    // MARK: - Helpers

    private static func stripBullet(_ s: String) -> String {
        var l = s.trimmingCharacters(in: .whitespaces)
        while let f = l.first, "`*->•#".contains(f) { l.removeFirst() }
        return l.trimmingCharacters(in: .whitespaces)
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.uppercased().hasPrefix(key) else { return nil }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'`*"))
    }

    static func normalize(_ url: String) -> String {
        var s = url.lowercased()
        if let h = s.firstIndex(of: "#") { s = String(s[..<h]) }
        s = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if s.hasPrefix("www.") { s.removeFirst(4) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func host(_ url: String) -> String {
        let h = URL(string: url)?.host ?? url
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Pages that don't have readable text for a research read.
    private static func usable(_ url: String) -> Bool {
        guard let u = URL(string: url), let h = u.host?.lowercased(),
              ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
        let blocked = ["youtube.com", "youtu.be", "tiktok.com", "instagram.com", "facebook.com",
                       "x.com", "twitter.com", "pinterest.", "open.spotify.com", "music.apple.com"]
        if blocked.contains(where: { h == $0 || h.hasSuffix("." + $0) || ($0.hasSuffix(".") && h.contains($0)) }) { return false }
        let path = u.path.lowercased()
        return !(path.hasSuffix(".png") || path.hasSuffix(".jpg") || path.hasSuffix(".jpeg") ||
                 path.hasSuffix(".gif") || path.hasSuffix(".webp") || path.hasSuffix(".mp4"))
    }

    /// Distinctive words from the question, used to keep the relevant slice of a
    /// huge page (e.g. the Taylor Swift rows of a 100k-char discography table).
    static func focusTerms(_ text: String) -> [String] {
        let stop: Set<String> = ["research", "about", "every", "list", "what", "which", "where", "when",
                                 "that", "this", "with", "from", "have", "their", "there", "they",
                                 "your", "into", "been", "were", "does", "songs", "song", "credited",
                                 "credits", "produced", "producer", "worked", "work", "find", "give",
                                 "tell", "please", "more", "most", "best", "some", "also", "only"]
        var out: [String] = []
        for w in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let s = String(w)
            if s.count >= 4, !stop.contains(s), !out.contains(s) { out.append(s) }
        }
        return Array(out.prefix(10))
    }
}
