import XCTest
@testable import DownloadEngine

/// Tests for taking a download's final filename without destroying anything.
///
/// The first test is the bug: every write path did
/// `removeItem(at: destinationURL)` before `moveItem` (or used
/// `FileManager.createFile`, which replaces silently), so a file the person
/// saved into that folder during the hour the download was running was gone,
/// with nothing reported. It fails against that implementation.
final class DownloadDestinationTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("destination-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        folder = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func contents(of url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Someone else's file is never the cost of finishing a download

    func testMoveSavesBesideAnExistingFileRatherThanOverIt() throws {
        let theirs = try write("video.mp4", "THE USER'S FILE")
        let source = try write("finished.tmp", "DOWNLOADED")

        let written = try DownloadDestination.move(source, to: folder.appendingPathComponent("video.mp4"))

        XCTAssertEqual(contents(of: theirs), "THE USER'S FILE", "A file that arrived while the download ran must survive it.")
        XCTAssertEqual(written.lastPathComponent, "video (1).mp4")
        XCTAssertEqual(contents(of: written), "DOWNLOADED")
    }

    func testCreateFileClaimsBesideAnExistingFileRatherThanOverIt() throws {
        let theirs = try write("stream.ts", "THE USER'S FILE")

        let claimed = try DownloadDestination.createFile(at: folder.appendingPathComponent("stream.ts"))

        XCTAssertEqual(contents(of: theirs), "THE USER'S FILE")
        XCTAssertEqual(claimed.lastPathComponent, "stream (1).ts")
        XCTAssertEqual(contents(of: claimed), "", "The claim leaves an empty file for the caller to stream into.")
    }

    // MARK: - The ordinary case stays ordinary

    func testAFreeNameIsTakenUnchanged() throws {
        let source = try write("finished.tmp", "DOWNLOADED")
        let written = try DownloadDestination.move(source, to: folder.appendingPathComponent("video.mp4"))
        XCTAssertEqual(written.lastPathComponent, "video.mp4")
    }

    func testWalksPastEveryTakenName() throws {
        try write("video.mp4", "A")
        try write("video (1).mp4", "B")
        try write("video (2).mp4", "C")
        let source = try write("finished.tmp", "NEW")

        let written = try DownloadDestination.move(source, to: folder.appendingPathComponent("video.mp4"))

        XCTAssertEqual(written.lastPathComponent, "video (3).mp4")
        XCTAssertEqual(contents(of: folder.appendingPathComponent("video.mp4")), "A")
        XCTAssertEqual(contents(of: folder.appendingPathComponent("video (1).mp4")), "B")
        XCTAssertEqual(contents(of: folder.appendingPathComponent("video (2).mp4")), "C")
    }

    func testANameWithNoExtensionSuffixesCorrectly() throws {
        try write("README", "OLD")
        let source = try write("finished.tmp", "NEW")
        let written = try DownloadDestination.move(source, to: folder.appendingPathComponent("README"))
        XCTAssertEqual(written.lastPathComponent, "README (1)")
    }

    // MARK: - A real failure is a failure, not a reason to pick another name

    func testAMissingSourceThrowsInsteadOfLooping() {
        let missing = folder.appendingPathComponent("not-there.tmp")
        XCTAssertThrowsError(
            try DownloadDestination.move(missing, to: folder.appendingPathComponent("out.mp4")),
            "Only a name collision may be retried; anything else is a genuine error."
        )
    }

    // MARK: - One definition of what " (n)" means

    func testCandidateNamingMatchesWhatTheDuplicateSheetPromises() {
        let base = URL(fileURLWithPath: "/Users/me/Downloads/Some Video.mp4")
        XCTAssertEqual(DownloadDestination.candidate(for: base, suffix: 0), base)
        XCTAssertEqual(
            DownloadDestination.candidate(for: base, suffix: 2).lastPathComponent,
            "Some Video (2).mp4"
        )
    }

    // MARK: - Behaviour the shared name-taking loop must keep

    /// A missing folder is a genuine error with its POSIX cause intact, not a
    /// reason to walk names. Callers map this to "destination missing".
    func testCreateFileInAMissingFolderThrowsItsPOSIXError() {
        let target = folder.appendingPathComponent("gone/inside.bin")
        XCTAssertThrowsError(try DownloadDestination.createFile(at: target)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(ENOENT))
        }
    }

    /// The claim is atomic: many writers asking for one name each get their own.
    func testConcurrentFileClaimsNeverShareAName() {
        let wanted = folder.appendingPathComponent("race.bin")
        let count = 24
        let lock = NSLock()
        var taken: [URL] = []
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            if let url = try? DownloadDestination.createFile(at: wanted) {
                lock.lock(); taken.append(url); lock.unlock()
            }
        }
        XCTAssertEqual(taken.count, count)
        XCTAssertEqual(Set(taken.map(\.lastPathComponent)).count, count)
    }

    // MARK: - Claiming a folder (a multi-file payload)

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func testADirectoryNameIsTakenUnchangedWhenFree() throws {
        let claimed = try DownloadDestination.createDirectory(at: folder.appendingPathComponent("Some Folder"))
        XCTAssertEqual(claimed.lastPathComponent, "Some Folder")
        XCTAssertTrue(isDirectory(claimed))
    }

    func testCreateDirectoryClaimsBesideAnExistingFolderRatherThanIntoIt() throws {
        let theirs = folder.appendingPathComponent("Some Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: false)
        try write("Some Folder/keep.txt", "THE USER'S FILE")

        let claimed = try DownloadDestination.createDirectory(at: theirs)

        XCTAssertEqual(claimed.lastPathComponent, "Some Folder (1)")
        XCTAssertEqual(contents(of: theirs.appendingPathComponent("keep.txt")), "THE USER'S FILE")
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(atPath: claimed.path)).count, 0)
    }

    /// A file in the way refuses a folder of the same name just as a folder does.
    func testCreateDirectoryClaimsBesideAnExistingFile() throws {
        let theirs = try write("Name", "A FILE")
        let claimed = try DownloadDestination.createDirectory(at: theirs)
        XCTAssertEqual(claimed.lastPathComponent, "Name (1)")
        XCTAssertEqual(contents(of: theirs), "A FILE")
    }

    /// The bug the plan found: treating ".1" as an extension made
    /// "Ubuntu 24.04.1" into "Ubuntu 24.04 (1).1". A folder has no extension.
    func testADottedFolderNameKeepsItsWholeNameBeforeTheSuffix() throws {
        for name in ["Ubuntu 24.04.1", "node-v20.10.0"] {
            let wanted = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: wanted, withIntermediateDirectories: false)
            let claimed = try DownloadDestination.createDirectory(at: wanted)
            XCTAssertEqual(claimed.lastPathComponent, "\(name) (1)")
        }
    }

    func testDirectoryCandidateNaming() {
        let base = URL(fileURLWithPath: "/Users/me/Downloads/Ubuntu 24.04.1", isDirectory: true)
        XCTAssertEqual(DownloadDestination.candidate(for: base, suffix: 0, isDirectory: true), base)
        XCTAssertEqual(
            DownloadDestination.candidate(for: base, suffix: 2, isDirectory: true).lastPathComponent,
            "Ubuntu 24.04.1 (2)"
        )
    }

    /// Only the folder that is the claim is created. A vanished destination
    /// is an error for the caller to report, not something to rebuild.
    func testCreateDirectoryDoesNotCreateMissingParents() {
        let target = folder.appendingPathComponent("gone/Payload")
        XCTAssertThrowsError(try DownloadDestination.createDirectory(at: target)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, NSPOSIXErrorDomain)
            XCTAssertEqual(nsError.code, Int(ENOENT))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("gone").path))
    }

    /// mkdir is the atomic claim: concurrent requests for one name each get
    /// a folder of their own.
    func testConcurrentDirectoryClaimsNeverShareAName() {
        let wanted = folder.appendingPathComponent("Payload")
        let count = 24
        let lock = NSLock()
        var taken: [URL] = []
        DispatchQueue.concurrentPerform(iterations: count) { _ in
            if let url = try? DownloadDestination.createDirectory(at: wanted) {
                lock.lock(); taken.append(url); lock.unlock()
            }
        }
        XCTAssertEqual(taken.count, count)
        XCTAssertEqual(Set(taken.map(\.lastPathComponent)).count, count)
        XCTAssertTrue(taken.allSatisfy(isDirectory))
    }
}
