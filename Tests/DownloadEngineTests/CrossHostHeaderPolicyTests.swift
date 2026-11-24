import XCTest
@testable import DownloadEngine

private final class RedirectTestServer: URLProtocol {
    enum Action {
        case redirect(to: String)
        case data(Data, contentLengthHeader: String? = nil, supportsRanges: Bool = true)
    }

    struct RecordedRequest { let url: String; let headers: [String: String] }

    nonisolated(unsafe) private static var routes: [String: Action] = [:]
    nonisolated(unsafe) private static var _requests: [RecordedRequest] = []
    private static let lock = NSLock()

    static var requests: [RecordedRequest] { lock.withLock { _requests } }

    static func reset(routes: [String: Action]) {
        lock.withLock {
            self.routes = routes
            self._requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let action = Self.lock.withLock { () -> Action? in
            Self._requests.append(RecordedRequest(url: key, headers: request.allHTTPHeaderFields ?? [:]))
            return Self.routes[key]
        }

        switch action {
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            var next = request
            next.url = URL(string: target, relativeTo: url)?.absoluteURL
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)

        case .data(let body, let contentLengthHeader, let supportsRanges):
            var headers: [String: String] = ["Content-Type": "application/octet-stream"]
            var status = 200
            var slice = body
            if supportsRanges, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), !body.isEmpty {
                let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(bounds[0]) ?? 0
                let end = min(bounds.count > 1 ? (Int(bounds[1]) ?? body.count - 1) : body.count - 1, body.count - 1)
                status = 206
                slice = body.subdata(in: start ..< end + 1)
                headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            }
            if supportsRanges { headers["Accept-Ranges"] = "bytes" }
            if let contentLengthHeader {
                if !contentLengthHeader.isEmpty { headers["Content-Length"] = contentLengthHeader }
            } else {
                headers["Content-Length"] = "\(slice.count)"
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !slice.isEmpty {
                let chunkSize = max(1, slice.count / 4)
                var offset = 0
                while offset < slice.count {
                    let end = min(offset + chunkSize, slice.count)
                    client?.urlProtocol(self, didLoad: slice.subdata(in: offset..<end))
                    offset = end
                }
            }
            client?.urlProtocolDidFinishLoading(self)

        case nil:
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

final class CrossHostHeaderPolicyTests: XCTestCase {
    func testIsHTTPOrHTTPSAndResolveHTTP() {
        let base = URL(string: "https://example.com/media/playlist.m3u8")!
        XCTAssertTrue(URL(string: "http://example.com/a")!.isHTTPOrHTTPS)
        XCTAssertTrue(URL(string: "HTTPS://EXAMPLE.COM:8443/a")!.isHTTPOrHTTPS)
        XCTAssertFalse(URL(string: "file:///tmp/local.bin")!.isHTTPOrHTTPS)
        XCTAssertFalse(URL(string: "ftp://example.com/file.bin")!.isHTTPOrHTTPS)
        XCTAssertFalse(URL(string: "http:///local/path")!.isHTTPOrHTTPS)
        XCTAssertFalse(URL(string: "https://")!.isHTTPOrHTTPS)

        XCTAssertEqual(URL.resolveHTTP("  seg0.ts \n", relativeTo: base)?.absoluteString,
                       "https://example.com/media/seg0.ts")
        XCTAssertEqual(URL.resolveHTTP("//cdn.example.com/seg0.ts", relativeTo: base)?.absoluteString,
                       "https://cdn.example.com/seg0.ts")
        XCTAssertNil(URL.resolveHTTP("", relativeTo: base))
        XCTAssertNil(URL.resolveHTTP("file:///tmp/local.bin", relativeTo: base))
        XCTAssertNil(URL.resolveHTTP("http:///no-host", relativeTo: base))
    }

    func testIsSameOrigin() {
        let httpsDefault = URL(string: "https://example.com/a")!
        let httpsExplicit = URL(string: "HTTPS://EXAMPLE.COM:443/b")!
        let httpDefault = URL(string: "http://example.com/a")!
        let httpExplicit = URL(string: "http://example.com:80/b")!
        let altPort = URL(string: "https://example.com:8443/a")!
        let subdomain = URL(string: "https://cdn.example.com/a")!

        XCTAssertTrue(CrossHostHeaderPolicy.isSameOrigin(httpsDefault, httpsExplicit))
        XCTAssertTrue(CrossHostHeaderPolicy.isSameOrigin(httpDefault, httpExplicit))
        XCTAssertFalse(CrossHostHeaderPolicy.isSameOrigin(httpsDefault, httpDefault))
        XCTAssertFalse(CrossHostHeaderPolicy.isSameOrigin(httpsDefault, altPort))
        XCTAssertFalse(CrossHostHeaderPolicy.isSameOrigin(httpsDefault, subdomain))
    }

    func testHeadersPolicyAndSanitizedRedirectRequest() {
        let origin = URL(string: "https://app.example.com/download")!
        let sameOrigin = URL(string: "https://app.example.com:443/other")!
        let crossOrigin = URL(string: "https://cdn.other.test/file")!
        let downgrade = URL(string: "http://cdn.other.test/file")!

        let headers: [String: String] = [
            "Cookie": "sid=v1",
            "Authorization": "Bearer val1",
            "X-Custom-Header": "xyz",
            "User-Agent": "Convoy/1.0",
            "Referer": "https://app.example.com/page?id=123",
            "Origin": "https://app.example.com",
        ]

        XCTAssertEqual(CrossHostHeaderPolicy.headers(headers, from: origin, to: sameOrigin), headers)

        let cross = CrossHostHeaderPolicy.headers(headers, from: origin, to: crossOrigin)
        XCTAssertNil(cross["Cookie"])
        XCTAssertNil(cross["Authorization"])
        XCTAssertNil(cross["X-Custom-Header"])
        XCTAssertEqual(cross["User-Agent"], "Convoy/1.0")
        XCTAssertEqual(cross["Referer"], "https://app.example.com/page?id=123")

        let down = CrossHostHeaderPolicy.headers(headers, from: origin, to: downgrade)
        XCTAssertNil(down["Cookie"])
        XCTAssertNil(down["Referer"])

        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        XCTAssertNil(CrossHostHeaderPolicy.sanitizedRedirectRequest(from: response, to: URLRequest(url: URL(string: "file:///tmp/local.bin")!)))

        var crossReq = URLRequest(url: crossOrigin)
        crossReq.setValue("sid=1", forHTTPHeaderField: "Cookie")
        crossReq.setValue("Bearer abc", forHTTPHeaderField: "Authorization")
        crossReq.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        crossReq.setValue("\"etag-1\"", forHTTPHeaderField: "If-Range")
        crossReq.setValue("https://app.example.com/download", forHTTPHeaderField: "Referer")

        let sanitized = CrossHostHeaderPolicy.sanitizedRedirectRequest(from: response, to: crossReq)
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sanitized?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(sanitized?.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
        XCTAssertEqual(sanitized?.value(forHTTPHeaderField: "If-Range"), "\"etag-1\"")
        XCTAssertEqual(sanitized?.value(forHTTPHeaderField: "Referer"), "https://app.example.com/download")

        var downgradeReq = crossReq
        downgradeReq.url = downgrade
        let sanitizedDown = CrossHostHeaderPolicy.sanitizedRedirectRequest(from: response, to: downgradeReq)
        XCTAssertNil(sanitizedDown?.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(sanitizedDown?.value(forHTTPHeaderField: "Cookie"))
    }
}

@MainActor
final class RedirectAndBoundedFetchTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RedirectAndBoundedFetchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        URLSessionConfiguration.testProtocolClasses = [RedirectTestServer.self]
    }

    override func tearDown() async throws {
        URLSessionConfiguration.testProtocolClasses = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testBoundedFetchEnforcesContentLengthAndChunkedLimits() async {
        let keyURL = URL(string: "https://keys.test/key.bin")!
        let streamURL = URL(string: "https://streams.test/huge.m3u8")!
        RedirectTestServer.reset(routes: [
            keyURL.absoluteString: .data(Data(repeating: 0xAA, count: 2048), contentLengthHeader: "2048", supportsRanges: false),
            streamURL.absoluteString: .data(Data(repeating: 0x41, count: 4096), contentLengthHeader: "", supportsRanges: false),
        ])

        do {
            _ = try await BoundedFetchSession.shared.data(for: URLRequest(url: keyURL), maxBytes: 1024, limitError: StreamDownloadError.invalidEncryptionKey)
            XCTFail("Expected invalidEncryptionKey")
        } catch StreamDownloadError.invalidEncryptionKey {} catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await BoundedFetchSession.shared.data(for: URLRequest(url: streamURL), maxBytes: 1024, limitError: StreamDownloadError.manifestTooLarge)
            XCTFail("Expected manifestTooLarge")
        } catch StreamDownloadError.manifestTooLarge {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDownloadTaskStripsCredentialsAfterCrossOriginRedirectAndFreshHeaders() async throws {
        let originURL = "https://private.example.test/download/archive"
        let cdnURL = "https://cdn.thirdparty.test/blobs/archive"
        let payload = Data((0..<200_000).map { UInt8($0 & 0xFF) })

        RedirectTestServer.reset(routes: [
            originURL: .redirect(to: cdnURL),
            cdnURL: .data(payload, supportsRanges: true),
        ])

        let task = DownloadTask(
            url: URL(string: originURL)!,
            destinationURL: folder.appendingPathComponent("archive"),
            originalName: "archive",
            customHeaders: [
                "Cookie": "sid=val1",
                "Authorization": "Bearer val2",
                "X-Custom-Header": "val3",
                "User-Agent": "ConvoyTest/1.0",
            ],
            userProvidedDestinationName: true
        )
        task.retryDelay = { _, _ in 0.01 }

        try await task.start()

        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), payload)

        let cdnRequests = RedirectTestServer.requests.filter { $0.url == cdnURL }
        XCTAssertGreaterThanOrEqual(cdnRequests.count, 2, "Expected both redirected probe and segment request(s) to hit CDN")
        for req in cdnRequests {
            XCTAssertNil(req.headers["Cookie"])
            XCTAssertNil(req.headers["Authorization"])
            XCTAssertNil(req.headers["X-Custom-Header"])
            XCTAssertEqual(req.headers["User-Agent"], "ConvoyTest/1.0")
        }

        task.applyFreshHeaders([
            "Cookie": "sid=new",
            "Authorization": "Bearer new",
            "User-Agent": "ConvoyTest/2.0",
        ])
        XCTAssertNil(task.effectiveHeaders["Cookie"])
        XCTAssertNil(task.effectiveHeaders["Authorization"])
        XCTAssertEqual(task.effectiveHeaders["User-Agent"], "ConvoyTest/2.0")
    }
}