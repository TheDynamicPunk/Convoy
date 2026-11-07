import XCTest
@testable import DownloadEngine

/// How a capture taken during a re-link is judged against the expired
/// download: the same file resumes silently, anything else is put to the
/// person.
final class RelinkVerdictTests: XCTestCase {

    // MARK: - judge

    func testEqualSizesAreTheSameFile() {
        XCTAssertEqual(RelinkVerdict.judge(expected: 734_003_200, offered: 734_003_200), .sameFile)
    }

    func testDifferentSizesCarryBothNumbers() {
        XCTAssertEqual(
            RelinkVerdict.judge(expected: 1_000, offered: 640),
            .differentSize(expected: 1_000, offered: 640)
        )
    }

    func testAMissingOfferedSizeCannotBeVerified() {
        XCTAssertEqual(RelinkVerdict.judge(expected: 1_000, offered: nil), .cannotVerify)
    }

    func testAZeroOfferedSizeCannotBeVerified() {
        XCTAssertEqual(RelinkVerdict.judge(expected: 1_000, offered: 0), .cannotVerify)
    }

    func testADownloadThatNeverLearnedItsSizeCannotBeVerified() {
        // Equal-looking is not enough when one side is a placeholder: 0 must
        // never match 0.
        XCTAssertEqual(RelinkVerdict.judge(expected: 0, offered: 5_000), .cannotVerify)
        XCTAssertEqual(RelinkVerdict.judge(expected: 0, offered: nil), .cannotVerify)
    }

    // MARK: - CapturedDownload.offeredSize

    private func capture(matchHeaders: [String: String] = [:], expectedSize: Int64? = nil) -> CapturedDownload {
        CapturedDownload(
            url: URL(string: "https://cdn.test/file.bin")!,
            headers: [:],
            matchHeaders: matchHeaders,
            referrerURL: nil,
            suggestedFilename: nil,
            filenameSource: nil,
            expectedSize: expectedSize,
            segmentCount: nil,
            stream: nil
        )
    }

    func testOfferedSizeReadsContentLengthWhateverItsCase() {
        XCTAssertEqual(capture(matchHeaders: ["Content-Length": "2048"]).offeredSize, 2048)
        XCTAssertEqual(capture(matchHeaders: ["content-length": "2048"]).offeredSize, 2048)
    }

    func testOfferedSizeFallsBackToExpectedSize() {
        XCTAssertEqual(capture(expectedSize: 4096).offeredSize, 4096)
    }

    func testOfferedSizePrefersTheHeaderOverExpectedSize() {
        XCTAssertEqual(capture(matchHeaders: ["Content-Length": "100"], expectedSize: 999).offeredSize, 100)
    }

    func testOfferedSizeIsNilWhenNothingUsableWasSent() {
        XCTAssertNil(capture().offeredSize)
        XCTAssertNil(capture(matchHeaders: ["Content-Length": "abc"]).offeredSize)
        XCTAssertNil(capture(matchHeaders: ["Content-Length": "0"], expectedSize: 0).offeredSize)
    }

    func testAnUnusableHeaderStillLetsExpectedSizeThrough() {
        XCTAssertEqual(capture(matchHeaders: ["Content-Length": "abc"], expectedSize: 777).offeredSize, 777)
    }

    // MARK: - RelinkNameVerdict

    func testTheSameNameMatches() {
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["Episode 4.mp4"], offered: "Episode 4.mp4"), .same)
    }

    func testCaseAndSurroundingWhitespaceAreNotADifference() {
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["Episode 4.mp4"], offered: "  episode 4.MP4 "), .same)
    }

    func testADifferentNameIsDifferent() {
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["Episode 4.mp4"], offered: "Episode 5.mp4"), .different)
    }

    func testAMatchWithAnyKnownNameIsAMatch() {
        // The current file name can drift from the name the download was
        // created with (a "(1)" suffix, a Content-Disposition name).
        XCTAssertEqual(
            RelinkNameVerdict.judge(known: ["Episode 4 (1).mp4", "Episode 4.mp4"], offered: "Episode 4.mp4"),
            .same
        )
    }

    func testNoOfferedNameClaimsNothing() {
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["app.dmg"], offered: nil), .unknown)
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["app.dmg"], offered: ""), .unknown)
        XCTAssertEqual(RelinkNameVerdict.judge(known: ["app.dmg"], offered: "   "), .unknown)
    }
}
