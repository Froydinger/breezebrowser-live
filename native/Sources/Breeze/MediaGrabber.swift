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

    static var isAvailable: Bool { toolPath("yt-dlp") != nil }

    /// The install line shown when yt-dlp is missing.
    static let installCommand = "brew install yt-dlp ffmpeg"
    /// The line shown when it is present but too old to work.
    static let upgradeCommand = "brew upgrade yt-dlp"

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
        guard let tool = toolPath("yt-dlp") else {
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
        ] + kind.formatArgs + [pageURL]

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
