import XCTest
@testable import DownloadEngine

/// The fake's own scripting hooks. Its engine behaviour is covered by the
/// contract suite; these are for what only tests use.
final class FakeTorrentEngineTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private var magnetA: String { "magnet:?xt=urn:btih:\(TorrentFixtures.hashA)" }

    func testAMagnetFindsNoPeersUntilItIsMadeResolvable() async throws {
        let engine = FakeTorrentEngine()
        do {
            _ = try await engine.probe(magnet: magnetA)
            XCTFail("an unresolvable magnet must be refused")
        } catch TorrentEngineError.rejected {
            // expected
        }

        engine.makeResolvable(try TorrentFile(TorrentFixtures.dataA))

        let file = try await engine.probe(magnet: magnetA)
        XCTAssertEqual(file.infoHash.hex, TorrentFixtures.hashA)
        let details = try await engine.add(.magnet(magnetA), into: scratch.appendingPathComponent("m"), files: nil)
        XCTAssertEqual(details.name, "abc")
    }

    func testSimulateBendsWhatTheSnapshotReports() async throws {
        let engine = FakeTorrentEngine()
        let torrent = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashA))
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: scratch.appendingPathComponent("s"), files: nil)

        engine.simulate(torrent) {
            $0.state = .seeding
            $0.downloadedBytes = 5
            $0.connectedPeers = 3
        }

        let snapshot = try await engine.snapshot(of: torrent)
        XCTAssertEqual(snapshot.state, .seeding)
        XCTAssertEqual(snapshot.downloadedBytes, 5)
        XCTAssertEqual(snapshot.connectedPeers, 3)
        XCTAssertEqual(snapshot.totalBytes, 5, "what was not simulated keeps its default")
    }

    func testTheUpdateStreamSeesASimulatedChange() async throws {
        let engine = FakeTorrentEngine()
        let torrent = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashA))
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: scratch.appendingPathComponent("u"), files: nil)

        var states: [TorrentSnapshot.State] = []
        for try await snapshot in engine.updates(of: torrent, every: .milliseconds(10)) {
            states.append(snapshot.state)
            if states.count == 1 { engine.simulate(torrent) { $0.state = .seeding } }
            if snapshot.state == .seeding { break }
            if states.count > 300 { return XCTFail("never saw the simulated state") }
        }
        XCTAssertEqual(states.first, .downloading)
        XCTAssertEqual(states.last, .seeding)
    }
}
