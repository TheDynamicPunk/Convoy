import XCTest
@testable import DownloadEngine

/// A list this build can't read is kept under a new name, so the empty list
/// this session would save can't replace it.
final class UnreadableDownloadListTests: XCTestCase {

    private var folder: URL!
    private var listURL: URL { folder.appendingPathComponent("downloads.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-list-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    private func writeList(_ contents: String = "not json") throws {
        try contents.write(to: listURL, atomically: true, encoding: .utf8)
    }

    func testKeepsTheContentsUnderANewNameBesideTheList() throws {
        try writeList("[{\"id\":\"from an older build\"}]")

        let kept = try UnreadableDownloadList.setAside(listURL)

        XCTAssertEqual(kept.deletingLastPathComponent(), folder)
        XCTAssertTrue(kept.lastPathComponent.hasPrefix("downloads-unreadable-"))
        XCTAssertEqual(kept.pathExtension, "json")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), "[{\"id\":\"from an older build\"}]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: listURL.path))
    }

    /// Two in the same second must not overwrite each other.
    func testASecondOneInTheSameSecondGetsItsOwnName() throws {
        let now = Date()
        try writeList("first")
        let first = try UnreadableDownloadList.setAside(listURL, now: now)
        try writeList("second")
        let second = try UnreadableDownloadList.setAside(listURL, now: now)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testThrowsWhenThereIsNoListToKeep() {
        XCTAssertThrowsError(try UnreadableDownloadList.setAside(listURL))
    }
}
