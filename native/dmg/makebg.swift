// Generates the Breeze DMG background as a true @2x retina asset.
// Canvas is 1240x840 px, but the bitmap rep's *point* size is set to 620x420 so
// Finder lays it out in the 620x420-point DMG window at the right scale (a plain
// PNG carries no point size → Finder paints it 1:1 → the art renders 2x too big
// and clips). Output is TIFF, which preserves the rep's point size.
import AppKit

let scale: CGFloat = 2
let WPT: CGFloat = 620, HPT: CGFloat = 420          // window size in points
let W = Int(WPT * scale), H = Int(HPT * scale)      // pixels

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: WPT, height: HPT)          // <- makes it @2x

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// Draw in points; the context is scaled so coordinates below are window points.
ctx.scaleBy(x: scale, y: scale)

func c(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
let rect = NSRect(x: 0, y: 0, width: WPT, height: HPT)
// y-from-top helper (canvas origin is bottom-left)
func top(_ t: CGFloat) -> CGFloat { HPT - t }

// soft diagonal gradient (warm Breeze beige → cool accent blue)
let grad = NSGradient(colors: [c(244,241,237), c(234,235,245), c(221,229,250)],
                      atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
grad.draw(in: rect, angle: -78)

// large soft accent glow, lower-center behind the icon row
ctx.saveGState()
let glow = NSGradient(colors: [c(91,124,250,0.20), c(91,124,250,0)], atLocations: [0,1], colorSpace: .sRGB)!
glow.draw(in: NSRect(x: WPT/2 - 230, y: top(360), width: 460, height: 460),
          relativeCenterPosition: .zero)
ctx.restoreGState()

// fine top hairline for a polished framed feel
c(255,255,255,0.5).setFill()
NSRect(x: 0, y: top(2), width: WPT, height: 2).fill()

// wordmark near the top
let title = "Breeze" as NSString
let tAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 40, weight: .bold),
    .foregroundColor: c(32,32,38),
    .kern: 0.5]
let tSize = title.size(withAttributes: tAttrs)
title.draw(at: NSPoint(x: WPT/2 - tSize.width/2, y: top(78)), withAttributes: tAttrs)

// tagline under the wordmark
let tag = "Calm, private browsing" as NSString
let gAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: c(91,124,250,0.9),
    .kern: 1.5]
let gSize = tag.size(withAttributes: gAttrs)
tag.draw(at: NSPoint(x: WPT/2 - gSize.width/2, y: top(102)), withAttributes: gAttrs)

// arrow between the two icons (icon row centered at y=215 in the 620x420 window)
ctx.saveGState()
let ay = top(215)
let arrow = NSBezierPath()
arrow.lineWidth = 4.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 258, y: ay)); arrow.line(to: NSPoint(x: 362, y: ay))
arrow.move(to: NSPoint(x: 346, y: ay + 13)); arrow.line(to: NSPoint(x: 365, y: ay)); arrow.line(to: NSPoint(x: 346, y: ay - 13))
c(91,124,250,0.9).setStroke(); arrow.stroke()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let tiff = rep.tiffRepresentation!
try! tiff.write(to: URL(fileURLWithPath: "background.tiff"))
print("wrote background.tiff (\(W)x\(H)px @2x → \(Int(WPT))x\(Int(HPT))pt)")
