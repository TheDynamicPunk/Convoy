import XCTest
@testable import DownloadEngine

/// Tests for what the "reclaim disk space" control is allowed to see.
///
/// The scope is the safety property: only leftovers no download can claim are
/// reported, so the control cannot destroy resumable progress however it is
/// pressed. Most of these assert something is *absent* from the report, which
/// is the point — a paused download's bytes being invisible here is what makes
/// the button safe enough to need no confirmation.
final class TemporaryStorageTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("temp-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        container = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeScratchDirectory(
        _ kind: TaskScratchDirectory, for taskID: UUID, kilobytes: Int = 64
    ) throws -> URL {
        let url = kind.url(for: taskID, in: container)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 7, count: kilobytes * 1024)
            .write(to: url.appendingPathComponent("segment-0000.tmp"))
        return url
    }

    @discardableResult
    private func makeFile(_ name: String, kilobytes: Int = 16) throws -> URL {
        let url = container.appendingPathComponent(name)
        try Data(repeating: 7, count: kilobytes * 1024).write(to: url)
        return url
    }

    private func backdate(_ url: URL, byDays days: Double) throws {
        let date = Date().addingTimeInterval(-days * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date], ofItemAtPath: url.path
        )
    }

    private func reported(known: Set<UUID>) -> Set<URL> {
        Set(TemporaryStorage.report(knownTaskIDs: known, in: container).orphaned.map(\.url))
    }

    // MARK: - Anything a download still claims is invisible here

    /// One assertion per status, because "still in the list" is the whole
    /// rule: a running download owns bytes being written right now, a paused
    /// one owns bytes its resume continues from, and a finished one is simply
    /// not this control's business.
    func testFilesOfADownloadStillInTheListAreNeverReported() throws {
        let running = UUID(), paused = UUID(), finished = UUID()
        try makeScratchDirectory(.streamSegments, for: running)
        try makeScratchDirectory(.youTubeMerge, for: paused)
        try makeFile("\(paused.uuidString)-segment-3.tmp")
        try makeScratchDirectory(.streamSegments, for: finished)

        XCTAssertTrue(
            TemporaryStorage.report(knownTaskIDs: [running, paused, finished], in: container).isEmpty,
            "Nothing a live download owns may appear in a report the Clear button acts on."
        )
    }

    // MARK: - What nothing can ever use again

    func testFilesOfADownloadNoLongerInTheListAreReported() throws {
        let gone = UUID()
        let directory = try makeScratchDirectory(.youTubeMerge, for: gone)
        let segment = try makeFile("\(gone.uuidString)-segment-0.tmp")

        XCTAssertEqual(reported(known: [UUID()]), [directory, segment])
    }

    func testADirectoryWithAnUnreadableTaskIDIsReported() throws {
        let url = container.appendingPathComponent("mdl-yt-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        XCTAssertTrue(reported(known: []).contains(url), "Nothing can claim a directory whose owner cannot be identified.")
    }

    // MARK: - The temp folder belongs to the whole system

    func testUnrelatedFilesAreIgnoredEntirely() throws {
        try makeFile("someone-elses-file.tmp")
        try makeFile("report.pdf")

        XCTAssertTrue(TemporaryStorage.report(knownTaskIDs: [], in: container).isEmpty)
    }

    // MARK: - Sizes

    func testTotalCountsOnlyOrphansAndMeasuresRealBytes() throws {
        let live = UUID()
        try makeScratchDirectory(.youTubeMerge, for: live, kilobytes: 512)
        try makeScratchDirectory(.youTubeMerge, for: UUID(), kilobytes: 128)

        let report = TemporaryStorage.report(knownTaskIDs: [live], in: container)

        XCTAssertGreaterThan(report.totalBytes, 100_000)
        XCTAssertLessThan(report.totalBytes, 300_000, "The live download's 512KB must not be in the total.")
    }

    // MARK: - Removing

    func testRemovingLeavesEverythingElseWhereItIs() throws {
        let live = UUID()
        let kept = try makeScratchDirectory(.youTubeMerge, for: live)
        let doomed = try makeScratchDirectory(.youTubeMerge, for: UUID())
        let stranger = try makeFile("someone-elses-file.tmp")

        let report = TemporaryStorage.report(knownTaskIDs: [live], in: container)
        let freed = TemporaryStorage.remove(report.orphaned)

        XCTAssertEqual(freed, report.totalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: doomed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
        XCTAssertTrue(TemporaryStorage.report(knownTaskIDs: [live], in: container).isEmpty)
    }

    // MARK: - Age is not a signal

    /// The bug that started all of this: the old sweep expired anything
    /// untouched for 24 hours, so a download paused overnight lost its partial
    /// bytes the next time any other download began. Age is not a signal here
    /// at all now.
    func testALiveDownloadsFilesSurviveAtAnyAge() throws {
        let paused = UUID()
        let directory = try makeScratchDirectory(.youTubeMerge, for: paused)
        try backdate(directory, byDays: 365)

        let report = TemporaryStorage.report(knownTaskIDs: [paused], in: container)

        XCTAssertTrue(report.isEmpty, "A year-old directory a live download still owns is exactly what its resume continues from.")
    }

    /// The gap that folded these two implementations into one: the old sweep
    /// walked only the scratch-directory prefixes, so a loose segment file was
    /// collected by nothing.
    func testLooseSegmentFilesAreCollectedAndNotOnlyDirectories() throws {
        let gone = UUID()
        let directory = try makeScratchDirectory(.youTubeMerge, for: gone)
        let segment = try makeFile("\(gone.uuidString)-segment-7.tmp")

        let report = TemporaryStorage.report(knownTaskIDs: [], in: container)

        XCTAssertEqual(Set(report.orphaned.map(\.url)), [directory, segment])
    }

    // MARK: - Deleting a download's segment files

    func testRemovingSegmentFilesTakesEveryIndexOfThatTaskOnly() throws {
        let task = UUID(), other = UUID()
        let own = try (0..<8).map { try makeFile("\(task.uuidString)-segment-\($0).tmp") }
        let othersSegment = try makeFile("\(other.uuidString)-segment-1.tmp")
        let scratch = try makeScratchDirectory(.streamSegments, for: task)
        let unrelated = try makeFile("unrelated.tmp")

        TemporaryStorage.removeSegmentFiles(of: task, in: container)

        let fm = FileManager.default
        XCTAssertTrue(own.allSatisfy { !fm.fileExists(atPath: $0.path) })
        XCTAssertTrue(fm.fileExists(atPath: othersSegment.path))
        XCTAssertTrue(fm.fileExists(atPath: scratch.path), "Scratch directories go through TaskScratchDirectory, not this.")
        XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    }

    /// The bug: segments are not persisted, so a task restored after relaunch
    /// has none in memory, and deleting its row removed only `segment-0`.
    @MainActor
    func testDeletingARestoredTaskRemovesAllItsSegmentFiles() throws {
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.bin")!,
            destinationURL: container.appendingPathComponent("file.bin"),
            originalName: "file.bin",
            totalBytes: 8_000,
            downloadedBytes: 4_000
        )
        let tempDir = FileManager.default.temporaryDirectory
        let segments = try (0..<8).map { index -> URL in
            let url = tempDir.appendingPathComponent("\(task.id.uuidString)-segment-\(index).tmp")
            try Data(repeating: 7, count: 1024).write(to: url)
            return url
        }
        addTeardownBlock { segments.forEach { try? FileManager.default.removeItem(at: $0) } }

        task.cleanupTempFiles()

        XCTAssertEqual(segments.filter { FileManager.default.fileExists(atPath: $0.path) }, [])
    }
}
