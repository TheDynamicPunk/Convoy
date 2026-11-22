import XCTest
@testable import Convoy

final class NumericSettingRowTests: XCTestCase {

    func testAValueInsideTheRangeIsKept() {
        XCTAssertEqual(NumericSettingRow.clamped(6881, to: 1024...65535), 6881)
        XCTAssertEqual(NumericSettingRow.clamped(1024, to: 1024...65535), 1024)
        XCTAssertEqual(NumericSettingRow.clamped(65535, to: 1024...65535), 65535)
    }

    func testAValueOutsideTheRangeLandsOnTheNearestEnd() {
        XCTAssertEqual(NumericSettingRow.clamped(0, to: 1024...65535), 1024)
        XCTAssertEqual(NumericSettingRow.clamped(-5, to: 1024...65535), 1024)
        XCTAssertEqual(NumericSettingRow.clamped(70_000, to: 1024...65535), 65535)
    }

    func testAZeroBasedRangeKeepsZero() {
        XCTAssertEqual(NumericSettingRow.clamped(0, to: 0...10_000_000), 0)
        XCTAssertEqual(NumericSettingRow.clamped(-1, to: 0...10_000_000), 0)
    }
}
