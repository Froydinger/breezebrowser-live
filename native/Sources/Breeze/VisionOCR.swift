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
