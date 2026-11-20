import XCTest
@testable import DownloadEngine

/// A real torrent through the real helper: the one check the fixtures cannot
/// make. It joins a public swarm, so it runs only when asked.
///
///     CONVOY_RQBIT_BINARY=/path/to/rqbit \
///     CONVOY_RQBIT_MAGNET='magnet:?xt=urn:btih:...' \
///     swift test --filter RqbitEngineSwarmTests
///
/// Use content that is free to share (Blender's open movies are the usual
/// choice). It downloads for about twenty seconds, then pauses, resumes and
/// deletes what it fetched, all inside a temporary folder. DHT is on, because
/// resolving a magnet needs it.
///
/// What it settles that nothing else can: that a magnet resolves to a torrent
/// whose hash matches the link; that adding the bytes as received keeps that
/// hash; that peers connect and bytes arrive; and that the speed rqbit reports
/// in `mbps` really is mebibytes per second, by comparing it with how fast
/// the byte count was actually rising.
final class RqbitEngineSwarmTests: XCTestCase {

    private func log(_ text: String) { print("[swarm] \(text)") }

    func testAMagnetIsResolvedDownloadedPausedResumedAndRemoved() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binary = environment["CONVOY_RQBIT_BINARY"], !binary.isEmpty,
              let magnet = environment["CONVOY_RQBIT_MAGNET"], !magnet.isEmpty else {
            throw XCTSkip("set CONVOY_RQBIT_BINARY and CONVOY_RQBIT_MAGNET to run against a real swarm")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rqbit-swarm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        let engine = RqbitEngine(
            options: RqbitEngine.Options(
                executable: URL(fileURLWithPath: binary),
                sessionDirectory: scratch.appendingPathComponent("session"),
                defaultOutputFolder: scratch.appendingPathComponent("incoming")
            ),
            supervisor: ProcessSupervisor(runDirectory: scratch.appendingPathComponent("run"))
        )
        addTeardownBlock { await engine.stop() }

        // 1. The link resolves to the torrent it names.
        let wanted = try MagnetURI(magnet)
        let started = Date()
        let file = try await engine.probe(magnet: magnet)
        log("resolved \"\(file.name)\" in \(String(format: "%.1f", Date().timeIntervalSince(started))) s: "
            + "\(file.files.count) file(s), \(file.totalSize) bytes")
        XCTAssertEqual(file.infoHash, wanted.infoHash, "the resolved torrent is not the one the link names")

        // 2. One file of a sensible size, so the transfer lasts long enough to
        //    measure and never fetches the whole thing.
        let candidates = file.files.enumerated().filter { $0.element.length >= 1 << 20 }
        let chosen = try XCTUnwrap(
            candidates.min { $0.element.length < $1.element.length }
                ?? file.files.enumerated().max { $0.element.length < $1.element.length },
            "the torrent has no files")
        log("downloading only \(chosen.element.path.joined(separator: "/")) (\(chosen.element.length) bytes)")

        // 3. Adding the bytes as received keeps the hash.
        let target = scratch.appendingPathComponent("download")
        let details = try await engine.add(.torrentFile(file.source), into: target, files: [chosen.offset])
        XCTAssertEqual(details.infoHash, file.infoHash)
        XCTAssertEqual(details.files.filter(\.isIncluded).count, 1)

        // 4. Bytes arrive, peers connect, and the reported speed is believable.
        var peerCount = 0
        var reported: [Double] = []
        var firstBytes: (Date, Int64)?
        var last: TorrentSnapshot?
        let deadline = Date().addingTimeInterval(120)
        let measureUntil = { (from: Date) in from.addingTimeInterval(20) }
        var measureEnd: Date?
        while Date() < deadline {
            let snapshot = try await engine.snapshot(of: file.infoHash)
            last = snapshot
            peerCount = max(peerCount, snapshot.connectedPeers)
            if snapshot.downloadedBytes > 0, firstBytes == nil {
                firstBytes = (Date(), snapshot.downloadedBytes)
                measureEnd = measureUntil(Date())
                log("first bytes after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, "
                    + "\(snapshot.connectedPeers) peer(s)")
            }
            if firstBytes != nil { reported.append(snapshot.downloadBytesPerSecond) }
            if snapshot.state == .seeding { break }
            if let measureEnd, Date() >= measureEnd { break }
            try await Task.sleep(for: .seconds(1))
        }
        let snapshot = try XCTUnwrap(last)
        let first = try XCTUnwrap(firstBytes, "no bytes arrived within 120 s: is the swarm alive?")
        XCTAssertGreaterThan(peerCount, 0)
        XCTAssertGreaterThan(snapshot.downloadedBytes, 0)

        let window = Date().timeIntervalSince(first.0)
        if window >= 5, snapshot.state != .seeding {
            let observed = Double(snapshot.downloadedBytes - first.1) / window
            let average = reported.reduce(0, +) / Double(max(reported.count, 1))
            log("observed \(Int(observed)) B/s over \(String(format: "%.0f", window)) s; "
                + "reported \(Int(average)) B/s on average")
            // Speeds swing from second to second, so this is loose on purpose:
            // wide enough for that, far too narrow for a units mistake (bits
            // against bytes is a factor of eight).
            XCTAssertGreaterThan(average, observed * 0.4, "reported speed is far below what was observed")
            XCTAssertLessThan(average, observed * 2.5, "reported speed is far above what was observed")
        } else {
            log("the transfer ended before there was time to compare speeds: units not checked this run")
        }

        // 5. Pause stops it, resume restarts it.
        if snapshot.state != .seeding {
            try await engine.pause(file.infoHash)
            let paused = try await engine.snapshot(of: file.infoHash)
            XCTAssertEqual(paused.state, .paused)
            try await Task.sleep(for: .seconds(2))
            let still = try await engine.snapshot(of: file.infoHash)
            XCTAssertEqual(still.downloadedBytes, paused.downloadedBytes, "bytes kept arriving while paused")

            try await engine.resume(file.infoHash)
            var resumed = false
            for _ in 0..<30 {
                let now = try await engine.snapshot(of: file.infoHash)
                if now.downloadedBytes > paused.downloadedBytes || now.state == .seeding { resumed = true; break }
                try await Task.sleep(for: .seconds(1))
            }
            XCTAssertTrue(resumed, "no bytes arrived within 30 s of resuming")
        }

        // 6. Removing with data leaves nothing of the payload behind.
        try await engine.remove(file.infoHash, deleteData: true)
        let leftover = chosen.element.path.reduce(target) { $0.appendingPathComponent($1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "the deleted torrent's file is still there")
        log("done")
    }
}
