import XCTest
@testable import DownloadEngine

/// The contract suite, run against a real rqbit.
///
/// Skipped unless `CONVOY_RQBIT_BINARY` names an rqbit executable, so the
/// ordinary test run needs no helper and no network. Run it with:
///
///     CONVOY_RQBIT_BINARY=/path/to/rqbit swift test --filter RqbitEngineContractTests
///
/// The helper is started with DHT and trackers off, so nothing leaves the
/// machine: the fixture torrents have no peers to find anyway. It is the
/// proof that `FakeTorrentEngine` does what the real engine does.
final class RqbitEngineContractTests: TorrentEngineContractTests {

    private var rqbit: RqbitEngine?

    override func makeEngine() async throws -> TorrentEngine {
        guard let path = ProcessInfo.processInfo.environment["CONVOY_RQBIT_BINARY"], !path.isEmpty else {
            throw XCTSkip("set CONVOY_RQBIT_BINARY to run the contract against the real helper")
        }
        let engine = RqbitEngine(
            options: RqbitEngine.Options(
                executable: URL(fileURLWithPath: path),
                sessionDirectory: scratch.appendingPathComponent("engine-session"),
                defaultOutputFolder: scratch.appendingPathComponent("engine-incoming"),
                extraArguments: ["--disable-dht", "--disable-trackers"]
            ),
            supervisor: ProcessSupervisor(runDirectory: scratch.appendingPathComponent("engine-run"))
        )
        rqbit = engine
        return engine
    }

    override func stop(_ engine: TorrentEngine) async {
        await rqbit?.stop()
    }
}
