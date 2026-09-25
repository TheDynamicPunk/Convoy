import XCTest
@testable import DownloadEngine

/// Scratch files written beside a download's destination: every kind is
/// hidden and keyed by task, and deleting any download removes all of them
/// while leaving the person's own files alone.
final class DestinationScratchFileTests: XCTestCase {

    private var folder: URL!
    private var destination: URL { folder.appendingPathComponent("Movie.mp4") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("destination-scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func touch(_ url: URL) throws -> URL {
        try Data([7]).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Every file each kind can leave for `taskID`, including yt-dlp's
    /// `.part`/`.ytdl` beside its output.
    private func makeEveryKind(for taskID: UUID) throws -> [URL] {
        var urls = try DestinationScratchFile.allCases.map {
            try touch($0.url(for: taskID, beside: destination))
        }
        let ytOutput = DestinationScratchFile.youTube.url(for: taskID, beside: destination)
        urls.append(try touch(ytOutput.appendingPathExtension("part")))
        urls.append(try touch(ytOutput.appendingPathExtension("ytdl")))
        return urls
    }

    /// Files a person could plausibly have beside their download, including
    /// names the old name-based YouTube cleanup would have matched.
    private func makePersonsFiles() throws -> [URL] {
        try ["Movie.mp4", "Movie.final.mp4", "Movie.mp4.part", "Movie.mp4.tmp"].map {
            try touch(folder.appendingPathComponent($0))
        }
    }

    func testEveryKindIsHiddenBesideTheDestinationAndKeyedByTask() {
        let taskID = UUID()
        for kind in DestinationScratchFile.allCases {
            let url = kind.url(for: taskID, beside: destination)
            XCTAssertEqual(url.deletingLastPathComponent(), folder)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("."), "\(kind) must be hidden")
            XCTAssertTrue(url.lastPathComponent.contains(taskID.uuidString))
        }
        let prefixes = DestinationScratchFile.allCases.map(\.prefix)
        XCTAssertEqual(Set(prefixes).count, prefixes.count, "Two kinds sharing a prefix would be indistinguishable")
    }

    func testRemovingTakesEveryKindOfThisTaskOnly() throws {
        let taskID = UUID(), other = UUID()
        let own = try makeEveryKind(for: taskID)
        let others = try makeEveryKind(for: other)
        let persons = try makePersonsFiles()

        DestinationScratchFile.removeAll(for: taskID, in: folder)

        XCTAssertEqual(own.filter(exists), [])
        XCTAssertEqual(others.filter(exists), others)
        XCTAssertEqual(persons.filter(exists), persons)
    }

    /// The product rule: whatever kind of download it was, deleting it leaves
    /// nothing it wrote beside its destination.
    @MainActor
    func testDeletingAnyKindOfDownloadRemovesAllItsScratchFiles() throws {
        let page = URL(string: "https://example.invalid/watch")!
        let kinds: [(String, (DownloadTask) -> Void)] = [
            ("byte-range", { _ in }),
            ("YouTube", { $0.configureYouTubeDownload(formatSelector: "137,140", pageURL: page) }),
            ("stream", { $0.configureStreamDownload(
                streamURL: page, streamType: "dash", customHeaders: [:],
                representationId: nil, bandwidth: nil
            ) }),
        ]
        let persons = try makePersonsFiles()

        for (name, configure) in kinds {
            let task = DownloadTask(
                url: page, destinationURL: destination, originalName: "Movie.mp4",
                totalBytes: 1_000, downloadedBytes: 500
            )
            configure(task)
            let scratch = try makeEveryKind(for: task.id)

            task.cleanupTempFiles()

            XCTAssertEqual(scratch.filter(exists), [], "\(name) download left scratch files behind")
            XCTAssertEqual(persons.filter(exists), persons, "\(name) download removed a file it did not write")
        }
    }
}
