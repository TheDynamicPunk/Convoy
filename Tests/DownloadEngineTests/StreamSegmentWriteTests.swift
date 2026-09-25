import XCTest
@testable import DownloadEngine

/// Serves `StubSegmentProtocol.chunks` as a 2xx body, one `didLoad` per chunk,
/// or `StubSegmentProtocol.status` with no body when it isn't 2xx.
private final class StubSegmentProtocol: URLProtocol {
    nonisolated(unsafe) static var chunks: [Data] = []
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var headers: [String: String] = [:]
    /// The first this-many requests lose the connection after one chunk.
    nonisolated(unsafe) static var dropFirstRequests = 0
    /// The first this-many requests are answered 503.
    nonisolated(unsafe) static var busyFirstRequests = 0
    /// Requests send their first chunk, then go quiet until cancelled.
    nonisolated(unsafe) static var stallAfterFirstChunk = false
    nonisolated(unsafe) static var acceptEncodings: [String?] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            chunks = []
            status = 200
            headers = [:]
            dropFirstRequests = 0
            busyFirstRequests = 0
            stallAfterFirstChunk = false
            acceptEncodings = []
            requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (busy, drop) = Self.lock.withLock { () -> (Bool, Bool) in
            Self.requestCount += 1
            Self.acceptEncodings.append(request.value(forHTTPHeaderField: "Accept-Encoding"))
            if Self.busyFirstRequests > 0 { Self.busyFirstRequests -= 1; return (true, false) }
            if Self.dropFirstRequests > 0 { Self.dropFirstRequests -= 1; return (false, true) }
            return (false, false)
        }
        let status = busy ? 503 : Self.status
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard (200...299).contains(status) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if drop {
            if let first = Self.chunks.first { client?.urlProtocol(self, didLoad: first) }
            // A moment later, as on a real connection.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        if Self.stallAfterFirstChunk {
            if let first = Self.chunks.first { client?.urlProtocol(self, didLoad: first) }
            return
        }
        for chunk in Self.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class StreamSegmentWriteTests: XCTestCase {
    private var tempDir: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamSegmentWriteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubSegmentProtocol.self]
        session = URLSession(configuration: config, delegate: StreamSegmentSessionDelegate(), delegateQueue: nil)
        StubSegmentProtocol.reset()
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testManySmallChunksAreWrittenInOrder() async throws {
        let chunks = (0..<2000).map { i in Data("\(i),".utf8) }
        StubSegmentProtocol.chunks = chunks

        let seg = StreamSegment(index: 0, url: URL(string: "https://example.test/seg0.ts")!,
                                tempDir: tempDir, headers: [:])
        try await seg.download(session: session)

        let written = try Data(contentsOf: await seg.tempFileURL)
        XCTAssertEqual(written, chunks.reduce(Data(), +))
        try await seg.markComplete()
        let isComplete = await seg.isComplete
        XCTAssertTrue(isComplete)
    }

    /// Bytes of a request still running are counted, so a stream's row moves
    /// between finished pieces; they leave the count when it ends.
    func testBytesStillArrivingAreCountedUntilTheRequestEnds() async throws {
        StubSegmentProtocol.chunks = [Data(count: 1000), Data(count: 1000)]
        StubSegmentProtocol.stallAfterFirstChunk = true
        let delegate = try XCTUnwrap(session.delegate as? StreamSegmentSessionDelegate)
        let seg = StreamSegment(index: 0, url: URL(string: "https://example.test/seg0.ts")!,
                                tempDir: tempDir, headers: [:])
        let session = session!
        let download = Task { try await seg.download(session: session) }

        let deadline = Date().addingTimeInterval(5)
        while delegate.inFlightBytes < 1000, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(delegate.inFlightBytes, 1000)

        delegate.close()
        session.invalidateAndCancel()
        _ = await download.result
        XCTAssertEqual(delegate.inFlightBytes, 0)
    }

    func testBodyPastSpillThresholdIsWrittenInOrder() async throws {
        let chunkSize = 256 << 10
        let count = StreamSegmentSessionDelegate.spillThreshold / chunkSize * 2 + 3
        let chunks = (0..<count).map { i in Data(repeating: UInt8(i % 251), count: chunkSize) }
        StubSegmentProtocol.chunks = chunks

        let seg = StreamSegment(index: 2, url: URL(string: "https://example.test/whole.mp4")!,
                                tempDir: tempDir, headers: [:])
        try await seg.download(session: session)

        let written = try Data(contentsOf: await seg.tempFileURL)
        XCTAssertEqual(written.count, chunkSize * count)
        XCTAssertEqual(written, chunks.reduce(into: Data()) { $0.append($1) })
    }

