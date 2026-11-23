import XCTest
import DownloadEngine
@testable import Convoy

final class NumericSettingRowTests: XCTestCase {

    func testAValueInsideTheRangeIsKept() {
        let ports = TorrentHelperConfig.listenPortRange
        XCTAssertEqual(NumericSettingRow.clamped(51413, to: ports), 51413)
        XCTAssertEqual(NumericSettingRow.clamped(ports.lowerBound, to: ports), ports.lowerBound)
        XCTAssertEqual(NumericSettingRow.clamped(ports.upperBound, to: ports), ports.upperBound)
    }

    func testAValueOutsideTheRangeLandsOnTheNearestEnd() {
        let ports = TorrentHelperConfig.listenPortRange
        XCTAssertEqual(NumericSettingRow.clamped(0, to: ports), ports.lowerBound)
        XCTAssertEqual(NumericSettingRow.clamped(-5, to: ports), ports.lowerBound)
        XCTAssertEqual(NumericSettingRow.clamped(ports.upperBound + 1, to: ports), ports.upperBound)
    }

    func testTheUploadLimitRangeKeepsZeroAndStopsAtWhatRqbitAccepts() {
        let limits = 0...TorrentHelperConfig.maxUploadLimitKBps
        XCTAssertEqual(NumericSettingRow.clamped(0, to: limits), 0)
        XCTAssertEqual(NumericSettingRow.clamped(-1, to: limits), 0)
        XCTAssertEqual(NumericSettingRow.clamped(limits.upperBound + 1, to: limits), limits.upperBound)
    }
}
