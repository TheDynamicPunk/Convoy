import SwiftUI
import XCTest
import DownloadEngine
@testable import Convoy

final class DownloadStatusStyleTests: XCTestCase {

    private let everyStatus: [DownloadStatus] = [
        .waiting, .starting, .validating, .refreshingLink, .downloading, .paused,
        .completed, .failed(nil), .cancelled, .urlExpired(referrerURL: nil),
        .destinationMissing, .awaitingDuplicateResolution,
    ]

    func testEveryStatusHasALabel() {
        for status in everyStatus {
            XCTAssertFalse(status.label.isEmpty, "\(status) has no label")
        }
    }

    func testLabelsAreTheOnesTheListAlwaysShowed() {
        XCTAssertEqual(DownloadStatus.validating.label, "Checking")
        XCTAssertEqual(DownloadStatus.refreshingLink.label, "Starting")
        XCTAssertEqual(DownloadStatus.destinationMissing.label, "Folder Missing")
        // The list said "Needs Your Input", the duplicate sheet "Needs Input";
        // one wording now serves both.
        XCTAssertEqual(DownloadStatus.awaitingDuplicateResolution.label, "Needs Your Input")
    }

    func testOnlyTheStatusesThatHaveABarShowOne() {
        let withBar: [DownloadStatus] = [
            .waiting, .starting, .validating, .refreshingLink, .downloading, .paused,
            .urlExpired(referrerURL: nil), .destinationMissing,
        ]
        for status in everyStatus {
            XCTAssertEqual(status.showsProgressBar, withBar.contains(status), "\(status)")
        }
    }

    func testTheEstablishedColoursAreUnchanged() {
        XCTAssertEqual(DownloadStatus.downloading.color, .blue)
        XCTAssertEqual(DownloadStatus.starting.color, .blue)
        XCTAssertEqual(DownloadStatus.refreshingLink.color, .blue)
        XCTAssertEqual(DownloadStatus.waiting.color, .orange)
        XCTAssertEqual(DownloadStatus.urlExpired(referrerURL: nil).color, .orange)
        XCTAssertEqual(DownloadStatus.paused.color, .yellow)
        XCTAssertEqual(DownloadStatus.completed.color, .green)
        XCTAssertEqual(DownloadStatus.failed(nil).color, .red)
        XCTAssertEqual(DownloadStatus.cancelled.color, .gray)
    }

    func testCheckingIsItsOwnLighterBlueNotDownloadingBlueOrWaitingOrange() {
        XCTAssertNotEqual(DownloadStatus.validating.color, DownloadStatus.downloading.color)
        XCTAssertNotEqual(DownloadStatus.validating.color, DownloadStatus.waiting.color)
    }
}
