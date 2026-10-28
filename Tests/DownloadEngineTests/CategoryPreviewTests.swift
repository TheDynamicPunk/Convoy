import XCTest
@testable import DownloadEngine

/// The "Try It" field in Settings. It must answer exactly as real routing
/// would, because a field that promises a folder real downloads do not use is
/// worse than no field.
final class CategoryPreviewTests: XCTestCase {

    private let music = DownloadCategory(
        name: "Music", folderPath: "/Users/test/Music", extensions: ["mp3"]
    )
    private let work = DownloadCategory(
        name: "Work", folderPath: "/Users/test/Work", sitePatterns: ["example.com"]
    )

    private func name(_ input: String, in categories: [DownloadCategory]) -> String? {
        CategoryPreview.route(for: input, in: categories)?.category.name
    }

    // MARK: - What can be typed

    func testABareFilenameMatchesByExtension() {
        XCTAssertEqual(name("song.mp3", in: [music, work]), "Music")
    }

    func testAFullLinkUsesBothItsNameAndItsSite() {
        XCTAssertEqual(name("https://cdn.example.com/files/a.zip", in: [music, work]), "Work")
        XCTAssertEqual(name("https://other.org/x/song.mp3", in: [work, music]), "Music")
    }

    func testALinkWithoutTheSchemeStillWorks() {
        XCTAssertEqual(name("example.com/dl/a.pdf", in: [work]), "Work")
    }

    func testABareSiteNameMatchesASiteOnlyCategory() {
        XCTAssertEqual(name("example.com", in: [work]), "Work")
    }

    func testAPercentEncodedNameIsReadAsTheFileItIs() {
        XCTAssertEqual(name("https://other.org/My%20Song.mp3", in: [music]), "Music")
    }

    func testAFilenameIsNotMistakenForASite() {
        // "song.mp3" has a dot, like a hostname does, but it is not one.
        XCTAssertNil(name("song.mp3", in: [work]))
    }

    func testReportsWhereTheFileWouldLand() throws {
        let route = try XCTUnwrap(CategoryPreview.route(for: "song.mp3", in: [music]))
        XCTAssertEqual(route.category.folder.path, "/Users/test/Music")
        XCTAssertEqual(route.destination.path, "/Users/test/Music/song.mp3")
    }

    // MARK: - Nothing to say

    func testAnEmptyOrBlankFieldSaysNothing() {
        XCTAssertNil(name("", in: [music]))
        XCTAssertNil(name("   \n ", in: [music]))
    }

    func testNoMatchSaysNothingMatches() {
        XCTAssertNil(name("a.xyz", in: [music, work]))
        XCTAssertNil(name("a.mp3", in: []))
    }

    // MARK: - Same rules as real downloads

    func testACategoryWithAnUnusableFolderTakesNothingHereEitherWay() {
        let broken = DownloadCategory(name: "Broken", folderPath: "", extensions: ["mp3"])
        XCTAssertNil(name("a.mp3", in: [broken]))
        XCTAssertEqual(name("a.mp3", in: [broken, music]), "Music")
    }
}
