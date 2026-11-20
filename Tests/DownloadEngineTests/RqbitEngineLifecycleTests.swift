import XCTest
@testable import DownloadEngine

/// How `RqbitEngine` starts, replaces and stops its helper, tested with no
/// rqbit: the "helper" is a script that logs each launch and sleeps, and the
/// stub answers (or fails) its HTTP on its behalf. Every helper gets its own
/// random port, so a request's port says which helper it was meant for, which
/// is how these tests kill one helper without killing its replacement.
final class RqbitEngineLifecycleTests: XCTestCase {

    private var scratch: URL!
    private var supervisor: ProcessSupervisor!
    private let ledger = Ledger()
    private let torrent = TorrentInfoHash(hex: TorrentFixtures.hashA)!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubHelperProtocol.reset()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("rqbit-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        supervisor = ProcessSupervisor(runDirectory: scratch.appendingPathComponent("run"))
    }

    override func tearDownWithError() throws {
        StubHelperProtocol.reset()
        supervisor.stopAll(timeout: 3)
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private let statsJSON = """
    {"state":"live","file_progress":[0],"error":null,"progress_bytes":0,"uploaded_bytes":0,"total_bytes":5,"finished":false,
    "live":{"snapshot":{"peer_stats":{"queued":0,"connecting":0,"live":0,"live_seeders":0,"seen":0}},
    "download_speed":{"mbps":0.0,"human_readable":"0.00 MiB/s"},"upload_speed":{"mbps":0.0,"human_readable":"0.00 MiB/s"}}}
    """

    /// What each helper's HTTP side does.
    private enum Behaviour {
        case healthy
        /// Its control port never answers, so it never counts as started.
        case neverAnswers
        /// The first helper to be pinged stops answering everything but the
        /// ping, as one that has died does. Its replacements are healthy.
        case firstHelperDies
        /// Every helper stops answering after being pinged.
        case everyHelperDies
        /// Like `firstHelperDies`, and the replacement reports that the torrent
        /// being removed is already gone, as one that restored a session in
        /// which the removal had happened would.
        case firstHelperDiesAndReplacementHasNoSuchTorrent
        /// Like `firstHelperDies`, but only the first request to it fails at
        /// once. Any later one hangs for a while and then fails, so its
        /// failure arrives after the replacement is already up.
        case firstHelperDiesSlowly
    }

    /// What the stub has seen, by port. Every helper the engine launches gets
    /// a port of its own and is pinged on it at once, so the number of
    /// distinct ports pinged is the number of helpers launched. (Counting from
    /// inside the helper script would miss one that is retired before its shell
    /// has run a line.)
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var first: Int?
        private var pinged: Set<Int> = []
        private var stats: [Int] = []
        private var requestsToFirst = 0
        /// How many stats requests the first helper has been sent, this one included.
        func countRequestToFirst() -> Int { lock.withLock { requestsToFirst += 1; return requestsToFirst } }
        func notePing(_ port: Int) { lock.withLock { pinged.insert(port); if first == nil { first = port } } }
        var launchCount: Int { lock.withLock { pinged.count } }
        func isFirst(_ port: Int) -> Bool { lock.withLock { first == port } }
        func noteStats(_ port: Int) { lock.withLock { stats.append(port) } }
        var statsPorts: [Int] { lock.withLock { stats } }
    }

    private func install(_ behaviour: Behaviour) {
        let statsJSON = self.statsJSON
        let ledger = self.ledger
        StubHelperProtocol.route = { request in
            let port = request.url.port ?? 0
            if request.path == "/" {
                ledger.notePing(port)
                return behaviour == .neverAnswers
                    ? .init(failure: URLError(.cannotConnectToHost))
                    : .init(body: Data("{}".utf8))
            }
            if request.path.hasSuffix("/stats/v1") { ledger.noteStats(port) }

            let dead = URLError(.cannotConnectToHost)
            switch behaviour {
            case .everyHelperDies:
                return .init(failure: dead)
            case .firstHelperDiesSlowly where ledger.isFirst(port):
                if ledger.countRequestToFirst() > 1 { Thread.sleep(forTimeInterval: 0.8) }
                return .init(failure: dead)
            case .firstHelperDies where ledger.isFirst(port),
                 .firstHelperDiesAndReplacementHasNoSuchTorrent where ledger.isFirst(port):
                return .init(failure: dead)
            case .firstHelperDiesAndReplacementHasNoSuchTorrent
                where request.path.hasSuffix("/forget") || request.path.hasSuffix("/delete"):
                return .init(status: 500, body: Data("""
                {"error_kind":"internal_error","human_readable":"error forgetting torrent: no such torrent in db","status":500}
                """.utf8))
            default:
                return request.path.hasSuffix("/stats/v1")
                    ? .init(body: Data(statsJSON.utf8))
                    : .init(body: Data("{}".utf8))
            }
        }
    }

