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

final class HLSParserHardeningTests: XCTestCase {
    private let base = URL(string: "https://cdn.example.com/video/index.m3u8")!

    func testRejectsNonHTTPSegmentURIFailingClosed() {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4,
        seg0.ts
        #EXTINF:4,
        file:///tmp/local.bin
        #EXTINF:4,
        seg2.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: playlist, baseURL: base))
    }

    func testRejectsNonHTTPMapAndKeyURIs() {
        let badMap = """
        #EXTM3U
        #EXT-X-MAP:URI="file:///tmp/local.bin"
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: badMap, baseURL: base))

        let badKey = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="file:///tmp/local.bin"
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: badKey, baseURL: base))
    }

    func testRejectsInvalidMediaSequenceAndByteRangeOverflow() {
        let negativeSeq = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:-1
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: negativeSeq, baseURL: base))

        let overflowSeq = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:\(Int.max)
        #EXTINF:4,
        seg0.ts
        #EXTINF:4,
        seg1.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: overflowSeq, baseURL: base))

        let overflowRange = """
        #EXTM3U
        #EXT-X-BYTERANGE:10@\(Int64.max)
        #EXTINF:4,
        seg0.m4s
        #EXT-X-ENDLIST
        """
        let parsed = HLSParser.parse(text: overflowRange, baseURL: base)
        XCTAssertNil(parsed?.segments.first?.byteRange)
    }

    func testAES128IVParsingValidatesAndLeftPads() {
        let validShortIV = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x1A
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let parsed = HLSParser.parse(text: validShortIV, baseURL: base)
        XCTAssertEqual(parsed?.encryption?.iv?.count, 16)
        XCTAssertEqual(parsed?.encryption?.iv?.last, 0x1A)
        XCTAssertEqual(parsed?.encryption?.iv?.first, 0x00)

        let oversizedIV = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00112233445566778899aabbccddeeff00
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: oversizedIV, baseURL: base))

        let invalidHexIV = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0xZZZZ
        #EXTINF:4,
        seg0.ts
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text: invalidHexIV, baseURL: base))
    }

    func testRejectsPlaylistExceedingMaxSegments() {
        var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:1"]
        lines.reserveCapacity(StreamLimits.maxSegments * 2 + 4)
        for i in 0...StreamLimits.maxSegments {
            lines.append("#EXTINF:1,")
            lines.append("s\(i).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        XCTAssertNil(HLSParser.parse(text: lines.joined(separator: "\n"), baseURL: base))
    }
}
