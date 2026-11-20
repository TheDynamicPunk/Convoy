import XCTest
@testable import DownloadEngine

@MainActor
final class DownloadKindTests: XCTestCase {

    private func makeTask(
        url: String = "https://example.invalid/file.zip",
        name: String = "file.zip",
        totalBytes: Int64 = 1024
    ) -> DownloadTask {
        DownloadTask(
            url: URL(string: url)!,
            destinationURL: FileManager.default.temporaryDirectory.appendingPathComponent(name),
            originalName: name,
            totalBytes: totalBytes
        )
    }

    func testNewTaskDefaultsToDirectKindAndUsesSizeInIdentity() {
        let task = makeTask(totalBytes: 4096)

        XCTAssertEqual(task.kind, .direct)
        XCTAssertFalse(task.hasUnknownTotalSize)
        XCTAssertNil(task.ytFormatSelector)
        XCTAssertNil(task.streamURL)
        XCTAssertEqual(task.identity.size, 4096)
        XCTAssertNil(task.identity.youTubeFormatSelector)
    }

    func testYouTubeConfigurationSetsKindAndOmitsSizeFromIdentity() {
        let page = URL(string: "https://example.invalid/watch?v=sample")!
        let task = makeTask(url: page.absoluteString, name: "video.mp4", totalBytes: 50_000_000)
        task.configureYouTubeDownload(formatSelector: "137,140", pageURL: page)

        XCTAssertEqual(task.kind, .youTube(.init(formatSelector: "137,140", pageURL: page)))
        XCTAssertFalse(task.hasUnknownTotalSize)
        XCTAssertEqual(task.ytFormatSelector, "137,140")
        XCTAssertEqual(task.ytPageURL, page)
        XCTAssertNil(task.streamURL)
        XCTAssertEqual(task.identity.youTubeFormatSelector, "137,140")
        XCTAssertNil(task.identity.size)
    }

    func testStreamConfigurationSetsKindAndMarksUnknownTotalSize() {
        let manifest = URL(string: "https://cdn.example.invalid/master.m3u8")!
        let audio = [HLSAudioCandidate(url: URL(string: "https://cdn.example.invalid/en.m3u8")!, lang: "en", isDefault: true)]
        let task = makeTask(url: manifest.absoluteString, name: "clip", totalBytes: 1000)
        task.configureStreamDownload(
            streamURL: manifest,
            streamType: "hls",
            customHeaders: ["Referer": "https://site.example.invalid/"],
            representationId: "v1",
            bandwidth: 2_000_000,
            preferredAudioLanguage: "en",
            hlsAudioTracks: audio,
            completedSegments: 3,
            totalSegments: 10
        )

        XCTAssertEqual(task.kind, .stream(.init(
            url: manifest,
            type: "hls",
            representationId: "v1",
            bandwidth: 2_000_000,
            preferredAudioLanguage: "en",
            hlsAudioTracks: audio
        )))
        XCTAssertTrue(task.hasUnknownTotalSize)
        XCTAssertEqual(task.streamURL, manifest)
        XCTAssertEqual(task.streamType, "hls")
        XCTAssertEqual(task.streamRepresentationId, "v1")
        XCTAssertEqual(task.streamBandwidth, 2_000_000)
        XCTAssertEqual(task.streamPreferredAudioLanguage, "en")
        XCTAssertEqual(task.streamHLSAudioTracks, audio)
        XCTAssertEqual(task.progressBasis, .segments(completed: 3, total: 10))
        XCTAssertNil(task.identity.size)
        XCTAssertNil(task.identity.youTubeFormatSelector)
    }

    func testPersistedSnapshotDecodesFlatJSONFieldsIntoDownloadKind() throws {
        let destPath = FileManager.default.temporaryDirectory.appendingPathComponent("a.zip").path
        let directJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "url": "https://example.invalid/a.zip",
          "destinationPath": "\(destPath)",
          "originalName": "a.zip",
          "priorityRaw": 1,
          "segmentCount": 8,
          "kind": "active",
          "totalBytes": 100,
          "downloadedBytes": 50
        }
        """
        let direct = try JSONDecoder().decode(PersistedDownloadTask.self, from: Data(directJSON.utf8))
        XCTAssertEqual(direct.downloadKind, .direct)

        let ytJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "url": "https://example.invalid/watch?v=abc",
          "destinationPath": "\(destPath)",
          "originalName": "abc.mp4",
          "priorityRaw": 1,
          "segmentCount": 1,
          "kind": "active",
          "totalBytes": 0,
          "downloadedBytes": 0,
          "ytFormatSelector": "137,140",
          "ytPageURL": "https://example.invalid/watch?v=abc"
        }
        """
        let yt = try JSONDecoder().decode(PersistedDownloadTask.self, from: Data(ytJSON.utf8))
        XCTAssertEqual(yt.downloadKind, .youTube(.init(
            formatSelector: "137,140",
            pageURL: URL(string: "https://example.invalid/watch?v=abc")!
        )))

        let streamJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000003",
          "url": "https://cdn.example.invalid/index.mpd",
          "destinationPath": "\(destPath)",
          "originalName": "show.mp4",
          "priorityRaw": 1,
          "segmentCount": 8,
          "kind": "active",
          "totalBytes": 0,
          "downloadedBytes": 0,
          "streamURL": "https://cdn.example.invalid/index.mpd",
          "streamType": "dash",
          "streamRepresentationId": "rep-720",
          "streamBandwidth": 1500000,
          "streamPreferredAudioLanguage": "ja"
        }
        """
        let stream = try JSONDecoder().decode(PersistedDownloadTask.self, from: Data(streamJSON.utf8))
        XCTAssertEqual(stream.downloadKind, .stream(.init(
            url: URL(string: "https://cdn.example.invalid/index.mpd")!,
            type: "dash",
            representationId: "rep-720",
            bandwidth: 1_500_000,
            preferredAudioLanguage: "ja"
        )))
    }
}