    private func helperScript() throws -> URL {
        let url = scratch.appendingPathComponent("fake-rqbit")
        try "#!/bin/sh\nexec sleep 60\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeEngine(startTimeout: TimeInterval = 5) throws -> RqbitEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHelperProtocol.self]
        return RqbitEngine(
            options: RqbitEngine.Options(
                executable: try helperScript(),
                sessionDirectory: scratch.appendingPathComponent("session"),
                defaultOutputFolder: scratch.appendingPathComponent("incoming"),
                startTimeout: startTimeout
            ),
            supervisor: supervisor,
            clientConfiguration: configuration
        )
    }

    private var launches: Int { ledger.launchCount }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out waiting") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// "Exactly n launches" means: wait for n to appear, give any extra one
    /// time to show up, then count.
    private func expectLaunches(_ n: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil({ launches >= n }, timeout: 5)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(launches, n, message, file: file, line: line)
    }

    // MARK: - Stopping is a barrier

    /// The case that was reproduced: stop() returned while the helper it had
    /// been starting was still running, free to hold the session folder open
    /// against whatever started next.
    func testStopWhileAHelperIsStartingLeavesNoHelperBehind() async throws {
        install(.neverAnswers)
        let engine = try makeEngine()
        let call = Task { try? await engine.snapshot(of: torrent) }
        try await waitUntil { launches == 1 }
        XCTAssertEqual(supervisor.activeCount, 1)

        await engine.stop()

        XCTAssertEqual(supervisor.activeCount, 0, "stop() returned while a helper was still running")
        _ = await call.value
        try await expectLaunches(1, "the interrupted call must not have started another")
    }

    func testAfterAStopTheNextCallStartsAFreshHelper() async throws {
        install(.neverAnswers)
        let engine = try makeEngine()
        let interrupted = Task { try? await engine.snapshot(of: torrent) }
        try await waitUntil { launches == 1 }
        await engine.stop()
        _ = await interrupted.value

        install(.healthy)
        let snapshot = try await engine.snapshot(of: torrent)

        XCTAssertEqual(snapshot.state, .downloading)
        try await expectLaunches(2)
        XCTAssertEqual(supervisor.activeCount, 1)
    }

