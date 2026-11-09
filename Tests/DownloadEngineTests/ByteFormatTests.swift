import XCTest
@testable import DownloadEngine

/// The one place byte counts become text. These pin the convention (decimal,
/// the way Finder counts) so a screen can't drift back to its own.
final class ByteFormatTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private func size(_ bytes: Int64, in units: ByteCountFormatStyle.Units = .all) -> String {
        ByteFormat.size(bytes, in: units, locale: us)
    }

    // MARK: - size

    func testCountsInThousandsLikeFinder() {
        XCTAssertEqual(size(1_000), "1 KB")
        XCTAssertEqual(size(1_500_000), "1.5 MB")
        XCTAssertEqual(size(1_073_741_824), "1.07 GB")
    }

    func testDoesNotCountInBinaryUnits() {
        // Exactly 1 MiB. The old per-screen loops called this "1.0 MB"; Finder
        // and now every screen call it 1.05 MB.
        XCTAssertEqual(size(1_048_576), "1.05 MB")
    }

    func testSmallValuesStayInBytes() {
        XCTAssertEqual(size(999), "999 bytes")
    }

    func testASingleByteIsSingular() {
        XCTAssertEqual(size(1), "1 byte")
    }

    func testThreeSignificantDigits() {
        XCTAssertEqual(size(1_234_000), "1.23 MB")
        XCTAssertEqual(size(12_340_000), "12.3 MB")
        XCTAssertEqual(size(123_400_000), "123 MB")
    }

    func testRoundsUpIntoTheNextUnitInsteadOfReadingOneThousand() {
        XCTAssertEqual(size(999_400), "999 KB")
        XCTAssertEqual(size(999_999), "1 MB")
    }

    func testUsesTheLocalesDecimalSeparator() {
        XCTAssertEqual(ByteFormat.size(1_048_576, locale: Locale(identifier: "de_DE")), "1,05 MB")
    }

    func testZeroReadsAsAFigureNotWords() {
        let zero = size(0)
        XCTAssertFalse(zero.contains("Zero"), zero)
        XCTAssertTrue(zero.hasPrefix("0"), zero)
    }

    // MARK: - Limiting the units

    func testAGBAndMBOnlyFigureUsesMBBelowAGigabyte() {
        XCTAssertEqual(size(500_000_000, in: [.gb, .mb]), "500 MB")
    }

    func testAGBAndMBOnlyFigureUsesGBAboveIt() {
        XCTAssertEqual(size(1_500_000_000, in: [.gb, .mb]), "1.5 GB")
    }

    func testZeroInMBOnlyIsAFigureInMB() {
        // What Settings asks for at zero, so the row never reads "Zero KB".
        let zero = size(0, in: .mb)
        XCTAssertFalse(zero.contains("Zero"), zero)
        XCTAssertTrue(zero.hasPrefix("0"), zero)
        XCTAssertTrue(zero.contains("MB"), zero)
    }

    // MARK: - speed

    func testSpeedIsASizePerSecond() {
        XCTAssertEqual(ByteFormat.speed(1_500_000, locale: us), "1.5 MB/s")
    }

    func testSpeedAtZeroStillEndsInPerSecond() {
        XCTAssertTrue(ByteFormat.speed(0, locale: us).hasSuffix("/s"))
    }

    // MARK: - Fixed digits

    private func fixed(_ bytes: Int64, in units: ByteCountFormatStyle.Units = .all) -> String {
        ByteFormat.size(bytes, in: units, digits: .fixed, locale: us)
    }

    func testFixedAlwaysHasExactlyOneDecimal() {
        XCTAssertEqual(fixed(304_000_000), "304.0 MB", "a whole number keeps its .0")
        XCTAssertEqual(fixed(304_200_000), "304.2 MB")
        XCTAssertEqual(fixed(2_000_000_000), "2.0 GB")
        XCTAssertEqual(fixed(12_000), "12.0 KB")
        XCTAssertEqual(fixed(512), "512.0 B")
        XCTAssertEqual(fixed(0), "0.0 B")
    }

    func testFixedCountsInThousandsLikeFinderNotInBinary() {
        XCTAssertEqual(fixed(1_500_000), "1.5 MB")
        XCTAssertEqual(fixed(1_073_741_824), "1.1 GB")
    }

    func testFixedRollsIntoTheNextUnitInsteadOfReadingOneThousand() {
        XCTAssertEqual(fixed(999_949), "999.9 KB")
        XCTAssertEqual(fixed(999_950), "1.0 MB")
    }

    func testFixedKeepsItsLengthWhereverTheValueLandsInAUnit() {
        // 100 MB to 999 MB, whole numbers included.
        let lengths = Set(stride(from: Int64(100_000_000), to: 999_000_000, by: 777_777).map { fixed($0).count })
        XCTAssertEqual(lengths, [8])
        XCTAssertEqual(fixed(304_000_000).count, fixed(304_100_000).count)
    }

    func testFixedHonoursTheUnitLimit() {
        XCTAssertEqual(fixed(500_000_000, in: [.gb, .mb]), "500.0 MB")
        XCTAssertEqual(fixed(1_500_000_000, in: [.gb, .mb]), "1.5 GB")
        XCTAssertEqual(fixed(0, in: .mb), "0.0 MB")
    }

    func testFixedSpeedIsAFixedSizePerSecond() {
        XCTAssertEqual(ByteFormat.speed(12_000_000, digits: .fixed, locale: us), "12.0 MB/s")
        XCTAssertEqual(ByteFormat.speed(512, digits: .fixed, locale: us), "512.0 B/s")
    }
}
