import XCTest
@testable import DownloadEngine

/// A range-aware stub server. Records every `Range` it was asked for, and can
/// answer the way the real servers that broke downloads do: cutting a response
/// short, ignoring the range and sending the whole file, or reporting a
/// Content-Range it isn't actually serving from.
private final class StubRangeProtocol: URLProtocol {
    struct Config {
        var body = Data()
        /// Bytes to serve per response, however many were asked for. Nil
        /// serves the whole requested range; 0 serves an empty body.
        var maxBytesPerResponse: Int?
        /// Answer 200 with the entire body, whatever was asked for.
        var ignoreRange = false
        /// Report this start byte in Content-Range rather than the real one.
        var contentRangeStartOverride: Int64?
        /// Sent back on every response.
        var etag: String?
        var lastModified: String?
        /// Answer a request carrying `If-Range` with the whole file, the way
        /// a server does when the validator no longer matches.
        var ifRangeFails = false
        var chunkSize = 1024
        /// The first this-many requests send `stallAfterBytes` and then
        /// never finish, like a connection that has gone quiet.
        var stallFirstRequests = 0
        var stallAfterBytes = 4_096
        /// The first this-many requests send `dropAfterBytes` and then lose
        /// the connection, the way a dropped HTTP/3 connection ends them.
        var dropFirstRequests = 0
        var dropAfterBytes = 0
        /// The first this-many requests are answered `busyStatus`, no body.
        var busyFirstRequests = 0
        var busyStatus = 503
        var retryAfter: String?
        /// Sent as Content-Encoding on every successful reply.
        var contentEncoding: String?
    }

    nonisolated(unsafe) static var config = Config()
    private nonisolated(unsafe) static var _rangesAsked: [String] = []
    private nonisolated(unsafe) static var _ifRangesSent: [String?] = []
    private nonisolated(unsafe) static var _stallsLeft = 0
    private nonisolated(unsafe) static var _dropsLeft = 0
    private nonisolated(unsafe) static var _busyLeft = 0
    private nonisolated(unsafe) static var _acceptEncodings: [String?] = []
    private static let lock = NSLock()

    static var rangesAsked: [String] { lock.withLock { _rangesAsked } }
    static var ifRangesSent: [String?] { lock.withLock { _ifRangesSent } }
    static var acceptEncodings: [String?] { lock.withLock { _acceptEncodings } }
    static func reset(_ config: Config) {
        lock.withLock {
            _rangesAsked = []
            _ifRangesSent = []
            _acceptEncodings = []
            _stallsLeft = config.stallFirstRequests
            _dropsLeft = config.dropFirstRequests
            _busyLeft = config.busyFirstRequests
        }
        self.config = config
    }

