import XCTest
@testable import DownloadEngine

/// Each open of the lock file is a separate `flock` holder, so two locks in
/// one process stand in for two running copies.
final class DownloadListLockTests: XCTestCase {

    private var folder: URL!
    private var listURL: URL { folder.appendingPathComponent("downloads.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-list-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    func testSecondHolderIsRefusedWhileTheFirstHoldsIt() {
        let first = DownloadListLock(beside: listURL)
        let second = DownloadListLock(beside: listURL)

        XCTAssertFalse(first.isHeldElsewhere)
        XCTAssertTrue(second.isHeldElsewhere)
    }

    func testReleasedWhenTheHolderGoesAway() {
        var first: DownloadListLock? = DownloadListLock(beside: listURL)
        XCTAssertEqual(first?.isHeldElsewhere, false)
        first = nil

        XCTAssertFalse(DownloadListLock(beside: listURL).isHeldElsewhere)
    }

    func testUnusableFolderDoesNotCountAsHeld() {
        let missing = folder.appendingPathComponent("missing/downloads.json")
        XCTAssertFalse(DownloadListLock(beside: missing).isHeldElsewhere)
    }
}
