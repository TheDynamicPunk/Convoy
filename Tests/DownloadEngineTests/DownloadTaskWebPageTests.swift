import XCTest
@testable import DownloadEngine

/// Pages at some addresses, the file at others, and a log of what was asked
/// for with which headers.
private final class PageServer: URLProtocol {
    struct Page {
        var headers: [String: String] = [:]
        var body = Data()
        var supportsRanges = true
    }

    struct Request { let url: String; let headers: [String: String] }

    nonisolated(unsafe) private static var pages: [String: Page] = [:]
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    nonisolated(unsafe) private static var _requests: [Request] = []
    private static let lock = NSLock()

    static var requests: [Request] { lock.withLock { _requests } }

    static func reset(pages: [String: Page], files: [String: Data]) {
        lock.withLock {
            self.pages = pages
            self.files = files
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!.absoluteString
        let (page, file) = Self.lock.withLock { () -> (Page?, Data?) in
            Self._requests.append(Request(url: url, headers: request.allHTTPHeaderFields ?? [:]))
            return (Self.pages[url], Self.files[url])
        }
        if let page {
            var headers = page.headers
            headers["Content-Type"] = headers["Content-Type"] ?? "text/html; charset=UTF-8"
            serve(page.body, ranged: page.supportsRanges, headers: headers)
        } else if let file {
            serve(file, ranged: true, headers: ["Content-Type": "application/octet-stream"])
        } else {
            reply(status: 404, headers: ["Content-Length": "0"], body: Data())
        }
    }

    private func serve(_ body: Data, ranged: Bool, headers: [String: String]) {
        var headers = headers
        var status = 200
        var slice = body
        if ranged, let range = request.value(forHTTPHeaderField: "Range"), range.hasPrefix("bytes="), !body.isEmpty {
            let bounds = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(bounds[0]) ?? 0
            let end = min(bounds.count > 1 ? (Int(bounds[1]) ?? body.count - 1) : body.count - 1, body.count - 1)
            status = 206
            slice = body.subdata(in: start ..< end + 1)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
        }
        if ranged { headers["Accept-Ranges"] = "bytes" }
        headers["Content-Length"] = "\(slice.count)"
        reply(status: status, headers: headers, body: slice)
    }

    private func reply(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Links that answer with a web page: "your download will start" pages that
/// forward to the file, pages that don't, and files served as pages.
@MainActor
final class DownloadTaskWebPageTests: XCTestCase {
    private var folder: URL!
    private let pageURL = "https://site.test/get/payload/"
    private let fileURL = "https://mirror.test/files/payload"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadTaskWebPageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        URLSessionConfiguration.testProtocolClasses = [PageServer.self]
    }

    override func tearDown() async throws {
        URLSessionConfiguration.testProtocolClasses = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func body(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ $0 / 251) % 251) })
    }

    private func html(_ head: String = "") -> Data {
        Data("<!DOCTYPE html>\n<html><head><title>Thanks!</title>\(head)</head><body>Your download will start shortly.</body></html>".utf8)
    }

    /// Names without an extension, so nothing renames the file and the
    /// shared DownloadManager stays out of it.
    private func makeTask(url: String? = nil, name: String = "payload", headers: [String: String] = [:],
                          userProvidedName: Bool = false) -> DownloadTask {
        let task = DownloadTask(
            url: URL(string: url ?? pageURL)!,
            destinationURL: folder.appendingPathComponent(name),
            originalName: name,
            customHeaders: headers,
            userProvidedDestinationName: userProvidedName
        )
        task.retryDelay = { _, _ in 0.01 }
        return task
    }

    private func assertCompleted(_ task: DownloadTask, with expected: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(task.status, .completed, "\(task.status)", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: task.destinationURL), expected, file: file, line: line)
    }

    private func assertFailedAsWebPage(_ task: DownloadTask, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed(let error) = task.status, case DownloadError.webPage? = error else {
            return XCTFail("expected a web page failure, got \(task.status)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.destinationURL.path), "nothing saved", file: file, line: line)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasPrefix(task.id.uuidString) }, "no temporary part left", file: file, line: line)
    }

    // MARK: - Pages that forward

    func testAPageWithARefreshHeaderIsFollowedToItsFile() async throws {
        let expected = body(12 << 20)
        PageServer.reset(pages: [pageURL: .init(headers: ["Refresh": "1;url=\(fileURL)"], body: html())],
                         files: [fileURL: expected])

        let task = makeTask(headers: ["Cookie": "session=1", "Referer": "https://site.test/download/"])
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertEqual(task.forwardedURL?.absoluteString, fileURL)
        let fileRequests = PageServer.requests.filter { $0.url == fileURL }
        XCTAssertGreaterThan(fileRequests.count, 1, "parts, not one request")
        XCTAssertTrue(fileRequests.allSatisfy { $0.headers["Cookie"] == nil }, "the page's cookies stay on its host")
        XCTAssertTrue(fileRequests.allSatisfy { $0.headers["Referer"] == pageURL }, "sent from the page, as a browser would")
    }

    func testAPageWithAMetaRefreshIsFollowed() async throws {
        let expected = body(300_000)
        let target = "https://site.test/files/payload?id=7&mirror=eu"
        let meta = "<meta http-equiv=\"refresh\" content=\"0; url=/files/payload?id=7&amp;mirror=eu\">"
        PageServer.reset(pages: [pageURL: .init(body: html(meta))], files: [target: expected])

        let task = makeTask(headers: ["Cookie": "session=1"])
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertEqual(PageServer.requests.last?.headers["Cookie"], "session=1", "same host, same session")
    }

    /// The page doesn't honour ranges, so the probe has the whole page
    /// before the meta refresh is read.
    func testAPageSentWholeIsFollowedToo() async throws {
        let expected = body(300_000)
        let meta = "<meta http-equiv=\"refresh\" content=\"2;url=\(fileURL)\">"
        PageServer.reset(pages: [pageURL: .init(body: html(meta), supportsRanges: false)], files: [fileURL: expected])

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
    }

    // MARK: - Pages that don't

    func testAPageThatForwardsNowhereFailsWithoutBeingSaved() async throws {
        PageServer.reset(pages: [pageURL: .init(body: html())], files: [:])

        let task = makeTask()
        try? await task.start()

        assertFailedAsWebPage(task)
    }

    func testAPageThatForwardsToItselfFailsInsteadOfLooping() async throws {
        PageServer.reset(pages: [pageURL: .init(headers: ["Refresh": "0; url=\(pageURL)"], body: html())], files: [:])

        let task = makeTask()
        try? await task.start()

        assertFailedAsWebPage(task)
        XCTAssertEqual(PageServer.requests.count, WebPageReply.maxForwards + 1)
    }

    // MARK: - Pages that are what was asked for

    func testAFileServedAsHTMLIsSavedAsTheFile() async throws {
        let expected = body(300_000)
        PageServer.reset(pages: [pageURL: .init(body: expected)], files: [:])

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertNil(task.forwardedURL)
    }

    func testAPageSavedUnderAPageNameIsKept() async throws {
        let page = html("<meta http-equiv=\"refresh\" content=\"0;url=\(fileURL)\">")
        PageServer.reset(pages: [pageURL: .init(body: page)], files: [fileURL: body(1_000)])

        let task = makeTask(name: "thanks.html", userProvidedName: true)
        try await task.start()

        try assertCompleted(task, with: page)
    }

    func testAnAttachmentServedAsHTMLIsSaved() async throws {
        let page = html()
        PageServer.reset(pages: [pageURL: .init(headers: ["Content-Disposition": "attachment"], body: page)], files: [:])

        let task = makeTask()
        try await task.start()

        try assertCompleted(task, with: page)
    }

    // MARK: - Resuming

    /// After a relaunch the task still knows where its page led, and resumes
    /// from the file rather than asking the page again.
    func testAResumeGoesStraightToTheFileThePageLedTo() async throws {
        let expected = body(300_000)
        PageServer.reset(pages: [pageURL: .init(headers: ["Refresh": "0;url=\(fileURL)"], body: html())],
                         files: [fileURL: expected])

        let task = DownloadTask(
            url: URL(string: pageURL)!,
            destinationURL: folder.appendingPathComponent("payload"),
            originalName: "payload",
            initialStatus: .paused,
            totalBytes: Int64(expected.count),
            lastValidatedAt: Date(),
            forwardedURL: URL(string: fileURL)!
        )
        task.retryDelay = { _, _ in 0.01 }
        try await task.start()

        try assertCompleted(task, with: expected)
        XCTAssertFalse(PageServer.requests.contains { $0.url == pageURL })
    }
}