    /// Takes one from a counter, if any are left.
    private static func take(_ counter: inout Int) -> Bool {
        lock.withLock {
            guard counter > 0 else { return false }
            counter -= 1
            return true
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let config = Self.config
        let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? ""
        let ifRange = request.value(forHTTPHeaderField: "If-Range")
        Self.lock.withLock {
            Self._rangesAsked.append(rangeHeader)
            Self._ifRangesSent.append(ifRange)
            Self._acceptEncodings.append(request.value(forHTTPHeaderField: "Accept-Encoding"))
        }

        if Self.take(&Self._busyLeft) {
            var headers: [String: String] = ["Content-Length": "0"]
            headers["Retry-After"] = config.retryAfter
            let response = HTTPURLResponse(url: request.url!, statusCode: config.busyStatus,
                                           httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let (start, end) = Self.parse(rangeHeader, bodyCount: config.body.count)
        var headers: [String: String] = [:]
        var status = 206
        var slice = Data()
        headers["ETag"] = config.etag
        headers["Last-Modified"] = config.lastModified
        headers["Content-Encoding"] = config.contentEncoding

        if config.ignoreRange || (config.ifRangeFails && request.value(forHTTPHeaderField: "If-Range") != nil) {
            status = 200
            slice = config.body
            headers["Content-Length"] = "\(slice.count)"
        } else {
            var last = min(end, config.body.count - 1)
            if let cap = config.maxBytesPerResponse { last = min(last, start + cap - 1) }
            if start <= last {
                slice = config.body.subdata(in: start ..< (last + 1))
                let reported = config.contentRangeStartOverride ?? Int64(start)
                headers["Content-Range"] = "bytes \(reported)-\(last)/\(config.body.count)"
            }
            headers["Content-Length"] = "\(slice.count)"
        }

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if Self.take(&Self._dropsLeft) {
            let end = min(config.dropAfterBytes, slice.count)
            if end > 0 { client?.urlProtocol(self, didLoad: slice.subdata(in: 0 ..< end)) }
            // A moment later, as on a real connection: URLSession drops
            // bytes delivered in the same instant as the failure.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }

        let stalls = Self.take(&Self._stallsLeft)
        if stalls {
            var offset = 0
            let end = min(config.stallAfterBytes, slice.count)
            while offset < end {
                let next = min(offset + config.chunkSize, end)
                client?.urlProtocol(self, didLoad: slice.subdata(in: offset ..< next))
                offset = next
            }
            return
        }

        var offset = 0
        while offset < slice.count {
            let next = min(offset + config.chunkSize, slice.count)
            client?.urlProtocol(self, didLoad: slice.subdata(in: offset ..< next))
            offset = next
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parse(_ header: String, bodyCount: Int) -> (Int, Int) {
        guard header.hasPrefix("bytes=") else { return (0, bodyCount - 1) }
        let parts = header.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(parts.first ?? "") ?? 0
        let end = parts.count > 1 ? (Int(parts[1]) ?? bodyCount - 1) : bodyCount - 1
        return (start, end)
    }
}

private final class RetryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(attempt: Int, serverAsked: TimeInterval?)] = []

    func append(_ attempt: Int, _ serverAsked: TimeInterval?) { lock.withLock { entries.append((attempt, serverAsked)) } }
    var all: [(attempt: Int, serverAsked: TimeInterval?)] { lock.withLock { entries } }
}

/// What a segment writes, and when it is allowed to call itself finished.
///
/// The bugs these pin down all produced a file of roughly the right size that
/// wouldn't open: chunks written out of arrival order by a `Task` per chunk, a
/// short response counted as a finished part, and a resume request answered
/// with the whole file appended behind the bytes already on disk.
@MainActor
final class DownloadSegmentWriteTests: XCTestCase {
    private var session: URLSession!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRangeProtocol.self]
        session = URLSession(configuration: config, delegate: SharedSegmentSessionDelegate(), delegateQueue: nil)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    /// Every wait a segment asked for, with any Retry-After it passed on.
    private let retryLog = RetryLog()

    private func makeSegment(size: Int, isMultiSegment: Bool = false,
                            validators: ResourceValidators = ResourceValidators(etag: nil, lastModified: nil),
                            customHeaders: [String: String] = [:],
                            retryDelay: TimeInterval = 0.01) -> DownloadSegment {
        let task = DownloadTask(
            url: URL(string: "https://example.invalid/file.bin")!,
            destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin"),
            originalName: "file.bin",
            totalBytes: Int64(size),
            downloadedBytes: 0
        )
        let log = retryLog
        let segment = DownloadSegment(
            task: task, index: 0, startByte: 0, endByte: Int64(size) - 1,
            session: session, customHeaders: customHeaders, isMultiSegment: isMultiSegment, validators: validators,
            retryDelay: { attempt, serverAsked in
                log.append(attempt, serverAsked)
                return retryDelay
            }
        )
        tempFiles.append(segment.tempFileURL)
        return segment
    }

    /// Distinct, position-dependent bytes: a file of the right length made of
    /// the right chunks in the wrong order still fails this.
    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ $0 / 251) % 251) })
    }

    // MARK: - Write ordering

    func testChunksAreWrittenInArrivalOrder() async throws {
        let expected = body(600 * 1024)
        StubRangeProtocol.reset(.init(body: expected, chunkSize: 512))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        let downloaded = await segment.downloadedBytes
        XCTAssertEqual(downloaded, Int64(expected.count))
        let isComplete = await segment.isComplete
        XCTAssertTrue(isComplete)
    }

    /// The finish must not overtake the last chunks and close the file on them.
    func testNoBytesAreDroppedAtTheEndOfAResponse() async throws {
        let expected = body(200 * 1024)
        StubRangeProtocol.reset(.init(body: expected, chunkSize: 64))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL).count, expected.count)
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    // MARK: - Short responses

    func testAShortResponseIsRefetchedRatherThanCountedAsDone() async throws {
        let expected = body(10_000)
        StubRangeProtocol.reset(.init(body: expected, maxBytesPerResponse: 1_000))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        let isComplete = await segment.isComplete
        XCTAssertTrue(isComplete)
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, 10)
        XCTAssertEqual(StubRangeProtocol.rangesAsked[1], "bytes=1000-9999",
                       "the second request must ask for exactly what the first one left")
    }

    func testAServerThatKeepsSendingNothingFailsRatherThanCompleting() async throws {
        let expected = body(4_096)
        StubRangeProtocol.reset(.init(body: expected, maxBytesPerResponse: 0))

        let segment = makeSegment(size: expected.count)
        do {
            try await segment.download()
            XCTFail("expected the segment to fail rather than report itself finished")
        } catch DownloadError.noData {}

        let isComplete = await segment.isComplete
        XCTAssertFalse(isComplete)
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, 3, "should give up, not retry forever")
    }

    // MARK: - A resume answered with the whole file

    func testResumeAnsweredWithTheWholeFileStartsOverRatherThanAppending() async throws {
        let expected = body(8_000)
        StubRangeProtocol.reset(.init(body: expected, ignoreRange: true))

        let segment = makeSegment(size: expected.count)
        // Stand in for an interrupted earlier run.
        try expected.prefix(2_000).write(to: segment.tempFileURL)

        try await segment.download()

        XCTAssertEqual(StubRangeProtocol.rangesAsked.first, "bytes=2000-7999")
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected,
                       "the whole-file reply must replace the partial file, not follow it")
        let downloaded = await segment.downloadedBytes
        XCTAssertEqual(downloaded, Int64(expected.count))
    }

    /// Nothing on disk yet, so a 200 costs nothing and is still the file.
    func testWholeFileReplyToAFirstRequestIsAccepted() async throws {
        let expected = body(4_000)
        StubRangeProtocol.reset(.init(body: expected, ignoreRange: true))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, 1)
    }

    func testWholeFileReplyIsRefusedWhenOtherSegmentsWouldMisalign() async throws {
        let expected = body(4_000)
        StubRangeProtocol.reset(.init(body: expected, ignoreRange: true))

        let segment = makeSegment(size: expected.count, isMultiSegment: true)
        do {
            try await segment.download()
            XCTFail("expected rangeNotHonored")
        } catch DownloadError.rangeNotHonored {}
    }

    // MARK: - The file changing on the server

    func testAPartRequestCarriesIfRange() async throws {
        let expected = body(2_000)
        StubRangeProtocol.reset(.init(body: expected, etag: "\"v1\""))

        let segment = makeSegment(size: expected.count,
                                  validators: .init(etag: "\"v1\"", lastModified: nil))
        try await segment.download()

        XCTAssertEqual(StubRangeProtocol.ifRangesSent, ["\"v1\""])
    }

    /// RFC 9110: no weak ETag in If-Range, and no date when an ETag exists.
    func testAWeakETagSendsNoIfRange() async throws {
        let expected = body(2_000)
        StubRangeProtocol.reset(.init(body: expected, etag: "W/\"v1\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))

        let segment = makeSegment(size: expected.count,
                                  validators: .init(etag: "W/\"v1\"",
                                                    lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))
        try await segment.download()

        XCTAssertEqual(StubRangeProtocol.ifRangesSent, [nil])
    }

    /// A Last-Modified that changes per response, beside a stable ETag, is
    /// not a new version.
    func testAStableETagOutweighsAChangingLastModified() async throws {
        let expected = body(4_000)
        StubRangeProtocol.reset(.init(body: expected, etag: "\"v1\"",
                                      lastModified: "Tue, 02 Jan 2024 00:00:00 GMT"))

        let segment = makeSegment(size: expected.count,
                                  validators: .init(etag: "\"v1\"",
                                                    lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    // MARK: - Cancellation and runs

    private func waitForBytes(_ segment: DownloadSegment) async throws {
        for _ in 0..<200 {
            if await segment.downloadedBytes > 0 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("no bytes arrived")
    }

    /// Fails the test if `run` doesn't end with `.cancelled` within 2 s.
    private func expectCancelled(_ run: Task<Void, Error>) async {
        let ended = expectation(description: "run ended with .cancelled")
        Task {
            do { try await run.value } catch DownloadError.cancelled { ended.fulfill() } catch {}
        }
        await fulfillment(of: [ended], timeout: 2)
    }

    /// A pause ends the request now, not when the connection gets round to
    /// it, and the next run resumes from what's on disk.
    func testCancelEndsAStalledRequestAtOnce() async throws {
        let expected = body(100_000)
        StubRangeProtocol.reset(.init(body: expected, stallFirstRequests: 1))

        let segment = makeSegment(size: expected.count)
        let run = Task { try await segment.download() }
        try await waitForBytes(segment)
        await segment.cancel()
        await expectCancelled(run)

        try await segment.download()
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    /// A new run while an old one still waits: the old one exits instead of
    /// hanging, and only the new one writes.
    func testANewRunSupersedesAnUncancelledOne() async throws {
        let expected = body(100_000)
        StubRangeProtocol.reset(.init(body: expected, stallFirstRequests: 1))

        let segment = makeSegment(size: expected.count)
        let first = Task { try await segment.download() }
        try await waitForBytes(segment)

        try await segment.download()
        await expectCancelled(first)
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    /// What the task group does to the other parts when one fails.
    func testCancellingTheCallingTaskEndsTheRequest() async throws {
        let expected = body(100_000)
        StubRangeProtocol.reset(.init(body: expected, stallFirstRequests: 1))

        let segment = makeSegment(size: expected.count)
        let run = Task { try await segment.download() }
        try await waitForBytes(segment)
        run.cancel()
        await expectCancelled(run)

        try await segment.download()
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    /// Bytes past the counted size (a late probe write) are dropped, not
    /// written ahead of the request's data.
    func testWritingStartsAtTheCountedSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp")
        tempFiles.append(url)
        try Data(repeating: 1, count: 3_000).write(to: url)

        let handle = try SharedSegmentSessionDelegate.openForWriting(url, at: 2_000)
        try handle.write(contentsOf: Data(repeating: 2, count: 10))
        try handle.close()

        XCTAssertEqual(try Data(contentsOf: url), Data(repeating: 1, count: 2_000) + Data(repeating: 2, count: 10))
    }

    // MARK: - Disk is the source of truth

    /// A finished part whose file has gone is pending again.
    func testSyncWithDiskNoticesAMissingPart() async throws {
        let expected = body(3_000)
        StubRangeProtocol.reset(.init(body: expected))

        let segment = makeSegment(size: expected.count)
        try await segment.download()
        try FileManager.default.removeItem(at: segment.tempFileURL)

        await segment.syncWithDisk()
        let isComplete = await segment.isComplete
        XCTAssertFalse(isComplete)
        let downloaded = await segment.downloadedBytes
        XCTAssertEqual(downloaded, 0)
    }

    /// The server honours If-Range: the file changed, so it sends the whole
    /// new version instead of a slice of it.
    func testAServerRefusingTheRangeBecauseTheFileChangedIsReported() async throws {
        let replacement = body(6_000)
        StubRangeProtocol.reset(.init(body: replacement, etag: "\"v2\"", ifRangeFails: true))

        let segment = makeSegment(size: 6_000, validators: .init(etag: "\"v1\"", lastModified: nil))
        try replacement.prefix(1_000).write(to: segment.tempFileURL)

        do {
            try await segment.download()
            XCTFail("expected resourceChanged")
        } catch DownloadError.resourceChanged {}

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL).count, 1_000,
                       "the old partial data must be left for the task to discard, not written over")
    }

    /// The server ignores If-Range and serves the range anyway — the
    /// validators on the 206 still give the change away.
    func testAChangedFileIsCaughtEvenWhenTheServerIgnoresIfRange() async throws {
        let replacement = body(6_000)
        StubRangeProtocol.reset(.init(body: replacement, etag: "\"v2\""))

        let segment = makeSegment(size: 6_000, validators: .init(etag: "\"v1\"", lastModified: nil))
        try replacement.prefix(1_000).write(to: segment.tempFileURL)

        do {
            try await segment.download()
            XCTFail("expected resourceChanged")
        } catch DownloadError.resourceChanged {}
    }

    func testMatchingValidatorsDownloadNormally() async throws {
        let expected = body(6_000)
        StubRangeProtocol.reset(.init(body: expected, etag: "\"v1\"",
                                      lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))

        let segment = makeSegment(size: expected.count,
                                  validators: .init(etag: "\"v1\"",
                                                    lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"))
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    /// A server that stops sending validators says nothing about the file,
    /// and throwing away a good download over it would be worse than the bug.
    func testAServerThatStopsSendingValidatorsIsNotTreatedAsAChange() async throws {
        let expected = body(4_000)
        StubRangeProtocol.reset(.init(body: expected))

        let segment = makeSegment(size: expected.count,
                                  validators: .init(etag: "\"v1\"", lastModified: nil))
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }

    func testContentRangeStartingAtTheWrongByteIsRefused() async throws {
        let expected = body(8_000)
        StubRangeProtocol.reset(.init(body: expected, contentRangeStartOverride: 0))

        let segment = DownloadSegment(
            task: DownloadTask(
                url: URL(string: "https://example.invalid/file.bin")!,
                destinationURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).bin"),
                originalName: "file.bin",
                totalBytes: 8_000,
                downloadedBytes: 0
            ),
            index: 1, startByte: 4_000, endByte: 7_999,
            session: session, isMultiSegment: true
        )
        tempFiles.append(segment.tempFileURL)

        do {
            try await segment.download()
            XCTFail("expected rangeNotHonored")
        } catch DownloadError.rangeNotHonored {}
    }

    // MARK: - Failures of the moment

    /// A dropped connection costs a wait, not the download: the next request
    /// asks for exactly what's missing.
    func testADroppedConnectionResumesFromTheBytesOnDisk() async throws {
        let expected = body(20_000)
        StubRangeProtocol.reset(.init(body: expected, dropFirstRequests: 2, dropAfterBytes: 3_000))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        XCTAssertEqual(StubRangeProtocol.rangesAsked, ["bytes=0-19999", "bytes=3000-19999", "bytes=6000-19999"])
    }

    /// Only failures in a row count: a connection that keeps dropping but
    /// moves the part forward each time is allowed to finish it.
    func testAConnectionThatKeepsDroppingButProgressesStillFinishes() async throws {
        let expected = body(30_000)
        StubRangeProtocol.reset(.init(body: expected, dropFirstRequests: 25, dropAfterBytes: 1_000))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        XCTAssertGreaterThan(StubRangeProtocol.rangesAsked.count, RetryPolicy.maxConsecutiveFailures)
        XCTAssertTrue(retryLog.all.allSatisfy { $0.attempt == 1 },
                      "progress between failures should restart the count")
    }

    func testFailuresWithNothingGainedGiveUpAtTheLimit() async throws {
        let expected = body(4_096)
        StubRangeProtocol.reset(.init(body: expected, dropFirstRequests: 1_000, dropAfterBytes: 0))

        let segment = makeSegment(size: expected.count)
        do {
            try await segment.download()
            XCTFail("expected the segment to give up")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, RetryPolicy.maxConsecutiveFailures)
        XCTAssertEqual(retryLog.all.map(\.attempt), Array(1..<RetryPolicy.maxConsecutiveFailures))
    }

    func testABusyServerIsAskedAgainWhenItSays() async throws {
        let expected = body(8_000)
        StubRangeProtocol.reset(.init(body: expected, busyFirstRequests: 2, busyStatus: 503, retryAfter: "7"))

        let segment = makeSegment(size: expected.count)
        try await segment.download()

        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
        XCTAssertEqual(retryLog.all.map(\.serverAsked), [7, 7], "Retry-After should reach the wait")
    }

    func testAMissingFileIsNotAskedForAgain() async throws {
        StubRangeProtocol.reset(.init(body: body(8_000), busyFirstRequests: 1_000, busyStatus: 404))

        let segment = makeSegment(size: 8_000)
        do {
            try await segment.download()
            XCTFail("expected httpError")
        } catch DownloadError.httpError(let code) {
            XCTAssertEqual(code, 404)
        }
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, 1)
        XCTAssertTrue(retryLog.all.isEmpty)
    }

    /// A pause during the wait before a retry ends the run at once.
    func testCancelEndsARetryWaitAtOnce() async throws {
        let expected = body(20_000)
        StubRangeProtocol.reset(.init(body: expected, dropFirstRequests: 1, dropAfterBytes: 2_000))

        let segment = makeSegment(size: expected.count, retryDelay: 30)
        let run = Task { try await segment.download() }
        try await waitForBytes(segment)
        while retryLog.all.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        await segment.cancel()
        await expectCancelled(run)
        XCTAssertEqual(StubRangeProtocol.rangesAsked.count, 1, "no request after the pause")
    }

    // MARK: - Compression

    /// Even when the browser's captured headers asked for compression.
    func testEveryRequestAsksForTheFileUncompressed() async throws {
        let expected = body(8_000)
        StubRangeProtocol.reset(.init(body: expected, maxBytesPerResponse: 3_000))

        let segment = makeSegment(size: expected.count, customHeaders: ["Accept-Encoding": "gzip, deflate, br"])
        try await segment.download()

        XCTAssertEqual(StubRangeProtocol.acceptEncodings.count, 3)
        XCTAssertTrue(StubRangeProtocol.acceptEncodings.allSatisfy { $0 == "identity" },
                      "\(StubRangeProtocol.acceptEncodings)")
    }

    /// Decoded bytes of a compressed range don't sit at its offsets.
    func testACompressedRangedReplyIsRefused() async throws {
        StubRangeProtocol.reset(.init(body: body(8_000), contentEncoding: "gzip"))

        let segment = makeSegment(size: 8_000)
        do {
            try await segment.download()
            XCTFail("expected compressedReply")
        } catch DownloadError.compressedReply {}
        let downloaded = await segment.downloadedBytes
        XCTAssertEqual(downloaded, 0, "nothing from the compressed reply should be written")
    }

    func testAnIdentityCodingIsAccepted() async throws {
        let expected = body(8_000)
        StubRangeProtocol.reset(.init(body: expected, contentEncoding: "identity"))

        let segment = makeSegment(size: expected.count)
        try await segment.download()
        XCTAssertEqual(try Data(contentsOf: segment.tempFileURL), expected)
    }
}
