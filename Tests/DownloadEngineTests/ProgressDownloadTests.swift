import XCTest
@testable import DownloadEngine

/// Serves `body` with a Content-Length in 64 KB chunks, or fails when
/// `failure` is set.
private final class StubHelperProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var failure: URLError?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": "\(Self.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < Self.body.count {
            let end = min(offset + 64 << 10, Self.body.count)
            client?.urlProtocol(self, didLoad: Self.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ByteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(Int64, Int64?)] = []

    func append(_ received: Int64, _ expected: Int64?) { lock.withLock { entries.append((received, expected)) } }
    var all: [(Int64, Int64?)] { lock.withLock { entries } }
}

final class ProgressDownloadTests: XCTestCase {
    private var configuration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHelperProtocol.self]
        return config
    }

    override func setUp() {
        StubHelperProtocol.failure = nil
    }

    func testReportsBytesAndReturnsTheFile() async throws {
        StubHelperProtocol.body = Data((0..<(1 << 20)).map { UInt8($0 % 251) })
        let log = ByteLog()

        let (file, response) = try await ProgressDownload.run(
            URL(string: "https://example.test/yt-dlp.zip")!, configuration: configuration,
            // Spelled out rather than passed as `log.append`: a method
            // reference is never `@Sendable`, whatever its base is.
            onBytes: { log.append($0, $1) }
        )
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file), StubHelperProtocol.body)
        let last = try XCTUnwrap(log.all.last)
        XCTAssertEqual(last.0, Int64(StubHelperProtocol.body.count))
        XCTAssertEqual(last.1, Int64(StubHelperProtocol.body.count))
    }

    func testAFailedTransferThrows() async {
        StubHelperProtocol.failure = URLError(.networkConnectionLost)

        do {
            _ = try await ProgressDownload.run(
                URL(string: "https://example.test/yt-dlp.zip")!, configuration: configuration, onBytes: { _, _ in }
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
    }

    func testFractionNeedsAKnownSize() {
        let sized = HelperInstallProgress(title: "Downloading yt-dlp", step: 1, stepCount: 2,
                                          receivedBytes: 25, expectedBytes: 100)
        let unsized = HelperInstallProgress(title: "Installing yt-dlp", step: 1, stepCount: 2,
                                            receivedBytes: 0, expectedBytes: nil)
        XCTAssertEqual(sized.fraction, 0.25)
        XCTAssertNil(unsized.fraction)
    }
}
