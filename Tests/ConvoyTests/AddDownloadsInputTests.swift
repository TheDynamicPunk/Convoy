import XCTest
@testable import Convoy

final class AddDownloadsInputTests: XCTestCase {

    func testParseInputURLsAcceptsValidMagnetAndRejectsInvalidMagnet() {
        let validMagnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Ubuntu"
        let invalidMagnet = "magnet:?xt=urn:btih:not-a-valid-hash"
        let httpURL = "https://example.com/file.zip"

        let parsed = AddDownloadsView.parseInputURLs(from: """
            \(validMagnet)
            \(invalidMagnet)
            \(httpURL)
            not-a-url
            """)

        XCTAssertEqual(parsed.map(\.absoluteString), [validMagnet, httpURL])
    }
}
