import XCTest
@testable import DownloadEngine

/// Choosing the audio language of a YouTube download, against trimmed
/// `--dump-json` output shaped like `0e3GPea1Tyg`'s.
final class YouTubeAudioLanguageTests: XCTestCase {

    private func format(
        _ id: String, ext: String = "m4a", video: Bool = false,
        language: String? = nil, preference: Int = -1, abr: Double = 0, bytes: Int64 = 1_000
    ) -> [String: Any] {
        var f: [String: Any] = [
            "format_id": id, "ext": ext, "protocol": "https",
            "url": "https://example.invalid/\(id)",
            "vcodec": video ? "avc1.640028" : "none",
            "acodec": video ? "none" : "mp4a.40.2",
            "abr": abr, "filesize": bytes, "language_preference": preference,
        ]
        if video { f["height"] = 1080 }
        if let language { f["language"] = language }
        return f
    }

    /// English original plus a Hindi dub; YouTube encodes the dub a hair
    /// higher, which is the trap `pickMergeAudio` has to avoid. French is
    /// offered only in WebM, which cannot be merged.
    private func dubbedVideo() throws -> YouTubeVideoInfo {
        try YouTubeResolver.videoInfo(from: ["title": "t", "formats": [
            format("137", ext: "mp4", video: true),
            format("140-23", language: "en-US", preference: 10, abr: 129.475, bytes: 2_000),
            format("139-23", language: "en-US", preference: 10, abr: 48.8),
            format("140-17", language: "hi", abr: 129.477, bytes: 2_001),
            format("139-17", language: "hi", abr: 48.8),
            format("251-4", ext: "webm", language: "fr", abr: 127.5),
        ]])
    }

    func testADubbedVideoOffersEachMergeableLanguageOriginalFirst() throws {
        let tracks = try dubbedVideo().audioTracks
        XCTAssertEqual(tracks.map(\.language), ["en-US", "hi"])
        XCTAssertEqual(tracks.map(\.isOriginal), [true, false])
    }

    /// One row per quality rather than one per quality per language.
    func testAudioOnlyRowsAreListedOnceNotPerLanguage() throws {
        let rows = try dubbedVideo().options.filter { !$0.hasVideo }
        XCTAssertEqual(rows.map(\.id), ["140-23", "139-23"])
        XCTAssertFalse(rows.contains { $0.label.contains("Hindi") || $0.label.contains("English") })
    }

    func testTheMergeTrackIsTheChosenLanguageAskedForByLanguage() throws {
        let hindi = try XCTUnwrap(dubbedVideo().mergeAudio(language: "hi"))
        XCTAssertEqual(hindi.formatID, "140-17")
        XCTAssertEqual(hindi.selector, "ba[format_id^=140-][language=hi]")
        XCTAssertEqual(hindi.filesizeBytes, 2_001)
    }

    /// The dub's higher bitrate must not win when the original is asked for.
    func testTheOriginalIsNotOutrankedByADubsBitrate() throws {
        XCTAssertEqual(try dubbedVideo().mergeAudio(language: "en-US")?.formatID, "140-23")
    }

    func testASingleLanguageVideoHasNoChoiceAndKeepsPlainIDs() throws {
        let info = try YouTubeResolver.videoInfo(from: ["title": "t", "formats": [
            format("137", ext: "mp4", video: true),
            format("140", language: "en", abr: 129.5),
            format("139", language: "en", abr: 48.8),
        ]])
        XCTAssertTrue(info.audioTracks.isEmpty)
        XCTAssertEqual(info.mergeAudio(language: nil)?.selector, "140")
    }

    // MARK: - Default

    func testTheSettingsPreferenceWinsWhenTheVideoHasIt() throws {
        let tracks = try dubbedVideo().audioTracks
        XCTAssertEqual(YouTubeResolver.defaultAudioLanguage(in: tracks, preferred: "hi"), "hi")
    }

    func testTheOriginalIsTheFallback() throws {
        let tracks = try dubbedVideo().audioTracks
        XCTAssertEqual(YouTubeResolver.defaultAudioLanguage(in: tracks, preferred: ""), "en-US")
        XCTAssertEqual(YouTubeResolver.defaultAudioLanguage(in: tracks, preferred: "de"), "en-US")
    }

    // MARK: - Selector and the file it produces

    func testALanguageSelectorMatchesWhicheverNumberYtDlpGaveTheFile() {
        let selector = YouTubeResolver.audioSelector(formatID: "140-23", language: "hi")
        XCTAssertTrue(YouTubeResolver.fileStem("140-17", satisfies: selector))
        XCTAssertFalse(YouTubeResolver.fileStem("139-17", satisfies: selector))
        XCTAssertTrue(YouTubeResolver.fileStem("140", satisfies: "140"))
        XCTAssertFalse(YouTubeResolver.fileStem("140-17", satisfies: "140"))
    }

    // MARK: - The shared language rule

    func testLanguageMatchingIsLooseOnRegionOnly() {
        XCTAssertTrue(AudioLanguage.matches("en-GB", preferred: "en"))
        XCTAssertTrue(AudioLanguage.matches("en", preferred: "en-GB"))
        XCTAssertTrue(AudioLanguage.matches("zh-Hans", preferred: "zh"))
        XCTAssertFalse(AudioLanguage.matches("eng", preferred: "en"))
        XCTAssertFalse(AudioLanguage.matches(nil, preferred: "en"))
        XCTAssertFalse(AudioLanguage.matches("en", preferred: ""))
    }
}
