import XCTest
@testable import DownloadEngine

/// The original categories, and how the stored list is read back.
///
/// The cases that matter: the defaults must not change identity between reads
/// (rows find their category by id), a person who deletes every category must
/// not have them quietly return, and unreadable stored text must never be
/// "repaired" by overwriting what the person had with the defaults.
final class CategoryDefaultsTests: XCTestCase {

    private let downloads = "/Users/test/Downloads"

    private var defaults: [DownloadCategory] {
        DownloadCategory.suggestedCategories(in: downloads)
    }

    // MARK: - The original set

    func testTheOriginalSevenAreAllThereInOrder() {
        XCTAssertEqual(
            defaults.map(\.name),
            ["Music", "Video", "Documents", "Books", "Archives", "Programs", "Images"]
        )
    }

    func testEachFilesIntoASubfolderOfTheGivenDownloadsFolder() {
        for category in defaults {
            XCTAssertTrue(category.hasUsableFolder, category.name)
            XCTAssertEqual(category.folderPath, downloads + "/" + category.name)
        }
    }

    func testTheIDsAreTheSameEveryTimeTheyAreBuilt() {
        // Random ids would orphan every row already filed under a default
        // category the next time the defaults were re-created.
        XCTAssertEqual(defaults.map(\.id), defaults.map(\.id))
        XCTAssertEqual(defaults, defaults)
        XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count, "ids must be distinct from each other")
    }

    func testNoOriginalCategoryClaimsTypeScript() {
        // "ts" is as likely to be source code as video.
        for category in defaults {
            XCTAssertFalse(category.extensions.contains("ts"), category.name)
        }
    }

    func testNoExtensionIsClaimedByTwoOriginalCategories() {
        XCTAssertTrue(CategoryRouter.duplicateExtensions(in: defaults).isEmpty)
    }

    // MARK: - Reading the stored list

    func testNothingStoredMeansTheOriginalCategories() {
        XCTAssertEqual(CategoryStorage.load(json: "", downloadsFolder: downloads), defaults)
    }

    func testAnEmptyListThePersonLeftStaysEmpty() throws {
        let stored = try XCTUnwrap(CategoryStorage.encode([]))
        XCTAssertFalse(stored.isEmpty, "an empty string would read back as \"never edited\"")
        XCTAssertEqual(CategoryStorage.load(json: stored, downloadsFolder: downloads), [])
    }

    func testUnreadableTextMeansNoCategoriesNotTheDefaults() {
        // Treating it as "never edited" would let the next save overwrite
        // whatever the person had with the defaults.
        XCTAssertEqual(CategoryStorage.load(json: "{not json", downloadsFolder: downloads), [])
    }

    func testASavedListComesBackExactly() throws {
        let custom = [
            DownloadCategory(name: "Work", folderPath: "/Users/test/Work", extensions: ["pdf"], sitePatterns: ["example.com"]),
            DownloadCategory(name: "Zips", folderPath: "/Users/test/Zips", extensions: ["zip"])
        ]
        let stored = try XCTUnwrap(CategoryStorage.encode(custom))
        XCTAssertEqual(CategoryStorage.load(json: stored, downloadsFolder: downloads), custom)
    }

    func testEditingADefaultKeepsItsIDSoFiledRowsStillFindIt() throws {
        var edited = defaults
        edited[0].extensions.append("wav")
        let stored = try XCTUnwrap(CategoryStorage.encode(edited))

        let reloaded = CategoryStorage.load(json: stored, downloadsFolder: downloads)

        XCTAssertEqual(reloaded[0].id, defaults[0].id)
        XCTAssertTrue(reloaded[0].extensions.contains("wav"))
        XCTAssertNotEqual(reloaded, defaults, "an edited list must read as different from the defaults")
    }

    func testAListSavedWhenCategoriesHadAnOnOffSwitchStillLoadsAndEveryCategoryRoutes() throws {
        // Earlier builds stored an "enabled" flag on each category and could
        // save one as false. The switch is gone, so there must be no way for
        // such a category to stay stuck off: it loads, and it routes.
        let legacy = """
        [{
          "id": "6F0C1B6E-1C2D-4C9A-9B1E-2D3F4A5B6C7D",
          "name": "Music",
          "folderPath": "/Users/test/Music",
          "extensions": ["mp3"],
          "sitePatterns": [],
          "enabled": false
        }]
        """

        let loaded = CategoryStorage.load(json: legacy, downloadsFolder: downloads)

        XCTAssertEqual(loaded.map(\.name), ["Music"])
        XCTAssertEqual(CategoryRouter.match(filename: "a.mp3", hosts: [], in: loaded)?.name, "Music")
        XCTAssertTrue(CategoryRouting.hasAnyRoutableCategory(loaded))
    }
}
