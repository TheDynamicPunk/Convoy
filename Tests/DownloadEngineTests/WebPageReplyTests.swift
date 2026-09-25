import XCTest
@testable import DownloadEngine

/// Telling a page from a file, and reading where a page forwards to.
final class WebPageReplyTests: XCTestCase {
    private let page = URL(string: "https://site.test/get/file.dmg/")!

    private func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: page, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - Page or file

    func testHTMLIsAPageUnlessOfferedAsAnAttachment() {
        XCTAssertTrue(WebPageReply.isPage(response(["Content-Type": "text/html; charset=UTF-8"])))
        XCTAssertTrue(WebPageReply.isPage(response(["Content-Type": "TEXT/HTML", "Content-Disposition": "inline"])))
        XCTAssertFalse(WebPageReply.isPage(response(["Content-Type": "text/html", "Content-Disposition": "attachment; filename=\"a.html\""])))
        XCTAssertFalse(WebPageReply.isPage(response(["Content-Type": "application/octet-stream"])))
        XCTAssertFalse(WebPageReply.isPage(response([:])))
    }

    func testOnlyHTMLNamesArePageNames() {
        for name in ["index.html", "Page.HTM", "a.xhtml", "b.shtml"] { XCTAssertTrue(WebPageReply.isPageName(name), name) }
        for name in ["file.dmg", "thanks", "download.php", "example.com"] { XCTAssertFalse(WebPageReply.isPageName(name), name) }
    }

    func testHTMLIsRecognisedFromItsFirstBytes() {
        for text in ["<!DOCTYPE html>", "\u{FEFF}\n  <html lang=\"en\">", "<HEAD>", "<!-- note -->", "<meta charset=utf-8>", "<p>Not found</p>"] {
            XCTAssertTrue(WebPageReply.looksLikeHTML(Data(text.utf8)), text)
        }
        XCTAssertFalse(WebPageReply.looksLikeHTML(Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])), "zip")
        XCTAssertFalse(WebPageReply.looksLikeHTML(Data("<htmlx>".utf8)))
        XCTAssertFalse(WebPageReply.looksLikeHTML(Data("{\"ok\":true}".utf8)))
        XCTAssertFalse(WebPageReply.looksLikeHTML(Data()))
    }

    // MARK: - Refresh values

    func testRefreshValuesInTheFormsBrowsersAccept() {
        let expected = "https://mirror.test/files/file.dmg"
        for value in ["1;url=https://mirror.test/files/file.dmg",
                      "0; URL=https://mirror.test/files/file.dmg",
                      "5, url = 'https://mirror.test/files/file.dmg'",
                      "3 url=\"https://mirror.test/files/file.dmg\"",
                      "0.5;https://mirror.test/files/file.dmg"] {
            XCTAssertEqual(WebPageReply.refreshTarget(value, page: page)?.absoluteString, expected, value)
        }
    }

    func testARelativeRefreshResolvesAgainstThePage() {
        XCTAssertEqual(WebPageReply.refreshTarget("0;url=/files/file.dmg", page: page)?.absoluteString,
                       "https://site.test/files/file.dmg")
        XCTAssertEqual(WebPageReply.refreshTarget("0;url=next", page: page)?.absoluteString,
                       "https://site.test/get/file.dmg/next")
    }

    func testARefreshOfThePageItselfOrOffTheWebIsNoForward() {
        XCTAssertNil(WebPageReply.refreshTarget("30", page: page))
        XCTAssertNil(WebPageReply.refreshTarget("", page: page))
        XCTAssertNil(WebPageReply.refreshTarget("soon; url=https://mirror.test/a", page: page))
        XCTAssertNil(WebPageReply.refreshTarget("0; url=javascript:alert(1)", page: page))
        XCTAssertNil(WebPageReply.refreshTarget("0; url=ftp://mirror.test/a", page: page))
    }

    // MARK: - Meta refresh

    func testTheMetaRefreshIsFoundWhateverTheAttributeOrderOrQuoting() {
        let html = """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width">
        <META CONTENT='3; URL=https://mirror.test/get?id=7&amp;mirror=eu' HTTP-EQUIV=Refresh>
        </head><body>Thanks!</body></html>
        """
        let content = WebPageReply.metaRefresh(in: Data(html.utf8))
        XCTAssertEqual(content, "3; URL=https://mirror.test/get?id=7&mirror=eu")
        XCTAssertEqual(content.flatMap { WebPageReply.refreshTarget($0, page: page) }?.absoluteString,
                       "https://mirror.test/get?id=7&mirror=eu")
    }

    func testAPageWithoutAMetaRefreshHasNone() {
        let html = "<html><head><meta http-equiv=\"content-type\" content=\"text/html\"></head></html>"
        XCTAssertNil(WebPageReply.metaRefresh(in: Data(html.utf8)))
    }
}
