import XCTest
@testable import DownloadEngine

/// A server for whole downloads: ranged or not, and able to fail the ways
/// real ones did — dropping connections, answering busy, compressing a reply
/// it was asked not to.
private final class StubServer: URLProtocol {
    enum Compression { case none, always, rangedPartsOnly }

    struct Config {
        var body = Data()
        var supportsRanges = true
        var compression = Compression.none
        /// The first this-many requests fail before any reply.
        var failBeforeReplyFirst = 0
        /// The first this-many replies stop after `dropAfterBytes`.
        var dropFirst = 0
        var dropAfterBytes = 0
        /// The first this-many requests are answered 503.
        var busyFirst = 0
        var etag: String?
    }

    struct Request { let range: String?; let acceptEncoding: String? }

    nonisolated(unsafe) private static var config = Config()
    nonisolated(unsafe) private static var counters = (failBeforeReply: 0, drop: 0, busy: 0)
    nonisolated(unsafe) private static var _requests: [Request] = []
    private static let lock = NSLock()

    static var requests: [Request] { lock.withLock { _requests } }

    static func reset(_ config: Config) {
        lock.withLock {
            self.config = config
            counters = (config.failBeforeReplyFirst, config.dropFirst, config.busyFirst)
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let (config, failBeforeReply, drop, busy) = Self.lock.withLock { () -> (Config, Bool, Bool, Bool) in
            Self._requests.append(Request(range: rangeHeader, acceptEncoding: request.value(forHTTPHeaderField: "Accept-Encoding")))
            func take(_ n: inout Int) -> Bool { guard n > 0 else { return false }; n -= 1; return true }
            let failBeforeReply = take(&Self.counters.failBeforeReply)
            let busy = !failBeforeReply && take(&Self.counters.busy)
            let drop = !failBeforeReply && !busy && take(&Self.counters.drop)
            return (Self.config, failBeforeReply, drop, busy)
        }

        if failBeforeReply {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        if busy {
            reply(status: 503, headers: ["Content-Length": "0"], body: Data())
            return
        }

        let body = config.body
        var status = 200
        var slice = body
        var headers: [String: String] = [:]
        headers["ETag"] = config.etag
        if request.httpMethod == "HEAD" {
            headers["Content-Length"] = "\(body.count)"
            reply(status: 200, headers: headers, body: Data())
            return
        }
        if config.supportsRanges {
            headers["Accept-Ranges"] = "bytes"
            if let rangeHeader, rangeHeader.hasPrefix("bytes=") {
                let bounds = rangeHeader.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(bounds[0]) ?? 0
                let end = min(bounds.count > 1 ? (Int(bounds[1]) ?? body.count - 1) : body.count - 1, body.count - 1)
                status = 206
                slice = body.subdata(in: start ..< end + 1)
                headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            }
        }

        let compressed: Bool
        switch config.compression {
        case .none: compressed = false
        case .always: compressed = true
        // Every ranged request but the probe's (which starts at byte 0).
        case .rangedPartsOnly: compressed = status == 206 && !(rangeHeader ?? "").hasPrefix("bytes=0-")
        }
        if compressed {
            // The stub sends the decoded bytes URLSession would hand over.
            headers["Content-Encoding"] = "gzip"
        } else {
            headers["Content-Length"] = "\(slice.count)"
        }

        if drop {
            let cut = min(config.dropAfterBytes, slice.count)
            reply(status: status, headers: headers, body: slice.prefix(cut), finish: false)
            // A moment later: URLSession drops bytes delivered in the same
            // instant as the failure.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        reply(status: status, headers: headers, body: slice)
    }

    private func reply(status: Int, headers: [String: String], body: Data, finish: Bool = true) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < body.count {
            let next = min(offset + 64 << 10, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: body.startIndex + offset ..< body.startIndex + next))
            offset = next
        }
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {}
}

/// Whole downloads through `DownloadTask`: the probe, parts or a whole-file
/// request, and the file that lands at the destination.
@MainActor
final class DownloadTaskRetryTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTaskRetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        URLSessionConfiguration.testProtocolClasses = [StubServer.self]
    }

