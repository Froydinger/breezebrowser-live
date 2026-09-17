// Downloading a video from a page that streams it in pieces.
//
// A streamed video has no single file behind it — it arrives as a manifest plus
// hundreds of segments — so WKDownload has nothing to point at. yt-dlp resolves
// the manifest, fetches the segments and hands back one file.
//
// It deliberately runs the copy of yt-dlp already on this Mac rather than a copy
// bundled inside Breeze:
//   * Sites change how they serve video constantly, and yt-dlp ships fixes within
//     days. A frozen bundled copy stops working within weeks and fails silently.
//   * An executable inside the app bundle needs its own signature, and would need
//     disable-library-validation once Breeze is notarized (see RELEASEPLAN.MD).
//   * It stays the user's tool, updated by the user, on their PATH.

import Foundation

enum MediaGrabber {
    /// Result's failure type must be an Error; yt-dlp's own messages are already
    /// readable, so this just carries one through.
    struct GrabError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// yt-dlp and ffmpeg live in Homebrew's bin, which a GUI app's PATH does not
    /// include — a GUI process inherits launchd's PATH, not a login shell's.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin"]

    static func toolPath(_ name: String) -> String? {
        for dir in searchPaths {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // MARK: - Breeze's own copy of yt-dlp

    /// Breeze keeps its own yt-dlp and updates it, rather than depending on the
    /// user having installed one and remembering to upgrade it.
    ///
    /// It lives in Application Support, NOT inside the app bundle, which matters:
    /// a file in the bundle is covered by the code signature, so it could not be
    /// replaced without invalidating it, and it would need its own signature and
    /// library-validation entitlement once Breeze is notarized. Outside the bundle
    /// it is just a file Breeze owns and can swap whenever a newer one exists.
    ///
    /// This is what stops the tool rotting. YouTube keeps changing how it serves
    /// video and yt-dlp ships fixes within days; a copy that is never refreshed
    /// starts returning 403 on most videos within weeks.
    static var managedDirectory: URL {
        Store.shared.supportDirectory.appendingPathComponent("tools", isDirectory: true)
    }
    static var managedTool: URL { managedDirectory.appendingPathComponent("yt-dlp") }

    static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// Refresh if the copy we have is older than this. yt-dlp releases roughly
    /// weekly and breakages are usually fixed within days of appearing.
    static let refreshInterval: TimeInterval = 7 * 24 * 3600

    static var hasManagedTool: Bool {
        FileManager.default.isExecutableFile(atPath: managedTool.path)
    }

    /// Prefer Breeze's copy, because that is the one that gets kept current. Fall
    /// back to whatever is on PATH so an existing Homebrew install still works.
    static func resolvedTool() -> String? {
        if hasManagedTool { return managedTool.path }
        return toolPath("yt-dlp")
    }

    static var isAvailable: Bool { resolvedTool() != nil }

    private static var managedToolAge: TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: managedTool.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    static var managedToolIsStale: Bool {
        guard let age = managedToolAge else { return true }
        return age > refreshInterval
    }

    private static var isFetching = false

    /// Download the current yt-dlp into Application Support.
    ///
    /// `completion` receives an error message, or nil on success. Safe to call
    /// when one is already in flight - the second caller is simply told to carry
    /// on with whatever copy exists.
    static func fetchLatestTool(completion: @escaping (String?) -> Void) {
        guard !isFetching else { DispatchQueue.main.async { completion(nil) }; return }
        isFetching = true
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120
        URLSession.shared.downloadTask(with: request) { temp, response, error in
            defer { isFetching = false }
            func finish(_ message: String?) { DispatchQueue.main.async { completion(message) } }
            if let error { return finish(error.localizedDescription) }
            guard let temp,
                  let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                return finish("Couldn't reach the yt-dlp download.")
            }
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: managedDirectory, withIntermediateDirectories: true)
                // Stage beside the target and swap, so a half-written file can never
                // end up being the thing Breeze tries to run.
                let staged = managedDirectory.appendingPathComponent("yt-dlp.incoming")
                try? fm.removeItem(at: staged)
                try fm.moveItem(at: temp, to: staged)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
                // A URLSession download carries no quarantine flag, but strip it
                // defensively rather than discover the exception later.
                try? fm.removeItem(at: managedTool)
                try fm.moveItem(at: staged, to: managedTool)
                finish(nil)
            } catch {
                finish(error.localizedDescription)
            }
        }.resume()
    }

    /// Make sure a usable yt-dlp exists before a download starts.
    ///
    /// Missing entirely: fetch it and wait, because nothing can happen without it.
    /// Present but stale: proceed immediately and refresh in the background, so a
    /// download is never held up by housekeeping.
    static func prepareTool(onNeedsFetch: @escaping () -> Void,
                            completion: @escaping (String?) -> Void) {
        if resolvedTool() == nil {
            onNeedsFetch()
            fetchLatestTool(completion: completion)
            return
        }
        if hasManagedTool && managedToolIsStale {
            fetchLatestTool { _ in }
        }
        completion(nil)
    }

    /// The install line shown when yt-dlp is missing.
    static let installCommand = "brew install yt-dlp ffmpeg"
    /// The line shown when it is present but too old to work.
    static let upgradeCommand = "brew upgrade yt-dlp"
    /// ffmpeg is still the user's to install - see noteMissingFFmpegOnce.
    static let ffmpegInstallCommand = "brew install ffmpeg"

    /// A 403 here almost never means what it says.
    ///
    /// YouTube gates its adaptive streams - everything above 360p, where video and
    /// audio arrive separately - behind checks that yt-dlp has to keep chasing, and
    /// it ships fixes within days. An out-of-date copy fails on exactly those
    /// streams while still managing the occasional ungated one, which is why some
    /// videos download and most do not. Measured directly: the same video and the
    /// same format 403'd on 2026.07.04 and downloaded cleanly on 2026.08.19.
    ///
    /// So a refusal is reported as what it almost certainly is - a stale tool with
    /// a one-line fix - rather than as a raw HTTP error the user can do nothing with.
    static func isLikelyStaleToolFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("403") || m.contains("forbidden")
            || m.contains("unable to download video data")
            || m.contains("nsig") || m.contains("player response")
            || m.contains("sign in to confirm")
    }

    static var hasFFmpeg: Bool { toolPath("ffmpeg") != nil }

    /// YouTube serves anything above 360p as separate video and audio streams, so
    /// merging them needs ffmpeg. Without it, ask for the best single file that
    /// needs no merging rather than failing - a lower-quality download beats an
    /// error, as long as the user is told why.
    static func formatArgs(for kind: Kind) -> [String] {
        guard hasFFmpeg else {
            return kind == .audio ? ["-f", "ba/b"] : ["-f", "b"]
        }
        return kind.formatArgs
    }

    enum Kind {
        case video, audio
        /// Cap at 1080p: above that YouTube serves video-only streams that must be
        /// muxed with a separate audio track, which is slower and much larger for
        /// little visible gain on a laptop display.
        var formatArgs: [String] {
            switch self {
            case .video:
                return ["-f", "bv*[height<=1080]+ba/b[height<=1080]/b",
                        "--merge-output-format", "mp4"]
            case .audio:
                return ["-x", "--audio-format", "m4a"]
            }
        }
    }

    /// Run yt-dlp for one page URL.
    ///
    /// `onProgress` reports bytes received/total, `onFinish` the resulting file or
    /// an error message. Both are delivered on the main queue. The returned Process
    /// can be terminated to cancel.
    @discardableResult
    static func download(pageURL: String,
                         kind: Kind,
                         into directory: URL,
                         onTitle: @escaping (String) -> Void,
                         onProgress: @escaping (Int64, Int64) -> Void,
                         onFinish: @escaping (Result<URL, GrabError>) -> Void) -> Process? {
        guard let tool = resolvedTool() else {
            DispatchQueue.main.async { onFinish(.failure(GrabError(message: "yt-dlp isn't installed."))) }
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        // The URL is passed as an argument, never through a shell, so a hostile
        // page title or query string cannot turn into a command.
        process.arguments = [
            "--newline",
            // Required. yt-dlp treats progress as terminal UI and suppresses it
            // when stdout is not a TTY - which is exactly what a Pipe is - so
            // without this the progress bar would sit at zero until the file
            // simply appeared. Verified: with it, progress lines arrive on stdout.
            "--progress",
            "--no-playlist",                 // a video inside a playlist is one video
            "--no-part",
            "--restrict-filenames",
            "--progress-template", "download:BZPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes,progress.total_bytes_estimate)s",
            "--print", "before_dl:BZTITLE %(title)s",
            "--print", "after_move:BZFILE %(filepath)s",
            "-o", directory.appendingPathComponent("%(title)s.%(ext)s").path,
        ] + formatArgs(for: kind) + [pageURL]

        var env = ProcessInfo.processInfo.environment
        // So yt-dlp can find ffmpeg, which it needs to merge video and audio.
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var producedFile: URL?
        var lastError = ""
        var buffer = ""

        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            buffer += text
            while let nl = buffer.firstIndex(of: "\n") {
                let line = String(buffer[buffer.startIndex..<nl])
                buffer = String(buffer[buffer.index(after: nl)...])
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                guard let tag = parts.first else { continue }
                switch tag {
                case "BZPROGRESS":
                    guard parts.count >= 3 else { continue }
                    let got = Int64(parts[1]) ?? 0
                    let total = Int64(parts[2]) ?? 0
                    DispatchQueue.main.async { onProgress(got, total) }
                case "BZTITLE":
                    guard parts.count >= 2 else { continue }
                    let title = parts.dropFirst().joined(separator: " ")
                    DispatchQueue.main.async { onTitle(title) }
                case "BZFILE":
                    guard parts.count >= 2 else { continue }
                    producedFile = URL(fileURLWithPath: parts.dropFirst().joined(separator: " "))
                default:
                    continue
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            // Keep the last real complaint; yt-dlp's errors are already readable.
            for line in text.split(separator: "\n") where line.contains("ERROR") {
                lastError = String(line).replacingOccurrences(of: "ERROR: ", with: "")
            }
        }

        process.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if proc.terminationStatus == 0, let file = producedFile {
                    onFinish(.success(file))
                } else if proc.terminationReason == .uncaughtSignal {
                    onFinish(.failure(GrabError(message: "Cancelled.")))
                } else {
                    onFinish(.failure(GrabError(message: lastError.isEmpty ? "Download failed." : lastError)))
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { onFinish(.failure(GrabError(message: error.localizedDescription))) }
            return nil
        }
        return process
    }
}
