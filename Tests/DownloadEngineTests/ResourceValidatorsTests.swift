import XCTest
@testable import DownloadEngine

/// Which responses count as a different version, and what goes in If-Range.
final class ResourceValidatorsTests: XCTestCase {
    private func response(etag: String? = nil, lastModified: String? = nil) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        headers["ETag"] = etag
        headers["Last-Modified"] = lastModified
        return HTTPURLResponse(url: URL(string: "https://example.invalid/f")!, statusCode: 206,
                               httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private let monday = "Mon, 01 Jan 2024 00:00:00 GMT"
    private let tuesday = "Tue, 02 Jan 2024 00:00:00 GMT"

    func testTheETagDecidesWhenBothSidesHaveOne() {
        let started = ResourceValidators(etag: "\"v1\"", lastModified: monday)
        XCTAssertFalse(started.differ(from: response(etag: "\"v1\"", lastModified: tuesday)))
        XCTAssertTrue(started.differ(from: response(etag: "\"v2\"", lastModified: monday)))
    }

    func testLastModifiedDecidesWithoutAnETagOnBothSides() {
        let started = ResourceValidators(etag: "\"v1\"", lastModified: monday)
        XCTAssertTrue(started.differ(from: response(lastModified: tuesday)))
        XCTAssertFalse(started.differ(from: response(lastModified: monday)))
    }

    func testMissingValidatorsProveNothing() {
        let started = ResourceValidators(etag: "\"v1\"", lastModified: monday)
        XCTAssertFalse(started.differ(from: response()))
        XCTAssertFalse(ResourceValidators(etag: nil, lastModified: nil).differ(from: response(etag: "\"v2\"")))
    }

    func testIfRange() {
        XCTAssertEqual(ResourceValidators(etag: "\"v1\"", lastModified: monday).ifRange, "\"v1\"")
        XCTAssertNil(ResourceValidators(etag: "W/\"v1\"", lastModified: monday).ifRange)
        XCTAssertEqual(ResourceValidators(etag: nil, lastModified: monday).ifRange, monday)
        XCTAssertNil(ResourceValidators(etag: nil, lastModified: nil).ifRange)
    }
}
