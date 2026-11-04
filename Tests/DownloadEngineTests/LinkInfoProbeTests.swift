import XCTest
@testable import DownloadEngine

/// What the capture review window learns about a link from its response
/// headers: size, a name, and whether it can be resumed.
final class LinkInfoProbeTests: XCTestCase {
    private let file = URL(string: "https://cdn.test/releases/app-1.2.dmg")!

    private func response(_ status: Int = 200, url: URL? = nil, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url ?? file, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func testSizeComesFromContentRangeOnA206() {
        let info = LinkInfoProbe.interpret(response(206, ["Content-Range": "bytes 0-0/734003200", "Content-Length": "1"]))
        XCTAssertEqual(info.size, 734_003_200)
    }

    func testSizeComesFromContentLengthOnA200() {
        let info = LinkInfoProbe.interpret(response(200, ["Content-Length": "5120"]))
        XCTAssertEqual(info.size, 5120)
    }

    func testUnknownTotalAndMissingLengthLeaveSizeNil() {
        XCTAssertNil(LinkInfoProbe.interpret(response(206, ["Content-Range": "bytes 0-0/*"])).size)
        XCTAssertNil(LinkInfoProbe.interpret(response(200, [:])).size)
    }

    func testACompressedReplyHasNoSize() {
        // Content-Length of a compressed reply counts compressed bytes, not the
        // file's, so it must not be shown as the file's size.
        let info = LinkInfoProbe.interpret(response(200, ["Content-Length": "900", "Content-Encoding": "gzip"]))
        XCTAssertNil(info.size)
    }

    func testNamePrefersContentDispositionOverTheURL() {
        let info = LinkInfoProbe.interpret(response(200, [
            "Content-Disposition": "attachment; filename=\"Real Name.zip\"",
        ]))
        XCTAssertEqual(info.suggestedFilename, "Real Name.zip")
    }

    func testNameFallsBackToTheResolvedURLOnlyWhenItHasAnExtension() {
        XCTAssertEqual(LinkInfoProbe.interpret(response(200, [:])).suggestedFilename, "app-1.2.dmg")
        let bare = URL(string: "https://cdn.test/latest/darwin-arm64")!
        XCTAssertNil(LinkInfoProbe.interpret(response(200, url: bare, [:])).suggestedFilename)
    }

    func testMIMETypeLosesItsParametersAndCase() {
        let info = LinkInfoProbe.interpret(response(200, ["Content-Type": "Video/MP4; codecs=avc1"]))
        XCTAssertEqual(info.mimeType, "video/mp4")
    }

    func testAnHTMLReplyIsAPage() {
        XCTAssertTrue(LinkInfoProbe.interpret(response(200, ["Content-Type": "text/html"])).isWebPage)
        XCTAssertFalse(LinkInfoProbe.interpret(response(200, ["Content-Type": "application/zip"])).isWebPage)
    }
}
