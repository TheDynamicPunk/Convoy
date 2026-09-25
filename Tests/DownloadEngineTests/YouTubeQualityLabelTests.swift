import XCTest
@testable import DownloadEngine

/// Quality labels use YouTube's own rung names, not the pixel height.
final class YouTubeQualityLabelTests: XCTestCase {

    private func videoLabels(_ formats: [[String: Any]]) throws -> [String] {
        let full = formats.map { f -> [String: Any] in
            f.merging([
                "protocol": "https", "ext": "mp4", "url": "https://example.invalid/v",
                "vcodec": "avc1.640028", "acodec": "none",
            ]) { own, _ in own }
        }
        return try YouTubeResolver.videoInfo(from: ["title": "t", "formats": full])
            .options.filter(\.hasVideo).map(\.label)
    }

    /// 9KOLMpUUo0w is 3840×2026; YouTube calls that 2160p.
    func testAWiderThan16By9VideoIsLabelledByItsRung() throws {
        let labels = try videoLabels([
            ["format_id": "401", "height": 2026, "format_note": "2160p"],
            ["format_id": "137", "height": 1012, "format_note": "1080p"],
        ])
        XCTAssertTrue(labels[0].hasPrefix("2160p "), labels[0])
        XCTAssertTrue(labels[1].hasPrefix("1080p "), labels[1])
    }

    /// Shown as YouTube words it, frame rate and HDR included.
    func testYouTubesLabelIsShownAsIs() throws {
        let labels = try videoLabels([["format_id": "699", "height": 1080, "fps": 60, "format_note": "1080p60 HDR"]])
        XCTAssertTrue(labels[0].hasPrefix("1080p60 HDR "), labels[0])
    }

    /// Same height and codec, different rung: both stay, since they no
    /// longer render the same.
    func testHDRAndSDRAtOneHeightAreBothOffered() throws {
        let labels = try videoLabels([
            ["format_id": "699", "height": 1080, "format_note": "1080p60 HDR", "filesize": 100],
            ["format_id": "399", "height": 1080, "format_note": "1080p60", "filesize": 100],
        ])
        XCTAssertEqual(labels.count, 2)
    }

    func testThePixelHeightAndFrameRateAreTheFallback() throws {
        let labels = try videoLabels([["format_id": "299", "height": 1080, "fps": 60]])
        XCTAssertTrue(labels[0].hasPrefix("1080p60 "), labels[0])
    }
}
