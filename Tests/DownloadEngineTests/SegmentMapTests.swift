import XCTest
@testable import DownloadEngine

/// The row's segment bar: lanes for ranged parts, grouped cells for stream
/// pieces.
final class SegmentMapTests: XCTestCase {

    // MARK: - Lanes

    func testLanesAreAsWideAsTheirBytesAndFillFromTheirStart() throws {
        let map = try XCTUnwrap(SegmentMap.lanes([
            (range: 500...999, downloaded: 500),
            (range: 0...499, downloaded: 125),
        ], totalBytes: 1000))
        XCTAssertEqual(map.layout, .lanes)
        // Sorted by position, whatever order the parts came in.
        XCTAssertEqual(map.spans[0].start, 0)
        XCTAssertEqual(map.spans[0].end, 0.5)
        XCTAssertEqual(map.spans[0].filled, 0.25)
        XCTAssertTrue(map.spans[0].isActive)
        XCTAssertEqual(map.spans[1].end, 1)
        XCTAssertEqual(map.spans[1].filled, 1)
        XCTAssertFalse(map.spans[1].isActive, "a finished lane has no connection")
        XCTAssertEqual(map.activeCount, 1)
    }

    func testLaneFillIsClamped() throws {
        let map = try XCTUnwrap(SegmentMap.lanes([
            (range: 0...99, downloaded: 150),
            (range: 100...199, downloaded: -5),
        ], totalBytes: 200))
        XCTAssertEqual(map.spans.map(\.filled), [1, 0])
    }

    func testOnePartHasNoMap() {
        XCTAssertNil(SegmentMap.lanes([(range: 0...99, downloaded: 50)], totalBytes: 100))
    }

    // MARK: - Pieces

    func testManyPiecesAreGroupedIntoCells() throws {
        var track = [SegmentMap.PieceState](repeating: .pending, count: 596)
        for i in 0..<298 { track[i] = .done }
        track[300] = .active
        let map = try XCTUnwrap(SegmentMap.pieces([track]))
        XCTAssertEqual(map.layout, .pieces)
        XCTAssertEqual(map.spans.count, SegmentMap.maxCells)
        XCTAssertEqual(map.spans.first?.start, 0)
        XCTAssertEqual(try XCTUnwrap(map.spans.last?.end), 1, accuracy: 1e-9)
        XCTAssertEqual(map.spans.first?.filled, 1)
        XCTAssertEqual(map.spans.last?.filled, 0)
        XCTAssertEqual(map.activeCount, 1)
        // Every piece lands in exactly one cell.
        let done = map.spans.reduce(0.0) { $0 + $1.filled * 596 / 100 }
        XCTAssertEqual(done, 298, accuracy: 6)
    }

    func testFewPiecesGetACellEach() throws {
        let map = try XCTUnwrap(SegmentMap.pieces([[.done, .active, .pending]]))
        XCTAssertEqual(map.spans.map(\.filled), [1, 0, 0])
        XCTAssertEqual(map.spans.map(\.isActive), [false, true, false])
    }

    func testASecondTrackFollowsAfterAGap() throws {
        let video = [SegmentMap.PieceState](repeating: .done, count: 300)
        let audio = [SegmentMap.PieceState](repeating: .pending, count: 100)
        let map = try XCTUnwrap(SegmentMap.pieces([video, audio]))
        let videoCells = map.spans.filter { $0.filled == 1 }
        let audioCells = map.spans.filter { $0.filled == 0 }
        XCTAssertEqual(videoCells.count, 75)
        XCTAssertEqual(audioCells.count, 25)
        let lastVideo = try XCTUnwrap(videoCells.last), firstAudio = try XCTUnwrap(audioCells.first)
        XCTAssertEqual(firstAudio.start - lastVideo.end, SegmentMap.trackGap, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(map.spans.last?.end), 1, accuracy: 1e-9)
    }

    func testATinyTrackStillGetsACell() throws {
        let map = try XCTUnwrap(SegmentMap.pieces([
            [SegmentMap.PieceState](repeating: .pending, count: 900), [.done],
        ]))
        XCTAssertEqual(map.spans.last?.filled, 1)
    }

    func testOnePieceHasNoMap() {
        XCTAssertNil(SegmentMap.pieces([[.pending], []]))
        XCTAssertNil(SegmentMap.pieces([]))
    }
}
