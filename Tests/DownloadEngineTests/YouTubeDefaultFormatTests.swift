import XCTest
@testable import DownloadEngine

/// The default pick in the quality picker: tallest video, never the first
/// option (which the combined-first sort made itag 18, at 360p).
final class YouTubeDefaultFormatTests: XCTestCase {

    private func option(
        _ id: String,
        height: Int?,
        hasVideo: Bool,
        hasAudio: Bool
    ) -> YouTubeFormatOption {
        YouTubeFormatOption(
            id: id,
            label: id,
            url: URL(string: "https://example.invalid/\(id)")!,
            headers: [:],
            ext: "mp4",
            filesizeBytes: nil,
            height: height,
            hasVideo: hasVideo,
            hasAudio: hasAudio,
            audioMergeAvailable: hasVideo && !hasAudio
        )
    }

    /// The regression: 360p combined sorts above 4K video-only.
    func testACombinedFormatDoesNotWinJustBySortingFirst() {
        let options = [
            option("18", height: 360, hasVideo: true, hasAudio: true),
            option("401", height: 2160, hasVideo: true, hasAudio: false),
            option("137", height: 1080, hasVideo: true, hasAudio: false),
            option("140", height: nil, hasVideo: false, hasAudio: true),
        ]
        XCTAssertEqual(YouTubeResolver.defaultFormatID(from: options), "401")
    }

    /// Pinned client means no combined format; same answer.
    func testTheTallestVideoWinsWithNoCombinedFormatPresent() {
        let options = [
            option("401", height: 2160, hasVideo: true, hasAudio: false),
            option("137", height: 1080, hasVideo: true, hasAudio: false),
            option("140", height: nil, hasVideo: false, hasAudio: true),
        ]
        XCTAssertEqual(YouTubeResolver.defaultFormatID(from: options), "401")
    }

    /// Equal heights defer to the resolver's existing order.
    func testEqualHeightsKeepTheResolversOwnOrder() {
        let options = [
            option("137", height: 1080, hasVideo: true, hasAudio: false),
            option("248", height: 1080, hasVideo: true, hasAudio: false),
        ]
        XCTAssertEqual(YouTubeResolver.defaultFormatID(from: options), "137")
    }

    /// No video to prefer, but still needs a pick.
    func testAudioOnlyListsFallBackToTheFirstOption() {
        let options = [
            option("140", height: nil, hasVideo: false, hasAudio: true),
            option("251", height: nil, hasVideo: false, hasAudio: true),
        ]
        XCTAssertEqual(YouTubeResolver.defaultFormatID(from: options), "140")
    }

    /// Missing heights must not fall through to the audio row.
    func testFormatsWithoutHeightsStillPreferVideo() {
        let options = [
            option("140", height: nil, hasVideo: false, hasAudio: true),
            option("999", height: nil, hasVideo: true, hasAudio: false),
        ]
        XCTAssertEqual(YouTubeResolver.defaultFormatID(from: options), "999")
    }

    func testAnEmptyListHasNoDefault() {
        XCTAssertNil(YouTubeResolver.defaultFormatID(from: []))
    }
}
