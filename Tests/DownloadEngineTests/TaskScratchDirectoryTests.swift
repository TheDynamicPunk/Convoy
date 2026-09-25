import XCTest
@testable import DownloadEngine

/// Tests for the naming contract of per-download scratch directories: the id
/// goes into the name, and comes back out of it.
///
/// That contract is what lets cleanup be driven by identity rather than by
/// age — the previous sweep deleted any `mdl-yt-` directory untouched for 24
/// hours, so a download paused overnight lost its partial bytes the next time
/// any other YouTube download started. Sweeping now lives in
/// `TemporaryStorage`, which recognises these directories *and* the loose
/// segment files beside them; its tests cover that behaviour.
final class TaskScratchDirectoryTests: XCTestCase {

    private var container: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeDirectory(_ kind: TaskScratchDirectory, for taskID: UUID) throws -> URL {
        let url = kind.url(for: taskID, in: container)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Deleting one row's directory

    func testRemoveTakesOnlyTheNamedTasksDirectory() throws {
        let deleted = UUID(), kept = UUID()
        let deletedDir = try makeDirectory(.youTubeMerge, for: deleted)
        let keptDir = try makeDirectory(.youTubeMerge, for: kept)

        TaskScratchDirectory.youTubeMerge.remove(for: deleted, in: container)

        XCTAssertFalse(exists(deletedDir))
        XCTAssertTrue(exists(keptDir))
    }

    func testRemoveIsANoOpWhenThereIsNothingToRemove() {
        TaskScratchDirectory.youTubeMerge.remove(for: UUID(), in: container)
    }

    // MARK: - Naming

    func testEveryKindRoundTripsItsTaskIDThroughTheDirectoryName() {
        for kind in TaskScratchDirectory.allCases {
            let taskID = UUID()
            let name = kind.url(for: taskID, in: container).lastPathComponent
            XCTAssertEqual(kind.taskID(fromDirectoryName: name), taskID, "\(kind) must be able to read back the id it wrote.")
        }
    }

    func testAKindDoesNotClaimAnotherKindsDirectoryName() {
        let taskID = UUID()
        let streamName = TaskScratchDirectory.streamSegments
            .url(for: taskID, in: container).lastPathComponent

        XCTAssertNil(TaskScratchDirectory.youTubeMerge.taskID(fromDirectoryName: streamName))
    }
}
