import XCTest
@testable import DownloadEngine

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
        StubHelperProtocol.reset()
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
