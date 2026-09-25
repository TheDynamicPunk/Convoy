import XCTest
@testable import DownloadEngine

/// What the join is allowed to produce, and what it must refuse.
///
/// The bug these pin down: the old join opened each part with `try?` and
/// skipped one it couldn't read, copied a short part and carried on — putting
/// every byte after it at the wrong offset — and never measured the result.
/// The download was marked completed either way. It also deleted each part as
/// it copied it, so anything that went wrong took the download with it.
final class SegmentMergeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentMergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var scratch: URL { dir.appendingPathComponent(".join-scratch") }

    /// Writes a part file holding `size` bytes of `filler`, plus any `surplus`
    /// bytes past the range it owns, and returns what the join should read.
    @discardableResult
    private func writePart(_ index: Int, size: Int, filler: UInt8, surplus: Int = 0) throws -> Data {
        let owned = Data(repeating: filler, count: size)
        let file = dir.appendingPathComponent("part-\(index)")
        try (owned + Data(repeating: 0xEE, count: surplus)).write(to: file)
        return owned
    }

    private func part(_ index: Int, size: Int) -> SegmentMerge.Part {
        SegmentMerge.Part(index: index, url: dir.appendingPathComponent("part-\(index)"),
                          size: Int64(size))
    }

    private func partsExist(_ indices: Int...) -> Bool {
        indices.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("part-\($0)").path)
        }
    }

    // MARK: - A good join

    func testPartsAreJoinedInIndexOrder() async throws {
        let a = try writePart(0, size: 4_000, filler: 1)
        let b = try writePart(1, size: 4_000, filler: 2)
        let c = try writePart(2, size: 2_000, filler: 3)

        try await SegmentMerge.join([part(0, size: 4_000), part(1, size: 4_000), part(2, size: 2_000)],
                                    into: scratch, expectedTotal: 10_000)

        XCTAssertEqual(try Data(contentsOf: scratch), a + b + c)
    }

    /// Part 0's file is also the streaming probe's scratch file, and the probe
    /// can overshoot the range part 0 owns.
    func testSurplusBytesPastAPartsRangeAreNotCopied() throws {
        let a = try writePart(0, size: 1_000, filler: 1, surplus: 500)
        let b = try writePart(1, size: 1_000, filler: 2)

        try SegmentMerge.joinNow([part(0, size: 1_000), part(1, size: 1_000)],
                                 into: scratch, expectedTotal: 2_000)

        XCTAssertEqual(try Data(contentsOf: scratch), a + b)
    }

    // MARK: - Refusals

    func testAMissingPartFailsTheJoin() throws {
        try writePart(0, size: 1_000, filler: 1)
        // Part 1 was never written.

        XCTAssertThrowsError(try SegmentMerge.joinNow(
            [part(0, size: 1_000), part(1, size: 1_000)], into: scratch, expectedTotal: 2_000
        )) { error in
            guard case SegmentMergeError.partMissing(let index) = error else {
                return XCTFail("expected partMissing, got \(error)")
            }
            XCTAssertEqual(index, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path),
                       "a refused join must not leave a half-written file behind")
        XCTAssertTrue(partsExist(0), "the parts are the only copy of the download")
    }

    func testAPartShorterThanItsRangeFailsTheJoin() throws {
        try writePart(0, size: 1_000, filler: 1)
        try writePart(1, size: 600, filler: 2)

        XCTAssertThrowsError(try SegmentMerge.joinNow(
            [part(0, size: 1_000), part(1, size: 1_000)], into: scratch, expectedTotal: 2_000
        )) { error in
            guard case SegmentMergeError.partShort(let index, let expected, let actual) = error else {
                return XCTFail("expected partShort, got \(error)")
            }
            XCTAssertEqual([index, Int(expected), Int(actual)], [1, 1_000, 600])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(partsExist(0, 1))
    }

    /// The end-to-end check: whatever the parts claimed individually, the file
    /// has to come to the size the server declared.
    func testAJoinThatDoesntReachTheExpectedTotalIsRefused() throws {
        try writePart(0, size: 1_000, filler: 1)

        XCTAssertThrowsError(try SegmentMerge.joinNow(
            [part(0, size: 1_000)], into: scratch, expectedTotal: 4_000
        )) { error in
            guard case SegmentMergeError.sizeMismatch(let expected, let actual) = error else {
                return XCTFail("expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual([Int(expected), Int(actual)], [4_000, 1_000])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    }

    func testAPausedJoinStopsAndLeavesThePartsAlone() throws {
        try writePart(0, size: 4_000, filler: 1)
        try writePart(1, size: 4_000, filler: 2)

        let cancellation = MergeCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(try SegmentMerge.joinNow(
            [part(0, size: 4_000), part(1, size: 4_000)],
            into: scratch, expectedTotal: 8_000, cancellation: cancellation
        )) { error in
            guard case DownloadError.cancelled = error else {
                return XCTFail("expected cancelled, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(partsExist(0, 1), "a pause must leave the download resumable")
    }

    // MARK: - Free space

    func testAVolumeThatCantHoldASecondCopyIsRefusedUpFront() {
        XCTAssertThrowsError(try SegmentMerge.ensureSpace(forWriting: .max, at: scratch)) { error in
            guard case SegmentMergeError.notEnoughSpace = error else {
                return XCTFail("expected notEnoughSpace, got \(error)")
            }
        }
    }

    func testAnOrdinarySizedDownloadIsNotRefused() {
        XCTAssertNoThrow(try SegmentMerge.ensureSpace(forWriting: 1_024, at: scratch))
    }
}