    override func tearDown() async throws {
        URLSessionConfiguration.testProtocolClasses = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ $0 / 251) % 251) })
    }

    /// No extension in the URL, so nothing renames the file and the shared
    /// DownloadManager stays out of it.
    private func makeTask() -> DownloadTask {
        let task = DownloadTask(
            url: URL(string: "https://example.test/files/payload")!,
            destinationURL: folder.appendingPathComponent("payload"),
            originalName: "payload"
        )
        task.retryDelay = { _, _ in 0.01 }
        return task
    }

    private func assertCompleted(_ task: DownloadTask, with expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(task.status, .completed, "\(String(describing: task.error))", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), expected, file: file, line: line)
        XCTAssertEqual(task.totalBytes, Int64(expected.count), file: file, line: line)
    }

    // MARK: - Parts

    /// Big enough for parallel parts, every one of which loses its
    /// connection once — as all of them do when they share an HTTP/3
    /// connection that drops.
    func testPartsThatAllLoseTheirConnectionStillFinishTheFile() async throws {
        let expected = body(12 << 20)
        StubServer.reset(.init(body: expected, dropFirst: 9, dropAfterBytes: 200_000))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        // The probe, eight parts that dropped, and eight that finished them
        // from where they stopped rather than from each part's start.
        let parts = StubServer.requests.dropFirst().compactMap(\.range)
        XCTAssertEqual(parts.count, 16, "\(parts)")
        XCTAssertEqual(Set(parts).count, 16, "a retry asks for what's missing, not the whole part again")
    }

    func testAFirstRequestThatFailsBeforeAnyReplyIsMadeAgain() async throws {
        let expected = body(300_000)
        StubServer.reset(.init(body: expected, failBeforeReplyFirst: 2))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
    }

    func testABusyServerIsWaitedOut() async throws {
        let expected = body(300_000)
        StubServer.reset(.init(body: expected, busyFirst: 3))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
    }

    func testEveryRequestAsksForTheFileUncompressed() async throws {
        let expected = body(12 << 20)
        StubServer.reset(.init(body: expected))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertGreaterThan(StubServer.requests.count, 1)
        XCTAssertTrue(StubServer.requests.allSatisfy { $0.acceptEncoding == "identity" })
    }

    // MARK: - No usable ranges

    /// Nothing to resume from: each failure starts the file over.
    func testAServerWithoutRangesStartsOverAfterADrop() async throws {
        let expected = body(3 << 20)
        StubServer.reset(.init(body: expected, supportsRanges: false, dropFirst: 2, dropAfterBytes: 500_000))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertEqual(StubServer.requests.count, 3)
    }

    /// A server that compresses even when asked not to: the size is
    /// unknown and ranges are unusable, so the file comes in one request —
    /// not truncated at the probe's range.
    func testAServerThatAlwaysCompressesIsFetchedWhole() async throws {
        let expected = body(3 << 20)
        StubServer.reset(.init(body: expected, compression: .always))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertNil(StubServer.requests.last?.range, "the whole file is asked for without a range")
    }

    /// The probe's reply was plain but a part's came compressed: the parts
    /// are discarded and the file is fetched whole.
    func testCompressedPartsFallBackToOneRequest() async throws {
        let expected = body(12 << 20)
        StubServer.reset(.init(body: expected, compression: .rangedPartsOnly))

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertNil(StubServer.requests.last?.range)
    }

    // MARK: - Resuming

    /// A resume that finds the file changed on the server starts over — and
    /// runs to the end rather than stopping at "Validating".
    func testAResumeThatFindsTheFileChangedStartsOverAndFinishes() async throws {
        let expected = body(300_000)
        StubServer.reset(.init(body: expected, etag: "\"v2\""))

        let task = DownloadTask(
            url: URL(string: "https://example.test/files/payload")!,
            destinationURL: folder.appendingPathComponent("payload"),
            originalName: "payload",
            initialStatus: .paused,
            totalBytes: 250_000,
            downloadedBytes: 1_000,
            etag: "\"v1\"",
            lastValidatedAt: nil
        )
        task.retryDelay = { _, _ in 0.01 }
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertEqual(task.etag, "\"v2\"")
    }

    // MARK: - Failures that are not retried

    func testAMissingFileFailsAtOnce() async throws {
        NotFoundServer.count = 0
        URLSessionConfiguration.testProtocolClasses = [NotFoundServer.self]

        let task = makeTask()
        do { try await task.start() } catch {}

        guard case .failed(let error) = task.status, case DownloadError.httpError(404)? = error else {
            return XCTFail("expected a 404 failure, got \(task.status)")
        }
        XCTAssertEqual(NotFoundServer.count, 1)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(task.id.uuidString) }, "no empty part file left")
    }

    // MARK: - Pausing

    /// A pause during a wait before a retry stops the download there.
    func testPausingDuringARetryWaitStopsTheDownload() async throws {
        let expected = body(300_000)
        StubServer.reset(.init(body: expected, failBeforeReplyFirst: 1))

        let task = makeTask()
        task.retryDelay = { _, _ in 30 }
        let run = Task { try await task.start() }
        while StubServer.requests.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)

        let started = Date()
        await task.pause()
        _ = try? await run.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(task.status, .paused)
        XCTAssertEqual(StubServer.requests.count, 1, "no request after the pause")
        // A paused download keeps its part until resumed or removed.
        TemporaryStorage.removeSegmentFiles(of: task.id)
    }
}

/// Answers 404 to everything, and counts.
private final class NotFoundServer: URLProtocol {
    nonisolated(unsafe) static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