    /// A pause invalidates the session; a segment scheduled just before must
    /// not create a task on it (an Objective-C exception, i.e. a crash).
    func testSegmentStartingAfterPauseIsCancelled() async throws {
        (session.delegate as! StreamSegmentSessionDelegate).close()
        session.invalidateAndCancel()

        let seg = StreamSegment(index: 3, url: URL(string: "https://example.test/seg3.ts")!,
                                tempDir: tempDir, headers: [:])
        do {
            try await seg.download(session: session)
            XCTFail("expected cancelled")
        } catch DownloadError.cancelled {}
    }

    func testHTTPErrorThrowsAndLeavesNoFile() async throws {
        StubSegmentProtocol.status = 404

        let seg = StreamSegment(index: 1, url: URL(string: "https://example.test/seg1.ts")!,
                                tempDir: tempDir, headers: [:])
        do {
            try await seg.download(session: session)
            XCTFail("expected httpError")
        } catch DownloadError.httpError(let code) {
            XCTAssertEqual(code, 404)
        }
        let path = await seg.tempFileURL.path
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - Failures of the moment

    private func segment(_ index: Int, byteRange: HLSByteRange? = nil) -> StreamSegment {
        StreamSegment(index: index, url: URL(string: "https://example.test/seg\(index).ts")!,
                      tempDir: tempDir, headers: ["Accept-Encoding": "gzip"], byteRange: byteRange,
                      retryDelay: { _, _ in 0.01 })
    }

    /// One dropped segment would otherwise end a stream of hundreds.
    func testADroppedSegmentIsFetchedAgainWhole() async throws {
        let chunks = (0..<50).map { i in Data("\(i),".utf8) }
        StubSegmentProtocol.chunks = chunks
        StubSegmentProtocol.dropFirstRequests = 2

        let seg = segment(4)
        try await seg.download(session: session)

        let file = await seg.tempFileURL
        XCTAssertEqual(try Data(contentsOf: file), chunks.reduce(Data(), +),
                       "a retry replaces the partial body, never follows it")
        XCTAssertEqual(StubSegmentProtocol.requestCount, 3)
    }

    func testABusyServerIsAskedAgain() async throws {
        StubSegmentProtocol.chunks = [Data("ok".utf8)]
        StubSegmentProtocol.busyFirstRequests = 3

        let seg = segment(5)
        try await seg.download(session: session)

        let file = await seg.tempFileURL
        XCTAssertEqual(try Data(contentsOf: file), Data("ok".utf8))
        XCTAssertEqual(StubSegmentProtocol.requestCount, 4)
    }

    func testASegmentThatNeverArrivesGivesUpAtTheLimit() async throws {
        StubSegmentProtocol.chunks = [Data("x".utf8)]
        StubSegmentProtocol.dropFirstRequests = 1_000

        let seg = segment(6)
        do {
            try await seg.download(session: session)
            XCTFail("expected the segment to give up")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(StubSegmentProtocol.requestCount, RetryPolicy.maxConsecutiveFailures)
    }

    /// Pausing closes the delegate; a segment waiting to retry stops at once.
    func testAPauseEndsARetryWait() async throws {
        StubSegmentProtocol.chunks = [Data("x".utf8)]
        StubSegmentProtocol.dropFirstRequests = 1

        let seg = StreamSegment(index: 7, url: URL(string: "https://example.test/seg7.ts")!,
                                tempDir: tempDir, headers: [:], retryDelay: { _, _ in 30 })
        let session = self.session!
        let run = Task { try await seg.download(session: session) }
        try await Task.sleep(nanoseconds: 300_000_000)
        (session.delegate as! StreamSegmentSessionDelegate).close()

        let started = Date()
        do {
            try await run.value
            XCTFail("expected cancelled")
        } catch DownloadError.cancelled {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(StubSegmentProtocol.requestCount, 1)
    }

    // MARK: - Compression

    func testASegmentAsksForItsBytesUncompressed() async throws {
        StubSegmentProtocol.chunks = [Data("ok".utf8)]

        try await segment(8).download(session: session)
        XCTAssertEqual(StubSegmentProtocol.acceptEncodings, ["identity"])
    }

    /// A slice of a compressed file can't be decoded on its own.
    func testACompressedByteRangeIsRefused() async throws {
        StubSegmentProtocol.chunks = [Data("slice".utf8)]
        StubSegmentProtocol.status = 206
        StubSegmentProtocol.headers = ["Content-Range": "bytes 100-104/1000", "Content-Encoding": "gzip"]

        let seg = segment(9, byteRange: HLSByteRange(start: 100, length: 5))
        do {
            try await seg.download(session: session)
            XCTFail("expected compressedReply")
        } catch DownloadError.compressedReply {}
        XCTAssertEqual(StubSegmentProtocol.requestCount, 1)
    }
}
