import XCTest
@testable import DownloadEngine

/// What a download row measures itself against.
///
/// The bug these pin down: the stream path estimated a byte total by averaging
/// the segments seen so far and ratcheting it upward, so the denominator grew
/// while it was on screen — and since the audio track contributes no average
/// until the video track finishes, the bar hit 100% at the end of the video
/// and fell back to the low 90s.
///
/// The merge cap and the segment ETA read private state no test can reach;
/// those were verified against a standalone harness.
@MainActor
final class DownloadTaskProgressBasisTests: XCTestCase {

    private func makeTask(totalBytes: Int64 = 0, downloadedBytes: Int64 = 0) -> DownloadTask {
        DownloadTask(
            url: URL(string: "https://example.invalid/video")!,
            destinationURL: URL(fileURLWithPath: "/tmp/video.mp4"),
            originalName: "video.mp4",
            totalBytes: totalBytes,
            downloadedBytes: downloadedBytes
        )
    }

    private func makeStreamTask(completed: Int? = nil, total: Int? = nil) -> DownloadTask {
        let task = makeTask()
        task.configureStreamDownload(
            streamURL: URL(string: "https://example.invalid/master.m3u8")!,
            streamType: "hls",
            customHeaders: [:],
            representationId: nil,
            bandwidth: nil,
            completedSegments: completed,
            totalSegments: total
        )
        return task
    }

    // MARK: - Which basis a task uses

    func testPlainDownloadMeasuresItselfInBytes() {
        let task = makeTask(totalBytes: 1000, downloadedBytes: 250)
        XCTAssertFalse(task.hasUnknownTotalSize)
        XCTAssertNil(task.segmentProgress)
        XCTAssertEqual(task.progress, 0.25, accuracy: 0.0001)
    }

    func testStreamTaskIsMarkedAsHavingNoKnowableTotal() {
        XCTAssertTrue(makeStreamTask().hasUnknownTotalSize)
    }

    // MARK: - Segment arithmetic

    /// Keeps a restored paused row from drawing an empty bar over a
    /// mostly-finished download.
    func testRestoredSegmentCountsDriveTheProgressBar() {
        let task = makeStreamTask(completed: 88, total: 210)
        XCTAssertEqual(task.segmentProgress?.completed, 88)
        XCTAssertEqual(task.segmentProgress?.total, 210)
        XCTAssertEqual(task.progress, 88.0 / 210.0, accuracy: 0.0001)
    }

    /// Bytes must not enter the calculation: a stream's totalBytes stays zero
    /// until the download finishes.
    func testSegmentProgressIgnoresBytesEntirely() {
        let task = makeStreamTask(completed: 105, total: 210)
        XCTAssertEqual(task.totalBytes, 0, "a stream must not publish a byte total mid-download")
        XCTAssertEqual(task.progress, 0.5, accuracy: 0.0001)
    }

    func testSegmentProgressReachesExactlyFull() {
        XCTAssertEqual(makeStreamTask(completed: 210, total: 210).progress, 1.0)
    }

    // MARK: - Degenerate inputs

    /// A stream task that has never run has no counts to restore. Asking for
    /// its progress must yield zero, not a division by zero.
    func testStreamTaskWithoutCountsReportsNoProgress() {
        let task = makeStreamTask()
        XCTAssertNil(task.segmentProgress)
        XCTAssertEqual(task.progress, 0)
    }

    func testZeroTotalSegmentsIsRefusedRatherThanStored() {
        let task = makeStreamTask(completed: 0, total: 0)
        XCTAssertNil(task.segmentProgress)
        XCTAssertEqual(task.progress, 0)
    }

    func testPlainDownloadWithNoKnownSizeReportsNoProgress() {
        XCTAssertEqual(makeTask(totalBytes: 0, downloadedBytes: 500).progress, 0)
    }
}
