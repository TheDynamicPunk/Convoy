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
}
