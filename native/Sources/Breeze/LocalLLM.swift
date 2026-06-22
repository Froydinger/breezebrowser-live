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
    // Llama 3.1 8B (Q4_K_M) — best on 16GB+ Apple Silicon. Apple FM is fallback only.
    // We reuse any existing 8B gguf to avoid a re-download.
    private let remote = URL(string: "https://huggingface.co/lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf")!
    private var server: Process?
    private(set) var ready = false
    var lastStatus = "Breeze AI runs locally. Download Llama 3.1 8B to start."
    private var starting = false
    private var history: [[String: String]] = []
    private var downloadDone: ((Bool) -> Void)?
    private var working = false
    private var pending: [(Bool) -> Void] = []

    init(tools: any BrowserAITools) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Breeze/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Reuse any already-downloaded 8B gguf; otherwise this is the download target.
        let existing = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil))?
            .first { let n = $0.lastPathComponent.lowercased()
                     return n.hasSuffix(".gguf") && n.contains("8b") && (n.contains("llama") || n.contains("qwen")) }
        modelURL = existing ?? base.appendingPathComponent("meta-llama-3.1-8b-instruct-q4_k_m.gguf")
        super.init()
        browser = tools
        resetChat()
    }

    func resetChat() {
        history = [["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))]]
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
    private func setStatus(_ s: String) {
        lastStatus = s
        if Thread.isMainThread {
            self.onStatus?(s)
        } else {
            DispatchQueue.main.async {
                self.onStatus?(s)
            }
        }
    }
    private func finish(_ ok: Bool) {
        working = false
        let cbs = pending; pending = []
        cbs.forEach { $0(ok) }
    }

    private func download(_ done: @escaping (Bool) -> Void) {
        setStatus("Downloading Llama 3.1 8B (~4.8 GB)… 0%")
        downloadDone = done
        let cfg = URLSessionConfiguration.default
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session.downloadTask(with: remote).resume()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let pct = Int(Double(totalBytesWritten) / Double(total) * 100)
        self.setStatus("Downloading Llama 3.1 8B (~4.8 GB)… \(pct)%")
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: modelURL)
            try FileManager.default.moveItem(at: location, to: modelURL)
            DispatchQueue.main.async { self.downloadDone?(true); self.downloadDone = nil }
        } catch {
            self.setStatus("Download failed: \(error.localizedDescription)")
            self.downloadDone?(false)
            self.downloadDone = nil
        }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            self.setStatus("Download failed: \(error.localizedDescription)")
            self.downloadDone?(false)
            self.downloadDone = nil
        }
    }

    private func launch(_ done: @escaping (Bool) -> Void) {
        if ready { done(true); return }
        if starting { pollHealth(done); return }
        guard let bin = llamaServerPath() else {
            setStatus("llama-server not found. Install with: brew install llama.cpp")
            done(false)
            return
        }
        starting = true
        setStatus("Starting local model…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", modelURL.path, "--host", "127.0.0.1", "--port", "\(port)",
                       "-c", "8192", "-ngl", "99"]
        p.standardOutput = nil; p.standardError = nil
        do {
            try p.run()
            server = p
        } catch {
            starting = false
            setStatus("Couldn't start model: \(error.localizedDescription)")
            done(false)
            return
        }
        pollHealth(done)
    }

    private func pollHealth(_ done: @escaping (Bool) -> Void, attempt: Int = 0) {
        if attempt > 90 {
            starting = false
            setStatus("Model didn't come up in time.")
            done(false)
            return
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                self.ready = true
                self.starting = false
                self.setStatus("On-device model ready.")
                done(true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.pollHealth(done, attempt: attempt + 1) }
            }
        }.resume()
    }

    func shutdown() { server?.terminate(); server = nil; ready = false }

    // MARK: - Chat

    func send(_ text: String, history: [[String: String]], contexts: [AIContext], completion: @escaping (Result<(String, [String]), Error>) -> Void) {
        ensure { ok in
            guard ok, let tools = self.browser else { completion(.failure(NSError(domain: "Breeze", code: 1, userInfo: [NSLocalizedDescriptionKey: "The local model isn't ready yet."]))); return }
            Task {
                do {
                    var turnHistory: [[String: String]] = [
                        ["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))]
                    ]
                    for msg in history {
                        let role = msg["role"] == "ai" ? "assistant" : "user"
                        if let content = msg["text"] {
                            turnHistory.append(["role": role, "content": content])
                        }
                    }
                    let (answer, chips) = try await Agent.run(
                        userText: text, contexts: contexts, tools: tools,
                        ask: { msg in
                            turnHistory.append(["role": "user", "content": msg])
                            let reply = try await self.complete(history: turnHistory)
                            turnHistory.append(["role": "assistant", "content": reply])
                            return reply
                        },
                        askFresh: { msg in
                            let freshHistory: [[String: String]] = [
                                ["role": "system", "content": Agent.systemPrompt(extra: Store.shared.string("aiInstructions"))],
                                ["role": "user", "content": msg]
                            ]
                            let reply = try await self.complete(history: freshHistory)
                            return reply
                        })
                    await MainActor.run { completion(.success((answer, chips))) }
                } catch {
                    await MainActor.run { completion(.failure(error)) }
                }
            }
        }
    }

    private func complete(history: [[String: String]]) async throws -> String {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body: [String: Any] = ["model": "llama-3.1-8b", "messages": history,
                                   "temperature": 0.5, "stream": false,
                                   "cache_prompt": true, "n_predict": 1024]
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
}