    func testEveryCallWaitingOnAStartingHelperIsToldItWasStopped() async throws {
        install(.neverAnswers)
        let engine = try makeEngine()
        let calls = (0..<3).map { _ in
            Task { () -> TorrentEngineError? in
                do { _ = try await engine.snapshot(of: torrent); return nil }
                catch { return error as? TorrentEngineError }
            }
        }
        try await waitUntil { launches == 1 }

        await engine.stop()

        for call in calls { let error = await call.value; XCTAssertEqual(error, .helperUnavailable) }
        try await expectLaunches(1, "waiters must not start helpers of their own while a stop is under way")
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    /// A request already on the wire when stop() is called finds its helper
    /// gone. That must end in an error, not in a new helper started after the
    /// engine was told to stop.
    func testACallInFlightDuringAStopDoesNotRestartTheHelper() async throws {
        let ledger = self.ledger
        StubHelperProtocol.route = { request in
            if request.path == "/" { ledger.notePing(request.url.port ?? 0); return .init(body: Data("{}".utf8)) }
            Thread.sleep(forTimeInterval: 0.4)           // the request is "on the wire"
            return .init(failure: URLError(.networkConnectionLost))
        }
        let engine = try makeEngine()
        let call = Task { () -> TorrentEngineError? in
            do { _ = try await engine.snapshot(of: torrent); return nil }
            catch { return error as? TorrentEngineError }
        }
        try await waitUntil { StubHelperProtocol.received.contains { $0.path.hasSuffix("/stats/v1") } }

        await engine.stop()

        let error = await call.value
        XCTAssertEqual(error, .helperUnavailable)
        try await expectLaunches(1)
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    // MARK: - Replacing a helper that has died

    func testAHelperThatStoppedAnsweringIsReplacedAndTheCallRetriedOnce() async throws {
        install(.firstHelperDies)
        let engine = try makeEngine()

        let snapshot = try await engine.snapshot(of: torrent)

        XCTAssertEqual(snapshot.state, .downloading)
        try await expectLaunches(2)
        XCTAssertEqual(supervisor.activeCount, 1, "the dead helper must be stopped, not left beside its replacement")
        XCTAssertEqual(Set(ledger.statsPorts).count, 2, "the retry must have gone to the new helper")
    }

    /// Several calls fail against the same dead helper at once. Only the
    /// first may retire it; a late failure must not retire the replacement.
    func testManyCallsFailingAgainstOneDeadHelperReplaceItOnce() async throws {
        install(.firstHelperDies)
        let engine = try makeEngine()
        let torrent = self.torrent

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { (try? await engine.snapshot(of: torrent))?.state == .downloading }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }

        XCTAssertEqual(results, Array(repeating: true, count: 8))
        try await expectLaunches(2, "one helper died, so exactly one replacement was due")
        XCTAssertEqual(supervisor.activeCount, 1)
    }

    /// One call fails at once and sets the replacement going. Another has a
    /// request in flight on the old helper. Retiring the old helper cancels
    /// that request, and the cancellation has to be read as "the helper is
    /// gone" and retried on the replacement, not handed to the caller as a
    /// cancellation nobody asked for. One replacement is all that is started.
    ///
    /// What this does not prove: that a failure charged to a retired helper
    /// cannot evict its replacement. Retiring a helper cancels its requests
    /// straight away, and a replacement is not started until that has
    /// happened, so such a failure arrives before the replacement exists and
    /// the interleaving cannot be forced from outside. The eviction is by
    /// helper identity as defence in depth; nothing here pins it.
    func testARequestCancelledByItsHelpersRetirementIsRetriedOnTheReplacement() async throws {
        install(.firstHelperDiesSlowly)
        let engine = try makeEngine()
        let torrent = self.torrent

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask { (try? await engine.snapshot(of: torrent))?.state == .downloading }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }

        XCTAssertEqual(results, [true, true])
        try await expectLaunches(2, "one helper died, so one replacement was due")
        XCTAssertEqual(supervisor.activeCount, 1)
    }

    func testOnlyOneReplacementIsTriedBeforeGivingUp() async throws {
        install(.everyHelperDies)
        let engine = try makeEngine()

        do {
            _ = try await engine.snapshot(of: torrent)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .helperUnavailable)
        }
        try await expectLaunches(2, "the original and one replacement, then stop trying")
        await engine.stop()
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    /// If the first attempt at removing a torrent died with its helper, and
    /// the replacement says the torrent is gone, the removal did happen.
    func testARemovalRetriedAfterACrashTreatsAlreadyGoneAsDone() async throws {
        install(.firstHelperDiesAndReplacementHasNoSuchTorrent)
        let engine = try makeEngine()

        try await engine.remove(torrent, deleteData: false)

        try await expectLaunches(2)
    }

    /// Without a crash, "no such torrent" is still an answer for the caller.
    func testARemovalOfAnUnknownTorrentIsStillNotFoundWhenNothingWentWrong() async throws {
        StubHelperProtocol.route = { request in
            request.path == "/" ? .init(body: Data("{}".utf8))
                : .init(status: 500, body: Data(#"{"error_kind":"internal_error","human_readable":"error forgetting torrent: no such torrent in db","status":500}"#.utf8))
        }
        let engine = try makeEngine()
        do {
            try await engine.remove(torrent, deleteData: false)
            XCTFail("expected .notFound")
        } catch {
            XCTAssertEqual(error as? TorrentEngineError, .notFound)
        }
    }

    // MARK: - Sharing one launch

    /// Callers that arrive while a helper is starting, or after, share it.
    func testConcurrentFirstCallsStartOneHelper() async throws {
        install(.healthy)
        let engine = try makeEngine()
        let torrent = self.torrent

        let states = await withTaskGroup(of: TorrentSnapshot.State?.self) { group in
            for _ in 0..<6 { group.addTask { try? await engine.snapshot(of: torrent).state } }
            return await group.reduce(into: [TorrentSnapshot.State?]()) { $0.append($1) }
        }

        XCTAssertEqual(states.compactMap { $0 }.count, 6)
        try await expectLaunches(1)
        XCTAssertEqual(supervisor.activeCount, 1)
    }
}
