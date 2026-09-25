import XCTest
@testable import DownloadEngine

/// Which failures are retried, how long the waits are, and what a request
/// asks for, independent of any one download path.
final class RetryPolicyTests: XCTestCase {

    // MARK: - What counts as passing

    func testDroppedAndTimedOutConnectionsAreRetried() {
        for code: URLError.Code in [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet] {
            XCTAssertTrue(RetryPolicy.isTransient(URLError(code)), "\(code)")
        }
    }

    func testFailuresThatWouldOnlyRepeatAreNot() {
        for code: URLError.Code in [.cancelled, .badURL, .serverCertificateUntrusted, .cannotDecodeRawData, .userAuthenticationRequired] {
            XCTAssertFalse(RetryPolicy.isTransient(URLError(code)), "\(code)")
        }
        XCTAssertFalse(RetryPolicy.isTransient(DownloadError.cancelled))
        XCTAssertFalse(RetryPolicy.isTransient(DownloadError.resourceChanged))
        XCTAssertFalse(RetryPolicy.isTransient(CocoaError(.fileWriteOutOfSpace)))
        XCTAssertFalse(RetryPolicy.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
    }

    func testBusyServersAreRetriedAndRefusalsAreNot() {
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(RetryPolicy.isTransient(DownloadError.httpError(status)), "\(status)")
        }
        for status in [400, 401, 403, 404, 410, 416] {
            XCTAssertFalse(RetryPolicy.isTransient(DownloadError.httpError(status)), "\(status)")
        }
    }

    func testAConnectionResetFromTheSocketIsRetried() {
        XCTAssertTrue(RetryPolicy.isTransient(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))))
    }

    /// A host DNS can't find on the first request is most likely a bad
    /// address; once the server has answered, it's the network changing.
    func testAnUnknownHostIsRetriedOnlyOnceTheServerHasAnswered() {
        let error = URLError(.cannotFindHost)
        XCTAssertFalse(RetryPolicy.isTransient(error, serverReached: false))
        XCTAssertTrue(RetryPolicy.isTransient(error, serverReached: true))
    }

    // MARK: - Waits

    func testWaitsDoubleUpToHalfAMinute() {
        let expected: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30, 30]
        for (index, base) in expected.enumerated() {
            let delay = RetryPolicy.delay(beforeRetry: index + 1)
            XCTAssertGreaterThanOrEqual(delay, base, "retry \(index + 1)")
            XCTAssertLessThanOrEqual(delay, base * 1.2, "retry \(index + 1)")
        }
    }

    func testAServersRetryAfterWinsWithinAMinute() {
        XCTAssertEqual(RetryPolicy.delay(beforeRetry: 1, serverAsked: 7), 7)
        XCTAssertEqual(RetryPolicy.delay(beforeRetry: 1, serverAsked: 3600), 60)
        XCTAssertEqual(RetryPolicy.delay(beforeRetry: 1, serverAsked: 0), 1)
    }

    func testRetryAfterReadsSecondsAndDates() {
        func response(_ value: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.test/")!, statusCode: 503,
                            httpVersion: "HTTP/1.1", headerFields: ["Retry-After": value])!
        }
        XCTAssertEqual(RetryPolicy.retryAfter(response("120")), 120)

        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let later = formatter.string(from: now.addingTimeInterval(45))
        XCTAssertEqual(RetryPolicy.retryAfter(response(later), now: now) ?? -1, 45, accuracy: 1)

        XCTAssertNil(RetryPolicy.retryAfter(response("soon")))
    }

    func testAWaitEndsAsSoonAsItIsNoLongerWanted() async {
        let started = Date()
        var checks = 0
        do {
            try await RetryPolicy.wait(30) {
                checks += 1
                return checks < 3
            }
            XCTFail("expected the wait to be cancelled")
        } catch DownloadError.cancelled {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    // MARK: - Compression

    func testARequestAsksForTheFileUncompressedWhateverWasCaptured() {
        var request = URLRequest(url: URL(string: "https://example.test/file.dmg")!)
        request.setValue("gzip, deflate, br, zstd", forHTTPHeaderField: "accept-encoding")
        ContentCoding.requestUncompressed(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testOnlyARealCodingCountsAsCompressed() {
        func response(_ coding: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.test/")!, statusCode: 206, httpVersion: "HTTP/1.1",
                            headerFields: coding.map { ["Content-Encoding": $0] } ?? [:])!
        }
        XCTAssertTrue(ContentCoding.isEncoded(response("gzip")))
        XCTAssertTrue(ContentCoding.isEncoded(response("br")))
        XCTAssertFalse(ContentCoding.isEncoded(response("identity")))
        XCTAssertFalse(ContentCoding.isEncoded(response(" Identity ")))
        XCTAssertFalse(ContentCoding.isEncoded(response("")))
        XCTAssertFalse(ContentCoding.isEncoded(response(nil)))
    }
}
