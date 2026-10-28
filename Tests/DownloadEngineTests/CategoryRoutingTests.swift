import XCTest
@testable import DownloadEngine

/// The decision of whether a download is filed into a category, and getting
/// that category's folder ready.
///
/// What these protect: a folder somebody picked being moved by a rule, a
/// half-filled category filing downloads into the app's working directory,
/// editing categories moving a download already under way, and a missing
/// drive being "fixed" by quietly building a lookalike folder on the boot disk.
final class CategoryRoutingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("category-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A test may have made a folder read-only; removal needs it writable.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            for item in items {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: root.appendingPathComponent(item).path
                )
            }
        }
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    private func category(
        _ name: String,
        folder: String? = nil,
        extensions: [String] = [],
        sites: [String] = []
    ) -> DownloadCategory {
        DownloadCategory(
            name: name,
            folderPath: folder ?? "/Users/test/\(name)",
            extensions: extensions,
            sitePatterns: sites
        )
    }

    private func route(
        _ filename: String,
        matchName: String? = nil,
        hosts: [String] = [],
        in categories: [DownloadCategory],
        explicit: Bool = false,
        alreadyRouted: Bool = false
    ) -> CategoryRoute? {
        CategoryRouting.route(
            filename: filename, matchName: matchName, hosts: hosts, categories: categories,
            folderIsExplicit: explicit, alreadyRouted: alreadyRouted
        )
    }

    // MARK: - route(): when a download is left alone

    func testAFolderThePersonPickedIsNeverMoved() {
        XCTAssertNil(route("a.mp3", in: [category("Music", extensions: ["mp3"])], explicit: true))
    }

    func testADownloadAlreadyRoutedIsNeverRoutedAgain() {
        // Editing categories must not move a download that is under way, and
        // a restart after a changed remote file must land where it did.
        XCTAssertNil(route("a.mp3", in: [category("Music", extensions: ["mp3"])], alreadyRouted: true))
    }

    func testNoCategoriesAndNoMatchBothMeanNoRoute() {
        XCTAssertNil(route("a.mp3", in: []))
        XCTAssertNil(route("a.xyz", in: [category("Music", extensions: ["mp3"])]))
    }

    // MARK: - route(): where a match goes

    func testAMatchKeepsItsNameInsideTheCategoryFolder() throws {
        let result = try XCTUnwrap(route("Song.MP3", in: [category("Music", extensions: ["mp3"])]))
        XCTAssertEqual(result.category.name, "Music")
        XCTAssertEqual(result.destination.path, "/Users/test/Music/Song.MP3")
    }

    func testACategoryWithAnEmptyOrRelativeFolderIsSkippedNotObeyed() throws {
        // An empty path resolves to the working directory: the last place a
        // download should be filed.
        let empty = category("Empty", folder: "", extensions: ["mp3"])
        let relative = category("Relative", folder: "Music", extensions: ["mp3"])
        let real = category("Music", extensions: ["mp3"])

        XCTAssertNil(route("a.mp3", in: [empty, relative]))
        XCTAssertEqual(try XCTUnwrap(route("a.mp3", in: [empty, relative, real])).category.name, "Music")
    }

    func testALeadingTildeInTheFolderIsExpanded() throws {
        let result = try XCTUnwrap(route("a.mp3", in: [category("Music", folder: "~/Music", extensions: ["mp3"])]))
        XCTAssertEqual(result.destination.path, NSHomeDirectory() + "/Music/a.mp3")
    }

    func testAStreamIsMatchedAsMp4ButKeepsItsOwnName() throws {
        let video = category("Video", extensions: ["mp4"])
        // No extension in the name itself, so without the assumed one it
        // matches nothing.
        XCTAssertNil(route("My Talk", in: [video]))

        let result = try XCTUnwrap(route(
            "My Talk", matchName: CategoryRouting.streamMatchName(for: "My Talk"), in: [video]
        ))
        XCTAssertEqual(result.destination.lastPathComponent, "My Talk")
    }

    func testTheFallbackNoticeNamesTheCategoryTheReasonAndWhereItWentInstead() {
        let notice = CategoryRouting.fallbackNotice(
            category: category("Music"),
            reason: .volumeNotMounted,
            savedTo: URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        )
        XCTAssertTrue(notice.contains("Music"))
        XCTAssertTrue(notice.contains("drive isn't connected"))
        XCTAssertTrue(notice.contains("Downloads"))
    }

    // MARK: - CategoryFolder.prepare

    func testAnExistingWritableFolderIsReady() throws {
        let folder = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(CategoryFolder.prepare(folder), .ready)
    }

    func testAMissingFolderIsCreatedWithItsParents() {
        let folder = root.appendingPathComponent("Media/Audio/Music", isDirectory: true)
        XCTAssertEqual(CategoryFolder.prepare(folder), .created)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testAFileInTheWayIsNotAFolder() throws {
        let path = root.appendingPathComponent("Music")
        try Data("x".utf8).write(to: path)
        XCTAssertEqual(CategoryFolder.prepare(path), .unavailable(.notAFolder))
    }

    func testAFolderThatCannotBeWrittenToIsReportedNotUsed() throws {
        try XCTSkipIf(getuid() == 0, "root can write anywhere, so there is nothing to detect")
        let folder = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertEqual(CategoryFolder.prepare(folder), .unavailable(.notWritable))
    }

    func testAMissingVolumeIsReportedAndNothingIsBuiltInItsPlace() {
        let volume = "/Volumes/convoy-test-missing-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: volume + "/Music", isDirectory: true)

        XCTAssertEqual(CategoryFolder.prepare(folder), .unavailable(.volumeNotMounted))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume))
    }
}
