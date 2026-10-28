import XCTest
@testable import DownloadEngine

/// Which category a finished download is routed into.
///
/// The cases worth the most are the ones that put a file in the wrong place
/// without anyone noticing: a partial download counted as finished media,
/// "evilexample.com" counted as "example.com", and a half-filled-in category
/// quietly matching every file.
final class CategoryRouterTests: XCTestCase {

    private func category(
        _ name: String,
        extensions: [String] = [],
        sites: [String] = []
    ) -> DownloadCategory {
        DownloadCategory(
            name: name,
            folderPath: "/Users/test/\(name)",
            extensions: extensions,
            sitePatterns: sites
        )
    }

    private func name(_ filename: String, hosts: [String] = [], in categories: [DownloadCategory]) -> String? {
        CategoryRouter.match(filename: filename, hosts: hosts, in: categories)?.name
    }

    // MARK: - Extensions

    func testExtensionMatchIgnoresCase() {
        let music = category("Music", extensions: ["mp3"])
        XCTAssertEqual(name("Song.MP3", in: [music]), "Music")
        XCTAssertEqual(name("song.mp3", in: [music]), "Music")
    }

    func testTypedExtensionFormsAllMeanTheSameThing() {
        let music = category("Music", extensions: [" .MP3 ", "*.flac", "ogg"])
        XCTAssertEqual(name("a.mp3", in: [music]), "Music")
        XCTAssertEqual(name("a.flac", in: [music]), "Music")
        XCTAssertEqual(name("a.ogg", in: [music]), "Music")
    }

    func testExtensionIsASuffixNotASubstring() {
        let music = category("Music", extensions: ["mp3"])
        // A partial download or a renamed backup is not finished media.
        XCTAssertNil(name("song.mp3.part", in: [music]))
        XCTAssertNil(name("mp3player.exe", in: [music]))
        XCTAssertNil(name("song.mp3x", in: [music]))
    }

    func testAFileThatIsOnlyTheExtensionDoesNotMatch() {
        XCTAssertNil(name(".mp3", in: [category("Music", extensions: ["mp3"])]))
    }

    func testMultiPartExtension() {
        let archives = category("Archives", extensions: ["tar.gz"])
        XCTAssertEqual(name("backup.tar.gz", in: [archives]), "Archives")
        XCTAssertNil(name("backup.gz", in: [archives]))
    }

    func testMoreSpecificExtensionWinsOnlyByBeingListedFirst() {
        let tarGz = category("Source", extensions: ["tar.gz"])
        let gz = category("Compressed", extensions: ["gz"])
        XCTAssertEqual(name("x.tar.gz", in: [tarGz, gz]), "Source")
        XCTAssertEqual(name("x.tar.gz", in: [gz, tarGz]), "Compressed")
        XCTAssertEqual(name("x.gz", in: [tarGz, gz]), "Compressed")
    }

    // MARK: - Order, empty

    func testListOrderIsPriority() {
        let first = category("First", extensions: ["pdf"])
        let second = category("Second", extensions: ["pdf"])
        XCTAssertEqual(name("a.pdf", in: [first, second]), "First")
        XCTAssertEqual(name("a.pdf", in: [second, first]), "Second")
    }

    func testNoMatchReturnsNilSoTheCallerFallsBackToTheDefaultFolder() {
        XCTAssertNil(name("a.xyz", in: [category("Music", extensions: ["mp3"])]))
        XCTAssertNil(name("a.xyz", in: []))
    }

    func testCategoryWithNoCriteriaMatchesNothing() {
        XCTAssertNil(name("a.mp3", hosts: ["example.com"], in: [category("Blank")]))
    }

    func testCriteriaThatAreAllInvalidMatchNothingRatherThanEverything() {
        // Extensions of just "." are unusable. That must not turn the
        // category into "everything from example.com".
        let broken = category("Broken", extensions: [".", "  "], sites: ["example.com"])
        XCTAssertNil(name("a.mp3", hosts: ["example.com"], in: [broken]))

        let brokenSites = category("BrokenSites", extensions: ["mp3"], sites: ["  "])
        XCTAssertNil(name("a.mp3", hosts: ["example.com"], in: [brokenSites]))
    }

    // MARK: - Sites

    func testBareHostMatchesItselfAndSubdomains() {
        let work = category("Work", sites: ["example.com"])
        XCTAssertEqual(name("a.bin", hosts: ["example.com"], in: [work]), "Work")
        XCTAssertEqual(name("a.bin", hosts: ["cdn.example.com"], in: [work]), "Work")
    }

    func testBareHostDoesNotMatchALookalike() {
        let work = category("Work", sites: ["example.com"])
        XCTAssertNil(name("a.bin", hosts: ["evilexample.com"], in: [work]))
        XCTAssertNil(name("a.bin", hosts: ["example.com.evil.net"], in: [work]))
    }

    func testWildcardPattern() {
        let video = category("Video", sites: ["*.googlevideo.com"])
        XCTAssertEqual(name("a.bin", hosts: ["r1---sn-abc.googlevideo.com"], in: [video]), "Video")
        XCTAssertNil(name("a.bin", hosts: ["googlevideo.com"], in: [video]))
        XCTAssertNil(name("a.bin", hosts: ["googlevideo.com.evil.net"], in: [video]))
    }

