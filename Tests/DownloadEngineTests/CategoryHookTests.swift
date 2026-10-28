import XCTest
@testable import DownloadEngine

/// `DownloadTask.applyCategoryIfNeeded`: what actually happens to a task when
/// routing runs, as opposed to the pure decision tested in
/// CategoryRoutingTests.
///
/// It is driven directly with a list of categories instead of through a real
/// download, so it needs no network and does not touch the person's settings.
@MainActor
final class CategoryHookTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-hook-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func makeTask(named name: String = "song.mp3", explicit: Bool = false) -> DownloadTask {
        DownloadTask(
            url: URL(string: "https://example.invalid/\(name)")!,
            destinationURL: root.appendingPathComponent("Downloads/\(name)"),
            originalName: name,
            folderIsExplicit: explicit
        )
    }

    private func category(
        _ name: String,
        folder: String? = nil,
        extensions: [String] = [],
        sites: [String] = []
    ) -> DownloadCategory {
        DownloadCategory(
            name: name,
            folderPath: folder ?? root.appendingPathComponent(name).path,
            extensions: extensions,
            sitePatterns: sites
        )
    }

    private func samePath(_ a: URL, _ b: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            a.resolvingSymlinksInPath().path, b.resolvingSymlinksInPath().path,
            file: file, line: line
        )
    }

    // MARK: - Filing

    func testAMatchingDownloadIsFiledIntoTheCategoryFolder() async {
        let music = category("Music", extensions: ["mp3"])
        let task = makeTask()

        await task.applyCategoryIfNeeded(categories: [music], hosts: [])

        samePath(task.destinationURL, root.appendingPathComponent("Music/song.mp3"))
        XCTAssertEqual(task.categoryID, music.id)
        XCTAssertNil(task.categoryNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: music.folder.path),
                      "the category folder is created when it does not exist yet")
    }

    func testNothingMatchingLeavesTheDownloadWhereItIs() async {
        let task = makeTask(named: "notes.txt")
        let before = task.destinationURL

        await task.applyCategoryIfNeeded(categories: [category("Music", extensions: ["mp3"])], hosts: [])

        XCTAssertEqual(task.destinationURL, before)
        XCTAssertNil(task.categoryID)
        XCTAssertNil(task.categoryNotice)
    }

    func testEitherTheClickedOrTheResolvedAddressCanSatisfyASiteRule() async {
        let cdn = category("CDN", sites: ["cdn.example.com"])
        let task = makeTask(named: "setup.bin")

        await task.applyCategoryIfNeeded(categories: [cdn], hosts: ["example.invalid", "cdn.example.com"])

        XCTAssertEqual(task.categoryID, cdn.id)
    }

    // MARK: - Left alone on purpose

    func testAFolderThePersonPickedIsNotMoved() async {
        let task = makeTask(explicit: true)
        let before = task.destinationURL

        await task.applyCategoryIfNeeded(categories: [category("Music", extensions: ["mp3"])], hosts: [])

        XCTAssertEqual(task.destinationURL, before)
        XCTAssertNil(task.categoryID)
    }

    func testRoutingHappensOnceEvenIfTheCategoriesChangeAfterwards() async {
        let first = category("Music", extensions: ["mp3"])
        let second = category("Elsewhere", extensions: ["mp3"])
        let task = makeTask()

        await task.applyCategoryIfNeeded(categories: [first], hosts: [])
        let routed = task.destinationURL
        // The person edits their categories while the download is running,
        // and the same task runs the hook again (a restart after the remote
        // file changed, for instance).
        await task.applyCategoryIfNeeded(categories: [second], hosts: [])

        XCTAssertEqual(task.destinationURL, routed)
        XCTAssertEqual(task.categoryID, first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.folder.path),
                       "the second category's folder must not even be created")
    }

    // MARK: - Things that go wrong

    func testAnUnavailableFolderKeepsTheDownloadWhereItIsAndSaysWhy() async {
        let gone = category(
            "Music",
            folder: "/Volumes/convoy-test-missing-\(UUID().uuidString)/Music",
            extensions: ["mp3"]
        )
        let task = makeTask()
        let before = task.destinationURL

        await task.applyCategoryIfNeeded(categories: [gone], hosts: [])

        XCTAssertEqual(task.destinationURL, before, "the download must not fail or vanish over a missing drive")
        XCTAssertNil(task.categoryID)
        let notice = task.categoryNotice ?? ""
        XCTAssertTrue(notice.contains("Music"), notice)
        XCTAssertTrue(notice.contains("Downloads"), notice)
    }

    func testAFileAlreadyInTheCategoryFolderIsNotOverwritten() async throws {
        let music = category("Music", extensions: ["mp3"])
        try FileManager.default.createDirectory(at: music.folder, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: music.folder.appendingPathComponent("song.mp3"))
        let task = makeTask()

        await task.applyCategoryIfNeeded(categories: [music], hosts: [])

        XCTAssertEqual(task.destinationURL.lastPathComponent, "song (1).mp3")
        XCTAssertEqual(task.categoryID, music.id)
    }
}
