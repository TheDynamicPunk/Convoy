import Foundation

/// What a row's segment bar draws: the parts of a download, where each sits
/// on the bar, and how much of each has arrived.
///
/// A ranged download gets one lane per part, as wide as the bytes that part
/// owns. A stream has too many pieces to draw one each, so they are grouped
/// into at most `maxCells` cells, and a second track (split audio) follows
/// the first after a gap. A download with a single part has no map; the
/// plain bar says the same thing.
public struct SegmentMap: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        /// One lane per ranged part; a lane fills from its start.
        case lanes
        /// Grouped stream pieces; a cell's fill is its share of pieces done.
        case pieces
    }

    public struct Span: Sendable, Equatable {
        /// Where the span sits, as fractions of the bar's width.
        public var start: Double
        public var end: Double
        /// How much has arrived, 0...1.
        public var filled: Double
        /// Has a request in flight while the download runs.
        public var isActive: Bool
    }

    /// A stream piece's state, as `StreamDownloader` reports it.
    public enum PieceState: UInt8, Sendable {
        case pending, active, done
    }

    public var layout: Layout
    public var spans: [Span]

    /// Spans with a request in flight: connections for lanes, cells for pieces.
    public var activeCount: Int { spans.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    /// Cells a stream's pieces are grouped into, across all its tracks.
    static let maxCells = 100
    /// Space between a stream's tracks, as a fraction of the bar.
    static let trackGap = 0.012

    /// One lane per ranged part. Nil for fewer than two parts.
    static func lanes(_ parts: [(range: ClosedRange<Int64>, downloaded: Int64)], totalBytes: Int64) -> SegmentMap? {
        guard parts.count > 1, totalBytes > 0 else { return nil }
        let total = Double(totalBytes)
        let spans = parts
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { part -> Span in
                let size = part.range.upperBound - part.range.lowerBound + 1
                let filled = min(1, max(0, Double(part.downloaded) / Double(size)))
                return Span(
                    start: min(1, max(0, Double(part.range.lowerBound) / total)),
                    end: min(1, max(0, Double(part.range.upperBound + 1) / total)),
                    filled: filled,
                    isActive: filled < 1
                )
            }
        return SegmentMap(layout: .lanes, spans: spans)
    }

    /// A stream's pieces, per track, grouped into cells. Each track gets
    /// cells in proportion to its piece count, and at least one. Nil for
    /// fewer than two pieces.
    static func pieces(_ tracks: [[PieceState]], maxCells: Int = maxCells) -> SegmentMap? {
        let tracks = tracks.filter { !$0.isEmpty }
        let total = tracks.reduce(0) { $0 + $1.count }
        guard total > 1, maxCells > 0 else { return nil }

        let usable = 1 - Double(tracks.count - 1) * trackGap
        let budget = Double(min(total, maxCells))
        var spans: [Span] = []
        var cursor = 0.0
        for track in tracks {
            let width = usable * Double(track.count) / Double(total)
            let share = (budget * Double(track.count) / Double(total)).rounded()
            // Never more cells than pieces, so no cell is empty.
            let cells = max(1, min(track.count, Int(share)))
            for cell in 0..<cells {
                let slice = track[(track.count * cell / cells)..<(track.count * (cell + 1) / cells)]
                let done = slice.reduce(0) { $0 + ($1 == .done ? 1 : 0) }
                spans.append(Span(
                    start: cursor + width * Double(cell) / Double(cells),
                    end: cursor + width * Double(cell + 1) / Double(cells),
                    filled: Double(done) / Double(slice.count),
                    isActive: slice.contains(.active)
                ))
            }
            cursor += width + trackGap
        }
        return SegmentMap(layout: .pieces, spans: spans)
    }
}
