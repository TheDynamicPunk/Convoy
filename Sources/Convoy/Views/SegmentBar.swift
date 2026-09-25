import SwiftUI
import DownloadEngine

/// The row's progress bar. One capsule, which splits into the download's
/// parts (see `SegmentMap`) while they are being fetched: a lane per
/// connection, or a stream's pieces in cells.
///
/// `split` morphs between the two with the same shapes throughout. Closed,
/// the parts' tiles butt together into the capsule's track and their fetched
/// bytes pack from the left into its fill; opening, the gaps widen, corners
/// round, and each part's bytes slide to where they sit in the file. Parts
/// start a little after the one to their left, so the split ripples across.
///
/// One `Canvas` rather than a view per part: a stream draws a hundred cells,
/// and the list can hold many running rows.
struct SegmentBar: View, Animatable {
    var map: SegmentMap?
    var progress: Double
    var color: Color
    /// 0 draws the capsule, 1 the parts.
    var split: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(progress, split) }
        set { (progress, split) = (newValue.first, newValue.second) }
    }

    /// Share of the morph by which the last part trails the first.
    private static let ripple = 0.3

    var body: some View {
        Canvas { context, size in
            let t = min(1, max(0, split))
            if t > 0, let map {
                drawParts(map, in: context, size: size, t: t)
            } else {
                drawCapsule(in: context, size: size)
            }
        }
    }

    private var track: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.4) }

    private func fillShading(to x: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [color.opacity(0.75), color]),
                        startPoint: .zero, endPoint: CGPoint(x: x, y: 0))
    }

    private static func capsule(_ rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2, style: .circular)
    }

    private func capsuleFillWidth(_ width: CGFloat) -> CGFloat { max(4, width * progress) }

    private func drawCapsule(in context: GraphicsContext, size: CGSize) {
        context.fill(Self.capsule(CGRect(origin: .zero, size: size)), with: .color(track))
        let width = capsuleFillWidth(size.width)
        context.fill(Self.capsule(CGRect(x: 0, y: 0, width: width, height: size.height)),
                     with: fillShading(to: width))
    }

    private func drawParts(_ map: SegmentMap, in context: GraphicsContext, size: CGSize, t: Double) {
        var context = context
        context.clip(to: Self.capsule(CGRect(origin: .zero, size: size)))
        let width = size.width, height = size.height
        let spans = map.spans
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * t }

        let narrowest = spans.map { ($0.end - $0.start) * width }.min() ?? 0
        // Cells too narrow to keep a gap run together.
        let fullGap: CGFloat = map.layout == .lanes ? 2 : (narrowest >= 3 ? 1 : 0)

        // Closed, the fetched bytes fill exactly the capsule's fill.
        let fetchedTotal = spans.reduce(0) { $0 + ($1.end - $1.start) * $1.filled } * width
        let capsuleFill = capsuleFillWidth(width)
        let scale = fetchedTotal > 0 ? capsuleFill / fetchedTotal : 0
        let firstFilled = spans.firstIndex { $0.filled > 0 }
        let lastFilled = spans.lastIndex { $0.filled > 0 }

        var tracks = Path()
        var fills: [Int: Path] = [:]   // by opacity, in hundredths
        // In flight: a lane's writing edge, a stream's cell. Each fades in
        // with its own part.
        var marks: [(path: Path, opacity: Double)] = []
        var packed: CGFloat = 0

        for (i, span) in spans.enumerated() {
            let delay = spans.count > 1 ? Self.ripple * Double(i) / Double(spans.count - 1) : 0
            let local = min(1, max(0, (t - delay) / (1 - Self.ripple)))
            let gap = fullGap * local

            // Closed, a tile reaches the next one: this also shuts the space
            // between a stream's tracks.
            let nextStart = i + 1 < spans.count ? spans[i + 1].start : 1
            let end = mix(nextStart, span.end, local)
            let x0 = span.start * width + (span.start > 0 ? gap / 2 : 0)
            let x1 = end * width - (end < 1 ? gap / 2 : 0)
            let fetched = (span.end - span.start) * span.filled * width * scale
            defer { packed += fetched }
            guard x1 > x0 else { continue }
            let cell = CGRect(x: x0, y: 0, width: x1 - x0, height: height)
            tracks.addPath(Path(roundedRect: cell, cornerRadius: 1.5 * local))

            if span.filled > 0 {
                let target: CGRect
                var opacity: Double
                switch map.layout {
                case .lanes:
                    target = CGRect(x: x0, y: 0, width: cell.width * span.filled, height: height)
                    opacity = 1
                case .pieces:
                    target = cell
                    opacity = 0.35 + 0.65 * span.filled
                    if span.isActive { opacity = max(opacity, 0.45) }
                }
                let rect = CGRect(x: mix(packed, target.minX, local), y: 0,
                                  width: mix(fetched, target.width, local), height: height)
                // Closed, only the fill's two ends are round.
                let leading = mix(i == firstFilled ? height / 2 : 0, 1.5, local)
                let trailing = mix(i == lastFilled ? height / 2 : 0, 1.5, local)
                let shape = UnevenRoundedRectangle(
                    topLeadingRadius: leading, bottomLeadingRadius: leading,
                    bottomTrailingRadius: trailing, topTrailingRadius: trailing, style: .circular
                ).path(in: rect)
                let key = Int((mix(1, opacity, local) * 100).rounded())
                fills[key, default: Path()].addPath(shape)

                // The lane's leading edge, where its connection is writing.
                if map.layout == .lanes, span.isActive, span.filled < 1, rect.width > 2 {
                    let tick = Path(CGRect(x: rect.maxX - 1.5, y: 0, width: 1.5, height: height))
                    // Only once the lanes have parted; in the closed bar it reads as a cut.
                    marks.append((tick, 0.85 * max(0, local - 0.6) / 0.4))
                }
            } else if map.layout == .pieces, span.isActive {
                marks.append((Path(roundedRect: cell, cornerRadius: 1.5 * local), local))
            }
        }

        // One path per layer, so tiles that touch draw without seams.
        context.fill(tracks, with: .color(track))
        let shading = fillShading(to: mix(capsuleFill, width, t))
        for (key, path) in fills {
            var layer = context
            layer.opacity = Double(key) / 100
            layer.fill(path, with: shading)
        }
        // Nothing fetched: the capsule's minimum nub fades out.
        if fetchedTotal == 0 {
            var nub = context
            nub.opacity = 1 - t
            nub.fill(Self.capsule(CGRect(x: 0, y: 0, width: capsuleFill, height: height)),
                     with: fillShading(to: capsuleFill))
        }
        let markColor: Color = map.layout == .lanes ? .white : color.opacity(0.45)
        for mark in marks where mark.opacity > 0 {
            var layer = context
            layer.opacity = mark.opacity
            layer.fill(mark.path, with: .color(markColor))
        }
    }
}
