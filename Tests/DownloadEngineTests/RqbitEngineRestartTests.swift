import XCTest
@testable import DownloadEngine

/// What happens to torrents when the real helper dies. Skipped unless
/// `CONVOY_RQBIT_BINARY` is set (see `RqbitEngineContractTests`).
final class RqbitEngineRestartTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rqbit-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let scratch = self.scratch!
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeEngine() throws -> RqbitEngine {
        guard let path = ProcessInfo.processInfo.environment["CONVOY_RQBIT_BINARY"], !path.isEmpty else {
            throw XCTSkip("set CONVOY_RQBIT_BINARY to run against the real helper")
        }
        let engine = RqbitEngine(
            options: RqbitEngine.Options(
                executable: URL(fileURLWithPath: path),
                sessionDirectory: scratch.appendingPathComponent("session"),
                defaultOutputFolder: scratch.appendingPathComponent("incoming"),
                extraArguments: ["--disable-dht", "--disable-trackers"]
            ),
            supervisor: ProcessSupervisor(runDirectory: scratch.appendingPathComponent("run"))
        )
        addTeardownBlock { await engine.stop() }
        return engine
    }

    /// Kills every process whose command line mentions this test's session
    /// folder, which is the helper and its guard: what a crash leaves.
    private func crashTheHelper() throws {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-f", scratch.appendingPathComponent("session").path]
        try pkill.run()
        pkill.waitUntilExit()
        XCTAssertEqual(pkill.terminationStatus, 0, "pkill found nothing to kill: the helper was not running")
    }

    func testAHelperThatDiesIsReplacedAndStillKnowsItsTorrents() async throws {
        let engine = try makeEngine()
        let torrent = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashA))
        let target = scratch.appendingPathComponent("download")
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)
        // As a person would see it: the torrent is up and showing before the crash.
        for _ in 0..<100 {
            if try await engine.snapshot(of: torrent).state != .initializing { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        try crashTheHelper()

        // RqbitEngine automatically retires the dead helper, starts a
        // replacement, and retries once, so a single call proves recovery.
        let details = try await engine.details(of: torrent)
        XCTAssertEqual(details.name, "abc")
        XCTAssertEqual(details.outputFolder.resolvingSymlinksInPath().path, target.resolvingSymlinksInPath().path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("abc").path))
    }

    /// A torrent that was paused when the helper died must come back paused,
    /// not quietly start running.
    func testAPausedTorrentStaysPausedAcrossARestart() async throws {
        let engine = try makeEngine()
        let torrent = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashA))
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: scratch.appendingPathComponent("download"), files: nil)
        for _ in 0..<100 {
            if try await engine.snapshot(of: torrent).state != .initializing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await engine.pause(torrent)

        try crashTheHelper()

        let state = try await engine.snapshot(of: torrent).state
        XCTAssertEqual(state, .paused)
    }
}
