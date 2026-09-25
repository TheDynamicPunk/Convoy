import XCTest
@testable import DownloadEngine

/// When the app offers to clear orphaned leftovers.
final class TemporaryStorageNoticeTests: XCTestCase {

    private let threshold = TemporaryStorageNotice.bytes(
        fromGB: TemporaryStorageNotice.defaultThresholdGB
    )

    func testNothingIsSaidBelowTheThreshold() {
        XCTAssertFalse(TemporaryStorageNotice.shouldShow(
            orphanedBytes: threshold - 1, thresholdBytes: threshold
        ))
    }

    func testTheThresholdItselfShows() {
        XCTAssertTrue(TemporaryStorageNotice.shouldShow(
            orphanedBytes: threshold, thresholdBytes: threshold
        ))
    }

    /// Clearing, or raising the bar, takes down a notice raised at launch.
    func testANoticeRaisedAtLaunchGoesOnceBelowTheThreshold() {
        XCTAssertTrue(TemporaryStorageNotice.stillShows(
            dueAtLaunch: true, orphanedBytes: threshold, thresholdBytes: threshold
        ))
        XCTAssertFalse(TemporaryStorageNotice.stillShows(
            dueAtLaunch: true, orphanedBytes: 0, thresholdBytes: threshold
        ))
    }

    /// Leftovers found mid-session, by Settings or a lowered threshold, wait
    /// for the next launch rather than interrupting this one.
    func testNothingFoundAfterLaunchRaisesTheNotice() {
        XCTAssertFalse(TemporaryStorageNotice.stillShows(
            dueAtLaunch: false, orphanedBytes: threshold * 4, thresholdBytes: threshold
        ))
    }

    /// A value written by the old slider still lands on a real stop.
    func testAStoredValueBetweenStopsSnapsToTheNearest() {
        XCTAssertEqual(TemporaryStorageNotice.nearestChoiceGB(to: 3.5), 4)
        XCTAssertEqual(TemporaryStorageNotice.nearestChoiceGB(to: 0.5), 1)
        XCTAssertEqual(TemporaryStorageNotice.nearestChoiceGB(to: 100), 8)
    }

    /// Every offered stop is one the picker can find again.
    func testEveryChoiceSnapsToItself() {
        for gb in TemporaryStorageNotice.thresholdChoicesGB {
            XCTAssertEqual(TemporaryStorageNotice.nearestChoiceGB(to: gb), gb)
        }
    }
}
