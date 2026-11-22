import XCTest
@testable import DownloadEngine

/// The parts of the rqbit adapter that do not need rqbit: how it is launched,
/// and what happens when what is launched is missing, dies at once or never
/// answers. Behaviour against the real helper is in
/// `RqbitEngineContractTests`, which runs when `CONVOY_RQBIT_BINARY` is set.
final class RqbitEngineTests: XCTestCase {

    private var scratch: URL!
    private var supervisor: ProcessSupervisor!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rqbit-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        supervisor = ProcessSupervisor(runDirectory: scratch.appendingPathComponent("run"))
    }

    override func tearDownWithError() throws {
        supervisor.stopAll(timeout: 3)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func options(executable: URL, startTimeout: TimeInterval = 5) -> RqbitEngine.Options {
        RqbitEngine.Options(
            executable: executable,
            sessionDirectory: scratch.appendingPathComponent("session"),
            defaultOutputFolder: scratch.appendingPathComponent("incoming"),
            startTimeout: startTimeout
        )
    }

    private func script(_ body: String) throws -> URL {
        let url = scratch.appendingPathComponent("fake-rqbit-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Launch arguments

    func testTheHelperIsLaunchedOnLoopbackWithItsStateInOurFolder() {
        let arguments = RqbitEngine.launchArguments(
            apiPort: 41001, peerPort: 41002,
            sessionDirectory: URL(fileURLWithPath: "/tmp/convoy/session"),
            defaultOutputFolder: URL(fileURLWithPath: "/tmp/convoy/incoming"),
            uploadLimit: nil, downloadLimit: nil, extra: [])

        XCTAssertEqual(arguments.firstIndex(of: "--http-api-listen-addr").map { arguments[$0 + 1] }, "127.0.0.1:41001")
        XCTAssertEqual(arguments.firstIndex(of: "--listen-port").map { arguments[$0 + 1] }, "41002")
        // The side effects found in Phase 0 that Convoy does not want.
        for flag in ["--disable-dht-persistence", "--disable-upnp-port-forward", "--disable-lsd"] {
            XCTAssertTrue(arguments.contains(flag), "missing \(flag)")
        }
        XCTAssertFalse(arguments.contains("--disable-dht"), "DHT is how magnet links find peers")
        XCTAssertEqual(Array(arguments.suffix(5)),
                       ["server", "start", "--persistence-location", "/tmp/convoy/session", "/tmp/convoy/incoming"])
    }

    func testRateLimitsAreLaunchFlagsAndOnlyWhenSet() {
        func arguments(up: Int?, down: Int?) -> [String] {
            RqbitEngine.launchArguments(
                apiPort: 1, peerPort: 2, sessionDirectory: URL(fileURLWithPath: "/s"),
                defaultOutputFolder: URL(fileURLWithPath: "/o"), uploadLimit: up, downloadLimit: down, extra: [])
        }
        XCTAssertFalse(arguments(up: nil, down: nil).contains("--ratelimit-upload"))
        XCTAssertFalse(arguments(up: nil, down: nil).contains("--ratelimit-download"))

        let limited = arguments(up: 50_000, down: 900_000)
        XCTAssertEqual(limited.firstIndex(of: "--ratelimit-upload").map { limited[$0 + 1] }, "50000")
        XCTAssertEqual(limited.firstIndex(of: "--ratelimit-download").map { limited[$0 + 1] }, "900000")
    }

    /// Options are global flags, so they belong before the subcommand.
    func testExtraArgumentsComeBeforeTheSubcommand() {
        let arguments = RqbitEngine.launchArguments(
            apiPort: 1, peerPort: 2, sessionDirectory: URL(fileURLWithPath: "/s"),
            defaultOutputFolder: URL(fileURLWithPath: "/o"), uploadLimit: nil, downloadLimit: nil,
            extra: ["--disable-dht"])

        let extra = arguments.firstIndex(of: "--disable-dht")
        let subcommand = arguments.firstIndex(of: "server")
        XCTAssertNotNil(extra)
        XCTAssertTrue(extra! < subcommand!)
    }

    func testNetworkTogglesOmitDisableFlagsWhenEnabled() {
        let arguments = RqbitEngine.launchArguments(
            apiPort: 41001, peerPort: 51413,
            sessionDirectory: URL(fileURLWithPath: "/s"),
            defaultOutputFolder: URL(fileURLWithPath: "/o"),
            uploadLimit: 256 * 1024, downloadLimit: nil,
            enableUPnP: true, enableLSD: true, persistDHT: true,
            extra: []
        )

        XCTAssertEqual(arguments.firstIndex(of: "--listen-port").map { arguments[$0 + 1] }, "51413")
        XCTAssertEqual(arguments.firstIndex(of: "--ratelimit-upload").map { arguments[$0 + 1] }, "\(256 * 1024)")
        XCTAssertFalse(arguments.contains("--disable-upnp-port-forward"))
        XCTAssertFalse(arguments.contains("--disable-lsd"))
        XCTAssertFalse(arguments.contains("--disable-dht-persistence"))
    }

    // MARK: - Launch failures

    func testAMissingExecutableIsReportedAsNotInstalled() async {
        let missing = scratch.appendingPathComponent("no-such-rqbit")
        let engine = RqbitEngine(options: options(executable: missing), supervisor: supervisor)

        do {
            _ = try await engine.snapshot(of: TorrentInfoHash(hex: TorrentFixtures.hashA)!)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .helperMissing(path: missing.path))
        }
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    func testAHelperThatDiesAtOnceIsReportedWithWhatItPrinted() async throws {
        let dying = try script("echo 'boom: something is wrong' >&2\nexit 3")
        let engine = RqbitEngine(options: options(executable: dying), supervisor: supervisor)

        do {
            _ = try await engine.snapshot(of: TorrentInfoHash(hex: TorrentFixtures.hashA)!)
            XCTFail("expected an error")
        } catch TorrentEngineError.helperFailedToStart(let detail) {
            XCTAssertTrue(detail.contains("boom: something is wrong"), "detail was: \(detail)")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    func testAHelperThatNeverAnswersIsStoppedAndReported() async throws {
        let silent = try script("exec sleep 60")
        let engine = RqbitEngine(options: options(executable: silent, startTimeout: 0.6), supervisor: supervisor)

        do {
            _ = try await engine.snapshot(of: TorrentInfoHash(hex: TorrentFixtures.hashA)!)
            XCTFail("expected an error")
        } catch TorrentEngineError.helperFailedToStart(let detail) {
            XCTAssertTrue(detail.contains("did not answer"), "detail was: \(detail)")
        } catch {
            XCTFail("unexpected \(error)")
        }

        // Stopping is asynchronous; give the guard a moment to finish.
        for _ in 0..<50 where supervisor.activeCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(supervisor.activeCount, 0, "a helper that never came up must not be left running")
    }
}
