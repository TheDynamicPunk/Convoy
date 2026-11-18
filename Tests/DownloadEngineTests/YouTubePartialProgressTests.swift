import XCTest
@testable import DownloadEngine

/// What a restored YouTube row should show: the bytes yt-dlp actually has on
/// disk, not the count last saved before the app went away.
///
/// Each test builds the files yt-dlp leaves behind in folders of its own: the
/// destination's folder for a single-format pick, and a stand-in for the
/// system temp folder for a video + audio pick.
final class YouTubePartialProgressTests: XCTestCase {

    private var folder: URL!
    private var tempContainer: URL!
    private var destination: URL { folder.appendingPathComponent("Movie.mp4") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-progress-tests-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("destination", isDirectory: true)
        tempContainer = root.appendingPathComponent("temp", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempContainer, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        folder = nil
        tempContainer = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ bytes: Int, to url: URL, modified: Date? = nil) throws -> URL {
        try Data(count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// yt-dlp's in-progress file for a single-format pick.
    private func partFile(for taskID: UUID) -> URL {
        DestinationScratchFile.youTube.url(for: taskID, beside: destination).appendingPathExtension("part")
    }

    /// The directory a video + audio pick downloads into.
    private func mergeDirectory(for taskID: UUID) throws -> URL {
        let directory = TaskScratchDirectory.youTubeMerge.url(for: taskID, in: tempContainer)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func bytesOnDisk(_ taskID: UUID, _ selector: String) -> Int64 {
        YouTubePartialProgress.bytesOnDisk(
            taskID: taskID, formatSelector: selector,
            destination: destination, tempContainer: tempContainer
        )
    }

    // MARK: - One format

    func testASingleFormatCountsItsPartFileBesideTheDestination() throws {
        let id = UUID()
        try write(4_000, to: partFile(for: id))

        XCTAssertEqual(bytesOnDisk(id, "22"), 4_000)
    }

    func testASingleFormatIgnoresBookkeepingOtherDownloadsAndThePersonsFiles() throws {
        let id = UUID()
        try write(4_000, to: partFile(for: id))
        try write(900, to: partFile(for: id).deletingPathExtension().appendingPathExtension("ytdl"))
        try write(7_000, to: partFile(for: UUID()))
        try write(5_000, to: folder.appendingPathComponent("Movie.mp4.part"))

        XCTAssertEqual(bytesOnDisk(id, "22"), 4_000)
    }

    func testASingleFormatFinishedButNeverRenamedStillCounts() throws {
        let id = UUID()
        try write(9_000, to: DestinationScratchFile.youTube.url(for: id, beside: destination))

        XCTAssertEqual(bytesOnDisk(id, "22"), 9_000)
    }

    func testASingleFormatWithNothingOnDiskIsZero() {
        XCTAssertEqual(bytesOnDisk(UUID(), "22"), 0)
    }

    // MARK: - Video + audio

    func testTwoFilesAreAddedTogetherWhetherFinishedOrStillDownloading() throws {
        let id = UUID()
        let directory = try mergeDirectory(for: id)
        try write(1_000, to: directory.appendingPathComponent("137.mp4"))
        try write(250, to: directory.appendingPathComponent("140.m4a.part"))

        XCTAssertEqual(bytesOnDisk(id, "137,140"), 1_250)
    }

    func testTwoFilesIgnoreBookkeepingAndTracksThisPickDidNotAskFor() throws {
        let id = UUID()
        let directory = try mergeDirectory(for: id)
        try write(600, to: directory.appendingPathComponent("137.mp4.part"))
        try write(50, to: directory.appendingPathComponent("137.mp4.ytdl"))
        try write(300, to: directory.appendingPathComponent("251.webm"))
        try write(100, to: directory.appendingPathComponent("140.m4a"))

        XCTAssertEqual(bytesOnDisk(id, "137,140"), 700)
    }

    func testALanguageSelectorFindsTheAudioWhicheverNumberYtDlpGaveIt() throws {
        let id = UUID()
        let directory = try mergeDirectory(for: id)
        try write(500, to: directory.appendingPathComponent("137.mp4"))
        try write(70, to: directory.appendingPathComponent("140-3.m4a.part"))
        let selector = "137," + YouTubeResolver.audioSelector(formatID: "140", language: "en")

        XCTAssertEqual(bytesOnDisk(id, selector), 570)
    }

    func testANewerRenumberedRunReplacesAnOlderOneInsteadOfAddingToIt() throws {
        let id = UUID()
        let directory = try mergeDirectory(for: id)
        try write(500, to: directory.appendingPathComponent("137.mp4"))
        try write(900, to: directory.appendingPathComponent("140-0.m4a.part"), modified: Date(timeIntervalSince1970: 1_600_000_000))
        try write(60, to: directory.appendingPathComponent("140-1.m4a.part"), modified: Date())
        let selector = "137," + YouTubeResolver.audioSelector(formatID: "140", language: "en")

        XCTAssertEqual(bytesOnDisk(id, selector), 560)
    }

    func testTwoFilesWithNoDirectoryAreZero() {
        XCTAssertEqual(bytesOnDisk(UUID(), "137,140"), 0)
    }

    // MARK: - What a restored row opens with

    private func restored(saved: Int64, total: Int64, id: UUID, selector: String?) -> Int64 {
        YouTubePartialProgress.restoredBytes(
            saved: saved, total: total, taskID: id, formatSelector: selector,
            destination: destination, tempContainer: tempContainer
        )
    }

    func testARestoredYouTubeRowShowsWhatIsOnDiskNotTheStaleSavedCount() throws {
        let id = UUID()
        try write(4_000, to: partFile(for: id))

        XCTAssertEqual(restored(saved: 100, total: 10_000, id: id, selector: "22"), 4_000)
    }

    func testTheRestoredCountIsCappedAtTheTotal() throws {
        let id = UUID()
        try write(12_000, to: partFile(for: id))

        XCTAssertEqual(restored(saved: 100, total: 10_000, id: id, selector: "22"), 10_000)
    }

    func testAnUnknownTotalIsNotACap() throws {
        let id = UUID()
        try write(12_000, to: partFile(for: id))

        XCTAssertEqual(restored(saved: 100, total: 0, id: id, selector: "22"), 12_000)
    }

    /// If the partial files are gone (cleared from Settings → Storage, say),
    /// resuming starts over, so the row must not claim the old count.
    func testMissingFilesReadAsZeroNotTheSavedCount() {
        XCTAssertEqual(restored(saved: 3_000, total: 10_000, id: UUID(), selector: "22"), 0)
    }

    func testARowThatIsNotYouTubeKeepsItsSavedCount() throws {
        let id = UUID()
        try write(4_000, to: partFile(for: id))

        XCTAssertEqual(restored(saved: 3_000, total: 10_000, id: id, selector: nil), 3_000)
    }

    // MARK: - The resolver helpers it shares with the merge step

    func testASelectorNamesOneFileOrTwo() {
        XCTAssertEqual(YouTubeResolver.fileSelectors(in: "22"), ["22"])
        XCTAssertEqual(YouTubeResolver.fileSelectors(in: "137,140"), ["137", "140"])
    }

    func testAPartFileCountsAsTheFileItWillBecomeButBookkeepingDoesNot() {
        let part = URL(fileURLWithPath: "/tmp/140.m4a.part")
        let bookkeeping = URL(fileURLWithPath: "/tmp/140.m4a.ytdl")

        XCTAssertEqual(YouTubeResolver.newestFile(matching: "140", in: [part]), part)
        XCTAssertNil(YouTubeResolver.newestFile(matching: "140", in: [bookkeeping]))
        XCTAssertNil(YouTubeResolver.newestFile(matching: "137", in: [part]))
    }
}
