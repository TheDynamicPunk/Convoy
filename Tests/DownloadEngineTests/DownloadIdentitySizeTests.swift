import XCTest
@testable import DownloadEngine

/// A known size is part of what makes two downloads "the same download": two
/// files of known, different sizes are not. A missing size says nothing.
final class DownloadIdentitySizeTests: XCTestCase {
    private let clip = URL(string: "https://example.invalid/media/clip.mp4")!

    private func identity(url: URL? = nil, name: String = "Title.mp4",
                          selector: String? = nil, size: Int64? = nil) -> DownloadIdentity {
        DownloadIdentity(url: url ?? clip, name: name, youTubeFormatSelector: selector, size: size)
    }

    func testTheSameNameAtADifferentKnownSizeIsADifferentDownload() {
        let large = identity(size: 2_000_000)
        let small = identity(size: 1_000_000)
        XCTAssertFalse(large.isSameDownload(as: small))
        XCTAssertFalse(small.isSameDownload(as: large))
    }

    func testTheSameNameAtTheSameKnownSizeIsTheSameDownload() {
        XCTAssertTrue(identity(size: 1_000_000).isSameDownload(as: identity(size: 1_000_000)))
    }

    func testAMissingSizeSaysNothing() {
        let known = identity(size: 1_000_000)
        let unknown = identity()
        XCTAssertTrue(known.isSameDownload(as: unknown))
        XCTAssertTrue(unknown.isSameDownload(as: known))
    }

    func testAZeroOrNegativeSizeCountsAsUnknown() {
        XCTAssertNil(identity(size: 0).size)
        XCTAssertNil(identity(size: -1).size)
        XCTAssertTrue(identity(size: 0).isSameDownload(as: identity(size: 1_000_000)))
    }

    func testADifferentKnownSizeOverridesAMatchingURL() {
        // Without sizes, one URL with two names is the same download...
        XCTAssertTrue(identity(name: "A.mp4").isSameDownload(as: identity(name: "B.mp4")))
        // ...but not once the files are known to differ.
        XCTAssertFalse(identity(name: "A.mp4", size: 1).isSameDownload(as: identity(name: "B.mp4", size: 2)))
    }

    func testASizeNeverMakesDifferentDownloadsTheSame() {
        let other = URL(string: "https://example.invalid/media/other.mp4")!
        let a = identity(url: clip, name: "A.mp4", size: 5)
        let b = identity(url: other, name: "B.mp4", size: 5)
        XCTAssertFalse(a.isSameDownload(as: b))
    }
}
