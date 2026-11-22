import XCTest
@testable import DownloadEngine

final class TorrentHelperConfigTests: XCTestCase {

    func testThePeerPortRangeStaysClearOfPrivilegedPortsAndFitsAUInt16() {
        XCTAssertEqual(TorrentHelperConfig.listenPortRange.lowerBound, 1024)
        XCTAssertLessThanOrEqual(TorrentHelperConfig.listenPortRange.upperBound, Int(UInt16.max))
    }

    func testFixedPortTreatsZeroAndOutOfRangeAsRandom() {
        XCTAssertNil(TorrentHelperConfig.fixedPort(from: 0))
        XCTAssertNil(TorrentHelperConfig.fixedPort(from: 80))
        XCTAssertNil(TorrentHelperConfig.fixedPort(from: 70_000))
        XCTAssertEqual(TorrentHelperConfig.fixedPort(from: 51413), 51413)
    }

    func testUploadBytesPerSecondClampsToRqbitUInt32Cap() {
        XCTAssertNil(TorrentHelperConfig.uploadBytesPerSecond(forKBps: 0))
        XCTAssertNil(TorrentHelperConfig.uploadBytesPerSecond(forKBps: -10))
        XCTAssertEqual(TorrentHelperConfig.uploadBytesPerSecond(forKBps: 500), 500 * 1024)
        let capped = TorrentHelperConfig.uploadBytesPerSecond(forKBps: TorrentHelperConfig.maxUploadLimitKBps + 5_000)
        XCTAssertEqual(capped, TorrentHelperConfig.maxUploadLimitKBps * 1024)
        XCTAssertLessThanOrEqual(capped ?? 0, Int(UInt32.max))
    }
}
