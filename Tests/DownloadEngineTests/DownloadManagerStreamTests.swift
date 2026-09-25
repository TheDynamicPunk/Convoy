import XCTest
@testable import DownloadEngine

@MainActor
final class DownloadManagerStreamTests: XCTestCase {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConvoyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // "Don't clobber an unmanaged file already at the destination" was tested
    // here against StreamDownloader.nonCollidingURL, which no longer exists.
    // DownloadDestinationTests covers it now, against the shared rule every
    // path uses.

    /// A .invalid URL never resolves (reserved by RFC 2606 for exactly this)
    /// so the manifest fetch fails fast via DNS rather than a real timeout,
    /// deterministically landing the task in .failed without needing a real
    /// network dependency to fail against.
    private func driveToFailure(_ task: DownloadTask, manager: DownloadManager) async throws {
        try? await manager.startDownload(task)
        guard case .failed = task.status else {
            XCTFail("expected task to reach .failed, got \(task.status)")
            return
        }
    }

    /// retryFailed used to always build a brand-new replacement task and
    /// delete the failed one — this regressed once retry started resuming
    /// in place (see DownloadManager.retryFailed's doc comment): a
    /// segment's temp file is keyed by its task's id, so a replacement
    /// couldn't find the old partial bytes and every retry silently
    /// restarted from byte 0. This test protects the current contract: the
    /// same task (same id) is what continues, never a replacement.
    func testRetryFailedResumesSameTaskInPlace() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let previousAutoStart = AppSettings.shared.autoStartDownloads
        AppSettings.shared.autoStartDownloads = false
        defer { AppSettings.shared.autoStartDownloads = previousAutoStart }

        let manager = DownloadManager.shared
        let source = URL(string: "https://example.invalid/manifest.mpd")!
        let destination = directory.appendingPathComponent("video.mp4")
        let original = try await manager.addStreamDownload(
            url: source,
            streamType: "dash",
            destination: destination,
            customHeaders: ["Referer": "https://example.invalid/watch"],
            representationId: "v1080",
            bandwidth: 4_000_000
        )

        try await driveToFailure(original, manager: manager)
        let originalID = original.id

        try await manager.retryFailed(original)

        // Same object, same id, still tracked — not removed and replaced.
        XCTAssertEqual(original.id, originalID)
        XCTAssertTrue(manager.tasks.contains { $0.id == originalID })
        XCTAssertEqual(manager.tasks.filter { $0.destinationURL == destination }.count, 1)
        XCTAssertEqual(original.streamURL, source)
        XCTAssertEqual(original.streamType, "dash")
        XCTAssertEqual(original.streamRepresentationId, "v1080")
        XCTAssertEqual(original.streamBandwidth, 4_000_000)

        await manager.cancelDownload(original)
    }

    /// fromScratch: true is for a download the user believes is genuinely
    /// corrupt/broken — it must actually discard prior progress rather than
    /// resume from it. Constructs a task with real prior progress directly
    /// (rather than driving an actual transfer) so this is deterministic and
    /// doesn't depend on how many bytes a .invalid host happens to deliver
    /// before failing (zero, always — nothing to discard).
    func testDiscardProgressForFreshRestartResetsPriorProgress() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let task = DownloadTask(
            url: URL(string: "https://example.invalid/manifest.mpd")!,
            destinationURL: directory.appendingPathComponent("video.mp4"),
            originalName: "video.mp4",
            totalBytes: 10_000,
            downloadedBytes: 4_000
        )
        task.configureStreamDownload(
            streamURL: URL(string: "https://example.invalid/manifest.mpd")!,
            streamType: "dash",
            customHeaders: [:],
            representationId: "v1080",
            bandwidth: 4_000_000
        )

        XCTAssertEqual(task.totalBytes, 10_000)
        XCTAssertEqual(task.downloadedBytes, 4_000)

        task.discardProgressForFreshRestart()

        XCTAssertEqual(task.totalBytes, 0)
        XCTAssertEqual(task.downloadedBytes, 0)
        // Identity/config the retry still needs to reconnect with is untouched.
        XCTAssertEqual(task.streamURL, URL(string: "https://example.invalid/manifest.mpd")!)
        XCTAssertEqual(task.streamType, "dash")
    }
}
