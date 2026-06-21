// Local Qwen backend. Runs llama-server (Homebrew) as a subprocess with the
// Qwen2.5 GGUF and talks to its OpenAI-compatible API on localhost. Fully local;
// the model is downloaded once to Application Support. Agentic: the model can
// request a web search (SEARCH: protocol) which we run and feed back — same
// effect as the Electron Qwen function-calling build.

import Foundation

final class LocalLLM: NSObject, URLSessionDownloadDelegate {
    weak var browser: (any BrowserAITools)?
    var onStatus: ((String) -> Void)?

    private let port = 8799
    private let modelURL: URL
    // Qwen2.5 7B (Q4_K_M) — best on 16GB+ Apple Silicon. The 3B is intentionally
    // dropped (too weak). We reuse any existing 7B gguf to avoid a re-download.
    private let remote = URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!
    private var server: Process?
    private(set) var ready = false
    private var starting = false
    private var history: [[String: String]] = []
    private var downloadDone: ((Bool) -> Void)?
    private var working = false
    private var pending: [(Bool) -> Void] = []

    init(tools: any BrowserAITools) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Breeze/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Reuse any already-downloaded 7B gguf; otherwise this is the download target.
        let existing = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))?
            .first { let n = $0.lastPathComponent.lowercased()
                     return n.hasSuffix(".gguf") && n.contains("7b") && n.contains("instruct") }
        modelURL = existing ?? base.appendingPathComponent("qwen2.5-7b-instruct-q4_k_m.gguf")
        super.init()
        browser = tools
        resetChat()
    }

    func resetChat() {
        let df = DateFormatter(); df.dateStyle = .full
        history = [["role": "system", "content": """
        You are Breeze, a private assistant inside a web browser, running entirely on \
        the user's Mac via a local model. Today is \(df.string(from: Date())). Be concise. \
        You may be given the text of the page the user is viewing — use it when they ask \
        about "this page". When a question needs current or factual info you're unsure of, \
        reply with ONLY one line: SEARCH: <query>. Never invent facts.
        """]]
    }

    private func llamaServerPath() -> String? {
        for p in ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: - Lifecycle

    func ensure(_ done: @escaping (Bool) -> Void) {
        if ready { done(true); return }
        pending.append(done)
        if working { return }            // a download/launch is already in flight
        working = true
        if FileManager.default.fileExists(atPath: modelURL.path) {
            launch { self.finish($0) }
        } else {
            download { ok in ok ? self.launch { self.finish($0) } : self.finish(false) }
        }
    }
    private func finish(_ ok: Bool) {
        working = false
        let cbs = pending; pending = []
        cbs.forEach { $0(ok) }
    }

    private func download(_ done: @escaping (Bool) -> Void) {
        onStatus?("Downloading Qwen 7B (~4.7 GB)… 0%")
        downloadDone = done
        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session.downloadTask(with: remote).resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(total) * 100)
        DispatchQueue.main.async { self.onStatus?("Downloading Qwen 7B (~4.7 GB)… \(pct)%") }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: modelURL)
            try FileManager.default.moveItem(at: location, to: modelURL)
            DispatchQueue.main.async { self.downloadDone?(true); self.downloadDone = nil }
        } catch {
            DispatchQueue.main.async { self.onStatus?("Download failed: \(error.localizedDescription)"); self.downloadDone?(false); self.downloadDone = nil }
        }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { DispatchQueue.main.async { self.onStatus?("Download failed: \(error.localizedDescription)"); self.downloadDone?(false); self.downloadDone = nil } }
    }

    private func launch(_ done: @escaping (Bool) -> Void) {
        if ready { done(true); return }
        if starting { pollHealth(done); return }
        guard let bin = llamaServerPath() else {
            onStatus?("llama-server not found. Install with: brew install llama.cpp"); done(false); return
        }
        starting = true
        onStatus?("Starting local model…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", "\(port)",
                       "-c", "4096", "-ngl", "99", "--jinja"]
        p.standardOutput = nil; p.standardError = nil
        do { try p.run(); server = p } catch { starting = false; onStatus?("Couldn't start model: \(error.localizedDescription)"); done(false); return }
        pollHealth(done)
    }

    private func pollHealth(_ done: @escaping (Bool) -> Void, attempt: Int = 0) {
        if attempt > 90 { starting = false; onStatus?("Model didn't come up in time."); done(false); return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                DispatchQueue.main.async { self.ready = true; self.starting = false; self.onStatus?("On-device model ready."); done(true) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollHealth(done, attempt: attempt + 1) }
            }
        }.resume()
    }

    func shutdown() { server?.terminate(); server = nil; ready = false }

    // MARK: - Chat

    func send(_ text: String, contexts: [AIContext], completion: @escaping (Result<(String, Bool), Error>) -> Void) {
        ensure { ok in
            guard ok else { completion(.failure(NSError(domain: "Breeze", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local model isn't ready yet."]))); return }
            Task {
                do {
                    var ctx = ""
                    for c in contexts { ctx += "[\(c.label)]\n\(String(c.text.prefix(1500)))\n\n" }
                    let userMsg = ctx.isEmpty ? text : "Context from open tabs:\n\(ctx)\nUser: \(text)"
                    self.history.append(["role": "user", "content": userMsg])
                    var reply = try await self.complete()
                    var usedSearch = false
                    if let q = Self.extractSearch(reply), let b = self.browser {
                        usedSearch = true
                        let results = await b.aiSearchWeb(q)
                        self.history.append(["role": "assistant", "content": reply])
                        self.history.append(["role": "user", "content": "Web search results for \"\(q)\":\n\(String(results.prefix(2600)))\n\nUsing these, answer my question fully."])
                        reply = try await self.complete()
                    }
                    self.history.append(["role": "assistant", "content": reply])
                    let final = reply, searched = usedSearch
                    await MainActor.run { completion(.success((final, searched))) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
        }
    }

    private func complete() async throws -> String {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = ["model": "qwen", "messages": history, "temperature": 0.5, "stream": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw NSError(domain: "Breeze", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected response from the model."])
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
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
