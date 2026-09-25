import XCTest
@testable import DownloadEngine

/// Tests for the one definition of "the same download".
///
/// The YouTube cases are the reason this type exists: `addYouTubeDownload`
/// ran no duplicate check at all, and MediaMuxer clears its output path before
/// exporting, so re-downloading a video you already had replaced the finished
/// file with no prompt. The non-YouTube cases are here to prove the rule they
/// always had is untouched — they pass against the pre-fix implementation, and
/// are meant to.
final class DownloadIdentityTests: XCTestCase {

    private let watchPage = URL(string: "https://www.youtube.com/watch?v=abc123")!
    private let otherPage = URL(string: "https://www.youtube.com/watch?v=zzz999")!
    private let fileURL = URL(string: "https://example.com/report.pdf")!
    private let otherFileURL = URL(string: "https://example.com/other.pdf")!

    private func youTube(_ url: URL, _ name: String, _ selector: String) -> DownloadIdentity {
        DownloadIdentity(url: url, name: name, youTubeFormatSelector: selector)
    }

    private func plain(_ url: URL, _ name: String) -> DownloadIdentity {
        DownloadIdentity(url: url, name: name)
    }

    // MARK: - YouTube: one URL, many legitimate files

    func testSameVideoAtSameQualityIsADuplicate() {
        XCTAssertTrue(
            youTube(watchPage, "Video (1080p).mp4", "137,140")
                .isSameDownload(as: youTube(watchPage, "Video (1080p).mp4", "137,140")),
            "Without this the finished file is replaced with no prompt."
        )
    }

    func testSameVideoAtADifferentQualityIsNotADuplicate() {
        XCTAssertFalse(
            youTube(watchPage, "Video (1080p).mp4", "137,140")
                .isSameDownload(as: youTube(watchPage, "Video (2160p).mp4", "313,140")),
            "The watch page is the URL for every quality, so URL equality alone would offer to resume a different file."
        )
    }

    func testDifferentVideoIsNotADuplicate() {
        XCTAssertFalse(
            youTube(watchPage, "Video (1080p).mp4", "137,140")
                .isSameDownload(as: youTube(otherPage, "Another (1080p).mp4", "137,140"))
        )
    }

    /// The name arm doing its job: a dubbed audio track is a different
    /// selector, so the URL arm lets it past — but it would land on the same
    /// path, which is a real collision.
    func testSameNameCollidesEvenWhenTheSelectorDiffers() {
        XCTAssertTrue(
            youTube(watchPage, "Video (1080p).mp4", "137,140")
                .isSameDownload(as: youTube(watchPage, "Video (1080p).mp4", "137,251"))
        )
    }

    func testAPlainRequestDoesNotMatchAYouTubeTaskAtTheSameURL() {
        XCTAssertFalse(
            youTube(watchPage, "Video (1080p).mp4", "137,140")
                .isSameDownload(as: plain(watchPage, "watch.html"))
        )
    }

    // MARK: - Everything else keeps exactly the rule it had

    func testPlainDownloadsMatchOnURL() {
        XCTAssertTrue(plain(fileURL, "report.pdf").isSameDownload(as: plain(fileURL, "renamed.pdf")))
    }

    func testPlainDownloadsMatchOnName() {
        XCTAssertTrue(plain(fileURL, "report.pdf").isSameDownload(as: plain(otherFileURL, "report.pdf")))
    }

    func testPlainDownloadsMatchOnNameRegardlessOfCase() {
        XCTAssertTrue(plain(fileURL, "Report.PDF").isSameDownload(as: plain(otherFileURL, "report.pdf")))
    }

    func testUnrelatedPlainDownloadsDoNotMatch() {
        XCTAssertFalse(plain(fileURL, "report.pdf").isSameDownload(as: plain(otherFileURL, "other.pdf")))
    }

    // MARK: - The rule cannot depend on which side is asking

    func testTheRuleIsSymmetric() {
        let pairs: [(DownloadIdentity, DownloadIdentity)] = [
            (youTube(watchPage, "Video (1080p).mp4", "137,140"),
             youTube(watchPage, "Video (2160p).mp4", "313,140")),
            (plain(fileURL, "report.pdf"), plain(otherFileURL, "report.pdf")),
            (plain(fileURL, "report.pdf"), plain(otherFileURL, "other.pdf")),
        ]
        for (a, b) in pairs {
            XCTAssertEqual(a.isSameDownload(as: b), b.isSameDownload(as: a))
        }
    }
}