    func testSitePatternIsCaseInsensitiveAndAcceptsAPastedURL() {
        let work = category("Work", sites: ["HTTPS://Example.com:8080/downloads"])
        XCTAssertEqual(name("a.bin", hosts: ["EXAMPLE.com"], in: [work]), "Work")
    }

    func testSiteOnlyCategoryTakesAnyFileFromThatSite() {
        let work = category("Work", sites: ["example.com"])
        XCTAssertEqual(name("whatever", hosts: ["example.com"], in: [work]), "Work")
    }

    func testExtensionAndSiteMustBothMatch() {
        let workPDFs = category("Work PDFs", extensions: ["pdf"], sites: ["example.com"])
        XCTAssertEqual(name("a.pdf", hosts: ["example.com"], in: [workPDFs]), "Work PDFs")
        XCTAssertNil(name("a.pdf", hosts: ["other.org"], in: [workPDFs]))
        XCTAssertNil(name("a.zip", hosts: ["example.com"], in: [workPDFs]))
    }

    func testSiteRestrictedCategoryNeverMatchesWhenNoHostIsKnown() {
        let work = category("Work", extensions: ["pdf"], sites: ["example.com"])
        XCTAssertNil(name("a.pdf", hosts: [], in: [work]))
    }

    func testEitherTheClickedHostOrTheResolvedHostCanSatisfyAPattern() {
        // GitHub-style: clicked github.com, served from a CDN.
        let github = category("GitHub", sites: ["github.com"])
        let cdn = category("CDN", sites: ["githubusercontent.com"])
        let hosts = ["github.com", "objects.githubusercontent.com"]
        XCTAssertEqual(name("a.dmg", hosts: hosts, in: [github]), "GitHub")
        XCTAssertEqual(name("a.dmg", hosts: hosts, in: [cdn]), "CDN")
    }

    // MARK: - Helpers and storage

    func testHostsFromURLsAreLowercasedUniqueAndSkipNil() {
        let hosts = CategoryRouter.hosts(from: [
            URL(string: "https://GitHub.com/a"),
            nil,
            URL(string: "https://github.com/b"),
            URL(string: "https://objects.githubusercontent.com/c")
        ])
        XCTAssertEqual(hosts, ["github.com", "objects.githubusercontent.com"])
    }

    func testGlobMatcherDoesNotGoExponential() {
        // The classic pathological case for a recursive matcher.
        let pattern = String(repeating: "a*", count: 30) + "b"
        let text = String(repeating: "a", count: 200)
        XCTAssertFalse(DownloadCategory.globMatch(pattern, text))
    }

    func testCodableRoundTripKeepsEverything() throws {
        let original = category("Books", extensions: ["epub", "mobi"], sites: ["example.com"])
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([DownloadCategory].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    func testFolderURLIsAnAbsoluteDirectoryPath() {
        let music = category("Music")
        XCTAssertEqual(music.folder.path, "/Users/test/Music")
        XCTAssertTrue(music.folder.hasDirectoryPath)
    }

    // MARK: - Phase 3: Suggested categories, duplicate warnings, and test field

    func testSuggestedCategoriesHaveExpectedOrderAndDisjointExtensions() {
        let suggested = DownloadCategory.suggestedCategories(in: "/Users/test/Downloads")
        XCTAssertEqual(
            suggested.map(\.name),
            ["Music", "Video", "Documents", "Books", "Archives", "Programs", "Images"]
        )
        XCTAssertTrue(suggested.allSatisfy(\.hasUsableFolder))
        XCTAssertEqual(suggested.first?.folder.path, "/Users/test/Downloads/Music")
        XCTAssertTrue(CategoryRouter.duplicateExtensions(in: suggested).isEmpty,
                      "seeded categories must not warn about overlapping extensions out of the box")
    }

    func testDuplicateExtensionsWarnsAcrossCategoriesInPriorityOrder() {
        let first = category("Music", extensions: [" .MP3 ", "flac", "mp3"])
        let second = category("Audio", extensions: ["mp3", "wav"])
        let third = category("Podcasts", extensions: ["MP3"])

        let duplicates = CategoryRouter.duplicateExtensions(in: [first, second, third])
        XCTAssertEqual(duplicates, [
            CategoryRouter.DuplicateExtension(
                ext: "mp3",
                categoryNames: ["Music", "Audio", "Podcasts"]
            )
        ])
    }

    func testParseExtensionsAndSitesNormaliseAndDeduplicate() {
        XCTAssertEqual(
            DownloadCategory.parseExtensions(" .MP3, *.tar.gz , mp3 \n flac "),
            ["mp3", "tar.gz", "flac"]
        )
        XCTAssertEqual(
            DownloadCategory.parseSitePatterns("HTTPS://Example.com:8080/dl, *.cdn.org , example.com"),
            ["example.com", "*.cdn.org"]
        )
    }
}
