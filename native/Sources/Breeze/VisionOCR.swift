// On-device image understanding via Apple's Vision framework: OCR (text in the
// image) + scene/classification labels. Lets the text model "read" attachments
// even though it isn't a vision model. Runs off the main thread.

import AppKit
import Vision

enum VisionOCR {
    static func describe(_ url: URL) -> String {
        guard let img = NSImage(contentsOf: url) else { return "(couldn't read image)" }
        var rect = NSRect(origin: .zero, size: img.size)
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return "(couldn't read image)" }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        let classReq = VNClassifyImageRequest()
        try? handler.perform([textReq, classReq])

        let lines = (textReq.results)?.compactMap { $0.topCandidates(1).first?.string } ?? []
        let labels = (classReq.results)?
            .filter { $0.confidence > 0.25 }
            .prefix(6)
            .map { $0.identifier } ?? []

        var out = ""
        if !labels.isEmpty { out += "Image appears to show: \(labels.joined(separator: ", ")).\n" }
        if !lines.isEmpty { out += "Text in the image:\n" + lines.joined(separator: "\n") }
        if out.isEmpty { out = "(no readable text or recognizable content)" }
        return out
    }
}

extension VisionOCR {
    /// OCR a rendered page (a WKWebView snapshot) into reading-order lines, each
    /// tagged with where it sits on screen so the model can talk about layout
    /// ("the banner at the top", "the price on the right"). Text only — nothing
    /// is sent as an image, so it costs the same as reading page text.
    static func readScreen(_ cg: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        let obs = (req.results ?? []).compactMap { o -> (String, CGRect)? in
            guard let s = o.topCandidates(1).first?.string, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (s, o.boundingBox)   // normalized, origin bottom-left
        }
        // Group into visual rows (similar vertical centre), rows top→bottom, words left→right.
        let sorted = obs.sorted { $0.1.midY > $1.1.midY }
        var rows: [[(String, CGRect)]] = []
        for o in sorted {
            if let last = rows.last?.first, abs(last.1.midY - o.1.midY) < max(0.008, o.1.height * 0.5) {
                rows[rows.count - 1].append(o)
            } else { rows.append([o]) }
        }
        return rows.map { row in
            let r = row.sorted { $0.1.minX < $1.1.minX }
            let y = 1 - (r.first?.1.midY ?? 0.5), x = r.first?.1.minX ?? 0
            let v = y < 0.2 ? "top" : (y > 0.8 ? "bottom" : "middle")
            let h = x < 0.33 ? "left" : (x > 0.6 ? "right" : "centre")
            return "[\(v)-\(h)] " + r.map(\.0).joined(separator: "   ")
        }
    }
}
