import AppKit

/// A "Task" is a one-shot Nav superpower invoked by a `/slash` command from any
/// input surface — the Nav chat, fullscreen Nav, the new-chat ask bar, or the URL
/// bar. Tasks are Breeze's renamed and expanded "Plugins" feature: instead of a
/// settings toggle nobody finds, every Task is one keystroke away. Typing `/` pops
/// the Task palette; `/research electric cars` runs the Research task on that topic.
struct BreezeTask {
    /// Typed after the slash, e.g. "research". Lowercase, no spaces.
    let slug: String
    /// Palette title, e.g. "Research".
    let title: String
    /// One-line description shown in the palette.
    let subtitle: String
    /// SF Symbol shown beside the Task in the palette.
    let symbol: String
    /// true → the Task wants a prompt after it ("/research <topic>"). false → it
    /// acts on the page you're currently viewing and needs no extra text.
    let needsPrompt: Bool
    /// Placeholder/hint once the Task is picked.
    let placeholder: String

    /// Every Task Nav can run. Order is the palette order.
    static let all: [BreezeTask] = [
        BreezeTask(slug: "research", title: "Research",
                   subtitle: "Dig through several sources and write a sourced summary",
                   symbol: "sailboat.fill", needsPrompt: true,
                   placeholder: "What should Nav research?"),
        BreezeTask(slug: "summarize", title: "Summarize",
                   subtitle: "TL;DR the page or video you're on",
                   symbol: "text.line.first.and.arrowtriangle.forward", needsPrompt: false,
                   placeholder: "Summarize this page"),
        BreezeTask(slug: "factcheck", title: "Fact-check",
                   subtitle: "Verify a claim against multiple sources",
                   symbol: "checkmark.seal.fill", needsPrompt: true,
                   placeholder: "What claim should Nav check?"),
        BreezeTask(slug: "youtube", title: "Creator Tools",
                   subtitle: "Analyze the YouTube video you're on for creators",
                   symbol: "play.rectangle.fill", needsPrompt: false,
                   placeholder: "Analyze this YouTube page"),
    ]

    /// Resolve a typed token to a Task — exact slug first, then a unique prefix
    /// ("/res" → research) so the palette can run on partial input.
    static func match(_ token: String) -> BreezeTask? {
        let s = token.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let exact = all.first(where: { $0.slug == s }) { return exact }
        let prefixed = all.filter { $0.slug.hasPrefix(s) }
        return prefixed.count == 1 ? prefixed.first : nil
    }

    /// Tasks whose slug starts with `token` — used to filter the live palette as
    /// the user types. Empty token returns everything.
    static func suggestions(for token: String) -> [BreezeTask] {
        let s = token.lowercased().trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return all }
        return all.filter { $0.slug.hasPrefix(s) || $0.title.lowercased().contains(s) }
    }

    /// Parse raw input like "/research electric cars" into (task, "electric cars").
    /// Returns nil when the text isn't a slash-command for a known Task.
    static func parse(_ raw: String) -> (task: BreezeTask, prompt: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first, let task = match(String(head)) else { return nil }
        let prompt = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (task, prompt)
    }
}
