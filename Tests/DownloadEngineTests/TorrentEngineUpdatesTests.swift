import XCTest
@testable import DownloadEngine

/// The shared `updates(of:every:)` stream, which every engine gets.
final class TorrentEngineUpdatesTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-updates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    /// A snapshot is a state, not an event: only the latest matters. A
    /// consumer that falls behind (a window nobody is looking at, a busy main
    /// thread) must not make the stream hold every snapshot produced meanwhile,
    /// which for a torrent of thousands of files is real memory, and must not
    /// then be handed hours-old ones before the current one.
    func testAConsumerThatFallsBehindIsHandedTheLatestSnapshotNotTheOldestQueued() async throws {
        let engine = FakeTorrentEngine()
        let torrent = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashA))
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: scratch.appendingPathComponent("d"), files: nil)

        let counter = Counter()
        engine.simulate(torrent) { $0.downloadedBytes = Int64(counter.next()) }

        let stream = engine.updates(of: torrent, every: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(500)) // the consumer is busy elsewhere
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()

        // The stream was producing every 10 ms the whole time, so dozens were
        // made. Unbounded, the first one out is the very first (1).
        let delivered = try XCTUnwrap(first).downloadedBytes
        XCTAssertGreaterThan(delivered, 10, "got snapshot #\(delivered): the stream queued everything while nobody listened")
    }
}
