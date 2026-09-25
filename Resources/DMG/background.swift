// Draws the DMG window background at 1x and 2x. make-dmg.sh runs it.
//   swift background.swift <out-dir>
//
// Light on purpose: with a background picture, Finder draws the icon
// labels in black whatever the system appearance.
import AppKit

let W: CGFloat = 660, H: CGFloat = 352
// The icon row. settings.py centres the icons on it at x = 170 and 490.
let iconY: CGFloat = 140

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locs)!
}

func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

/// A band whose top edge is a smooth curve through `crest`, filled to the bottom.
func wave(_ crest: [CGPoint]) -> (fill: CGPath, edge: CGPath) {
    let edge = CGMutablePath()
    edge.move(to: crest[0])
    for i in 1..<crest.count {
        let a = crest[i - 1], b = crest[i]
        let mx = (a.x + b.x) / 2
        edge.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
    }
    let band = edge.mutableCopy()!
    band.addLine(to: CGPoint(x: crest.last!.x, y: H + 10))
    band.addLine(to: CGPoint(x: crest[0].x, y: H + 10))
    band.closeSubpath()
    return (band, edge)
}

// MARK: - Arrow

/// Point on a cubic Bézier.
func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x, y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
}

/// Colour at `t` along the stroke: blue, violet, pink, orange.
func strokeColor(_ t: CGFloat) -> CGColor {
    let stops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
        (0, (0.29, 0.53, 0.97)), (0.45, (0.55, 0.36, 0.96)), (0.7, (0.78, 0.38, 0.75)), (1, (0.97, 0.50, 0.20)),
    ]
    var i = 0
    while i < stops.count - 2 && t > stops[i + 1].0 { i += 1 }
    let (t0, a) = stops[i], (t1, b) = stops[i + 1]
    let f = max(0, min(1, (t - t0) / (t1 - t0)))
    return CGColor(srgbRed: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: 1)
}

/// A brush-stroke arrow: a Z-shaped curl that settles into a straight run
/// up and to the right, thin at the start, its colour following the stroke.
func drawArrow(_ ctx: CGContext) {
    // Designed in a 232x100 box, then scaled into the gap between the icons.
    let origin = CGPoint(x: 262, y: iconY - 29), k: CGFloat = 0.578
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * k, y: origin.y + y * k) }
    let segments: [(CGPoint, CGPoint, CGPoint, CGPoint)] = [
        (p(2, 40), p(22, 10), p(67, -2), p(94, 2)),
        (p(94, 2), p(120, 6), p(97, 45), p(74, 78)),
        (p(74, 78), p(62, 96), p(92, 102), p(120, 96)),
        (p(120, 96), p(157, 88), p(197, 68), p(230, 56)),
    ]
    var points: [CGPoint] = []
    for (i, s) in segments.enumerated() {
        for j in (i == 0 ? 0 : 1)...60 { points.append(bezier(s.0, s.1, s.2, s.3, CGFloat(j) / 60)) }
    }
    var lengths: [CGFloat] = [0]
    for i in 1..<points.count {
        lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
    }
    let fullWidth: CGFloat = 6.5
    func width(_ t: CGFloat) -> CGFloat { 2.5 + (fullWidth - 2.5) * min(1, t / 0.3) }

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 10, color: color(0x8B5CF6, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for i in 1..<points.count {
        let t = lengths[i] / lengths.last!
        ctx.setStrokeColor(strokeColor(t))
        ctx.setLineWidth(width(t))
        ctx.move(to: points[i - 1])
        ctx.addLine(to: points[i])
        ctx.strokePath()
    }
    // Open head, pointing along the final run
    let tip = points.last!, back = points[points.count - 8]
    let angle = atan2(back.y - tip.y, back.x - tip.x)
    ctx.setStrokeColor(strokeColor(1))
    ctx.setLineWidth(fullWidth)
    for side in [-1.0, 1.0] as [CGFloat] {
        let a = angle + side * 0.75
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x + 17 * cos(a), y: tip.y + 17 * sin(a)))
    }
    ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    // Base
    fill(ctx, CGPath(rect: CGRect(x: 0, y: 0, width: W, height: H), transform: nil),
         gradient([color(0xFBFBFE), color(0xF1EFFB)]), from: .zero, to: CGPoint(x: 0, y: H))

    // Silk waves along the bottom, rising at the edges
    let waves: [([CGPoint], UInt32, CGFloat)] = [
        ([CGPoint(x: -20, y: 150), CGPoint(x: 150, y: 250), CGPoint(x: 360, y: 290), CGPoint(x: 560, y: 250), CGPoint(x: 690, y: 170)], 0xC9C3F2, 0.35),
        ([CGPoint(x: -20, y: 215), CGPoint(x: 190, y: 285), CGPoint(x: 420, y: 305), CGPoint(x: 600, y: 270), CGPoint(x: 690, y: 235)], 0xB4B9F0, 0.35),
        ([CGPoint(x: -20, y: 285), CGPoint(x: 220, y: 318), CGPoint(x: 460, y: 330), CGPoint(x: 690, y: 300)], 0xA9A6EC, 0.3),
    ]
    for (crest, hex, alpha) in waves {
        let (band, edge) = wave(crest)
        fill(ctx, band, gradient([color(hex, alpha), color(hex, alpha * 0.35)]),
             from: CGPoint(x: 0, y: crest.map(\.y).min()!), to: CGPoint(x: 0, y: H))
        ctx.addPath(edge)
        ctx.setStrokeColor(color(0xFFFFFF, 0.8))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    drawArrow(ctx)

    // Text
    func text(_ s: NSAttributedString, y: CGFloat) {
        s.draw(at: CGPoint(x: (W - s.size().width) / 2, y: y))
    }
    let strong = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.24, alpha: 1)
    let muted = NSColor(srgbRed: 0.33, green: 0.33, blue: 0.42, alpha: 1)
    text(NSAttributedString(string: "Drag Convoy to Applications",
                            attributes: [.foregroundColor: strong, .font: NSFont.systemFont(ofSize: 15, weight: .semibold)]),
         y: 262)
    let note: [NSAttributedString.Key: Any] = [.foregroundColor: muted, .font: NSFont.systemFont(ofSize: 12)]
    let bold: [NSAttributedString.Key: Any] = [.foregroundColor: strong, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
    let line1 = NSMutableAttributedString(string: "First open: if macOS can't verify Convoy, open ", attributes: note)
    line1.append(NSAttributedString(string: "System Settings › Privacy & Security,", attributes: bold))
    text(line1, y: 294)
    let line2 = NSMutableAttributedString(string: "scroll all the way down, and click ", attributes: note)
    line2.append(NSAttributedString(string: "Open Anyway", attributes: bold))
    line2.append(NSAttributedString(string: ".", attributes: note))
    text(line2, y: 312)
}

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // A hair under the window size: an image even slightly larger makes
    // Finder show scroll bars.
    rep.size = NSSize(width: W - 0.5, height: H - 0.5)
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // The rep already maps points to pixels; only flip to a top-left origin.
    ctx.translateBy(x: 0, y: rep.size.height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    draw(ctx)
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
render(scale: 1, to: out.appendingPathComponent("background.png"))
render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
