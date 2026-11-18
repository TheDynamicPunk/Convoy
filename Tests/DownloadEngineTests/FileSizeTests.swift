import XCTest
@testable import DownloadEngine

/// `FileSize.bytes(at:)`: the logical length of a file, or nil when it can't
/// be read, with the fallback left to the caller.
final class FileSizeTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-size-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    func testReportsTheNumberOfBytesInTheFile() throws {
        let file = folder.appendingPathComponent("data.bin")
        try Data(count: 12_345).write(to: file)

        XCTAssertEqual(FileSize.bytes(at: file), 12_345)
    }

    func testAnEmptyFileIsZeroNotNil() throws {
        let file = folder.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        XCTAssertEqual(FileSize.bytes(at: file), 0)
    }

    func testAMissingFileIsNilSoTheCallerChoosesTheFallback() {
        XCTAssertNil(FileSize.bytes(at: folder.appendingPathComponent("nope.bin")))
    }
}
