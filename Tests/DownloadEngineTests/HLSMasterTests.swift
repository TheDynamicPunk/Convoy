import XCTest
@testable import DownloadEngine

final class HLSMasterTests: XCTestCase {
    private let base = URL(string: "https://cdn.example.com/v/720P.mp4/master.m3u8?h=x")!

    func testSingleVariantMasterResolvesRelativeURI() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=2438046,RESOLUTION=1280x720,CODECS="avc1.640028,mp4a.40.2"
        index-v1-a1.m3u8?t=1
        """
        let variants = HLSParser.parseMaster(text: text, baseURL: base)
        XCTAssertEqual(variants?.count, 1)
        XCTAssertEqual(variants?.first?.url.absoluteString, "https://cdn.example.com/v/720P.mp4/index-v1-a1.m3u8?t=1")
        XCTAssertEqual(variants?.first?.bandwidth, 2438046)
        XCTAssertNil(HLSParser.parse(text: text, baseURL: base))
    }

    func testAudioGroupIsAttachedToItsVariant() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="en",DEFAULT=YES,URI="a/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="aud"
        low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=4000000
        high.m3u8
        """
        let variants = HLSParser.parseMaster(text: text, baseURL: base)!
        XCTAssertEqual(variants.map(\.bandwidth), [800000, 4000000])
        XCTAssertEqual(variants[0].audio.first?.url.absoluteString, "https://cdn.example.com/v/720P.mp4/a/en.m3u8")
        XCTAssertTrue(variants[1].audio.isEmpty)
    }

    func testMediaPlaylistIsNotAMaster() {
        let text = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nseg-1.m4s\n#EXT-X-ENDLIST"
        XCTAssertNil(HLSParser.parseMaster(text: text, baseURL: base))
    }
}
