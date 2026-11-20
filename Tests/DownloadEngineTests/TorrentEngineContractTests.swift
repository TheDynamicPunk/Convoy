import XCTest
@testable import DownloadEngine

/// What any `TorrentEngine` must do, written once and run against every
/// engine: the fake that the task tests use, and the real helper.
///
/// Running the same cases against both is what keeps the fake honest. Several
/// of them state behaviour that was *observed* in rqbit rather than assumed:
/// a second `add` of a torrent it already has comes back as success with the
/// old folder; a file that already exists is never overwritten; `forget`
/// keeps the payload and `delete` removes it.
///
/// This base class does nothing by itself: its `makeEngine` skips, so in
/// every run its own cases show as skipped. That noise is deliberate. Hiding
/// the base class from XCTest (by overriding `defaultTestSuite`) also made
/// `swift test --filter` on a subclass run no tests at all, silently, which is
/// far worse. Each engine gets a subclass that supplies one.
class TorrentEngineContractTests: XCTestCase {

    var engine: TorrentEngine!
    var scratch: URL!

    /// The engine under test, started fresh for each case.
    func makeEngine() async throws -> TorrentEngine {
        throw XCTSkip("contract suite: run through a subclass that supplies an engine")
    }

    /// Runs after each case; a real engine stops its helper here.
    func stop(_ engine: TorrentEngine) async {}

    override func setUp() async throws {
        try await super.setUp()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        self.scratch = scratch
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        let engine = try await makeEngine()
        self.engine = engine
        // Teardown blocks run last-in first-out: the engine stops before its
        // folder is removed.
        addTeardownBlock { [self] in await stop(engine) }
    }

    // MARK: - Helpers

    private func folder(_ name: String) -> URL { scratch.appendingPathComponent(name, isDirectory: true) }

    private func hash(_ hex: String) -> TorrentInfoHash { TorrentInfoHash(hex: hex)! }

    private func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A torrent can spend a moment initialising; wait for that to pass.
    private func settled(_ torrent: TorrentInfoHash) async throws -> TorrentSnapshot {
        for _ in 0..<200 {
            let snapshot = try await engine.snapshot(of: torrent)
            if snapshot.state != .initializing { return snapshot }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("still initialising after 10 s")
        return try await engine.snapshot(of: torrent)
    }

    // MARK: - Adding

    func testAddReportsTheTorrentAndCreatesItsFileInTheFolder() async throws {
        let target = folder("a")
        let details = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)

        XCTAssertEqual(details.infoHash.hex, TorrentFixtures.hashA)
        XCTAssertEqual(details.name, "abc")
        XCTAssertTrue(samePath(details.outputFolder, target))
        XCTAssertEqual(details.files, [TorrentDetails.File(path: ["abc"], length: 5, isIncluded: true)])
        let file = target.appendingPathComponent("abc")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, 5,
                       "the file is written at its full length from the start")
    }

    func testAddingOnlySomeFilesMarksTheRestAsSkipped() async throws {
        let details = try await engine.add(.torrentFile(TorrentFixtures.dataB), into: folder("b"), files: [0])

        XCTAssertEqual(details.files.map(\.path), [["a", "b.txt"], ["c.bin"]])
        XCTAssertEqual(details.files.map(\.isIncluded), [true, false])
    }

    func testTheSelectionCanBeChangedAfterwards() async throws {
        let torrent = hash(TorrentFixtures.hashB)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataB), into: folder("b"), files: [0])

        try await engine.setSelectedFiles([0, 1], of: torrent)

        let after = try await engine.details(of: torrent)
        XCTAssertEqual(after.files.map(\.isIncluded), [true, true])
    }

    func testAFolderNameWithAwkwardCharactersSurvivesTheWire() async throws {
        let target = folder("A & B + C #1 Ünï")
        let details = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)

        XCTAssertTrue(samePath(details.outputFolder, target), "got \(details.outputFolder.path)")
        XCTAssertTrue(exists(target.appendingPathComponent("abc")))
    }

    // MARK: - Choosing which files
    //
    // One rule for both engines: no files, or a file that does not exist, is
    // refused, and a refusal changes nothing. (rqbit itself would take an empty
    // selection and deselect everything; Convoy treats "nothing" as pause.)

    private func assertRejected(_ operation: () async throws -> Void, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("\(what) should have been rejected", file: file, line: line)
        } catch TorrentEngineError.rejected {
            // expected
        } catch {
            XCTFail("\(what) threw \(error), expected .rejected", file: file, line: line)
        }
    }

    private func assertNothingWasAdded(_ torrent: TorrentInfoHash, in folder: URL,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await engine.details(of: torrent)
            XCTFail("the refused add left a torrent behind", file: file, line: line)
        } catch TorrentEngineError.notFound {
            // expected
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(contents, [], "the refused add left files behind", file: file, line: line)
    }

    func testAnEmptySelectionIsRejectedAndChangesNothing() async throws {
        let target = folder("empty")
        await assertRejected({ _ = try await self.engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: []) },
                             "adding with no files")
        try await assertNothingWasAdded(hash(TorrentFixtures.hashA), in: target)

        let torrent = hash(TorrentFixtures.hashB)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataB), into: folder("b"), files: [0])
        await assertRejected({ try await self.engine.setSelectedFiles([], of: torrent) }, "selecting no files")
        let after = try await engine.details(of: torrent)
        XCTAssertEqual(after.files.map(\.isIncluded), [true, false], "a refused change must leave the selection as it was")
    }

    func testASelectionNamingAFileThatDoesNotExistIsRejectedAndChangesNothing() async throws {
        let target = folder("range")
        await assertRejected({ _ = try await self.engine.add(.torrentFile(TorrentFixtures.dataB), into: target, files: [0, 5]) },
                             "adding with file 5 of 2")
        await assertRejected({ _ = try await self.engine.add(.torrentFile(TorrentFixtures.dataB), into: target, files: [-1]) },
                             "adding with file -1")
        try await assertNothingWasAdded(hash(TorrentFixtures.hashB), in: target)

        let torrent = hash(TorrentFixtures.hashB)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataB), into: folder("b"), files: [0])
        await assertRejected({ try await self.engine.setSelectedFiles([0, 7], of: torrent) }, "selecting file 7 of 2")
        await assertRejected({ try await self.engine.setSelectedFiles([-1], of: torrent) }, "selecting file -1")
        let after = try await engine.details(of: torrent)
        XCTAssertEqual(after.files.map(\.isIncluded), [true, false], "a refused change must leave the selection as it was")
    }

    // MARK: - Adding what is already there

    func testAddingTheSameTorrentIntoTheSameFolderIsHarmless() async throws {
        let target = folder("a")
        let first = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)
        let second = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)

        XCTAssertEqual(first.infoHash, second.infoHash)
        XCTAssertTrue(samePath(second.outputFolder, target))
    }

    /// rqbit answers a repeat add with success and the *old* folder, ignoring
    /// the new one. A caller that did not check would believe its files were
    /// going where it asked.
    func testAddingTheSameTorrentIntoAnotherFolderIsRefusedAndNothingMoves() async throws {
        let first = folder("first"), second = folder("second")
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: first, files: nil)

        do {
            _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: second, files: nil)
            XCTFail("a second folder for the same torrent must be refused")
        } catch TorrentEngineError.alreadyAdded(let existing) {
            XCTAssertTrue(samePath(existing, first))
        }
        XCTAssertFalse(exists(second.appendingPathComponent("abc")))
        let unmoved = try await engine.details(of: hash(TorrentFixtures.hashA))
        XCTAssertTrue(samePath(unmoved.outputFolder, first))
    }

    func testAFileThatAlreadyExistsIsRefusedAndLeftAlone() async throws {
        let target = folder("clash")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let theirs = target.appendingPathComponent("abc")
        try Data("mine".utf8).write(to: theirs)

        // C is a different torrent whose one file is also called "abc".
        do {
            _ = try await engine.add(.torrentFile(TorrentFixtures.dataC), into: target, files: nil)
            XCTFail("adding over an existing file must be refused")
        } catch TorrentEngineError.rejected {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: theirs), Data("mine".utf8))
    }

    func testBytesThatAreNotATorrentAreRejected() async throws {
        do {
            _ = try await engine.add(.torrentFile(Data("not a torrent".utf8)), into: folder("x"), files: nil)
            XCTFail("expected a rejection")
        } catch TorrentEngineError.rejected {
            // expected
        }
    }

    // MARK: - State

    func testANewTorrentWithNoPeersIsDownloadingNothing() async throws {
        let torrent = hash(TorrentFixtures.hashA)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: folder("a"), files: nil)

        let snapshot = try await settled(torrent)

        XCTAssertEqual(snapshot.state, .downloading)
        XCTAssertEqual(snapshot.downloadedBytes, 0)
        XCTAssertEqual(snapshot.totalBytes, 5)
        XCTAssertEqual(snapshot.connectedPeers, 0)
        XCTAssertEqual(snapshot.fileProgress, [0])
    }

    func testPausingAndResuming() async throws {
        let torrent = hash(TorrentFixtures.hashA)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: folder("a"), files: nil)
        _ = try await settled(torrent)

        try await engine.pause(torrent)
        let paused = try await engine.snapshot(of: torrent)
        XCTAssertEqual(paused.state, .paused)

        try await engine.resume(torrent)
        let resumed = try await settled(torrent)
        XCTAssertEqual(resumed.state, .downloading)
    }

    func testAnUnknownTorrentIsNotFoundWhateverIsAskedOfIt() async throws {
        let stranger = hash(String(repeating: "7", count: 40))
        func assertNotFound(_ operation: () async throws -> Void, _ what: String) async {
            do {
                try await operation()
                XCTFail("\(what) should not succeed for an unknown torrent")
            } catch TorrentEngineError.notFound {
                // expected
            } catch {
                XCTFail("\(what) threw \(error), expected .notFound")
            }
        }
        await assertNotFound({ _ = try await self.engine.snapshot(of: stranger) }, "snapshot")
        await assertNotFound({ _ = try await self.engine.details(of: stranger) }, "details")
        await assertNotFound({ try await self.engine.pause(stranger) }, "pause")
        await assertNotFound({ try await self.engine.resume(stranger) }, "resume")
        await assertNotFound({ try await self.engine.setSelectedFiles([0], of: stranger) }, "setSelectedFiles")
        await assertNotFound({ try await self.engine.remove(stranger, deleteData: false) }, "remove")
    }

    // MARK: - Removing

    func testRemovingKeepsTheFilesUnlessToldOtherwise() async throws {
        let target = folder("keep")
        let torrent = hash(TorrentFixtures.hashA)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)

        try await engine.remove(torrent, deleteData: false)

        XCTAssertTrue(exists(target.appendingPathComponent("abc")), "forgetting a torrent must not delete its data")
        do {
            _ = try await engine.snapshot(of: torrent)
            XCTFail("the torrent should be gone")
        } catch TorrentEngineError.notFound {
            // expected
        }
    }

    func testRemovingWithDataDeletesTheFiles() async throws {
        let target = folder("gone")
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: target, files: nil)
        XCTAssertTrue(exists(target.appendingPathComponent("abc")))

        try await engine.remove(hash(TorrentFixtures.hashA), deleteData: true)

        XCTAssertFalse(exists(target.appendingPathComponent("abc")))
    }

    // MARK: - Updates

    func testTheUpdateStreamEndsWhenTheTorrentIsRemoved() async throws {
        let torrent = hash(TorrentFixtures.hashA)
        _ = try await engine.add(.torrentFile(TorrentFixtures.dataA), into: folder("u"), files: nil)

        var received = 0
        for try await _ in engine.updates(of: torrent, every: .milliseconds(20)) {
            received += 1
            if received == 2 { try await engine.remove(torrent, deleteData: false) }
            if received > 300 { return XCTFail("the stream did not end after the torrent was removed") }
        }
        XCTAssertGreaterThanOrEqual(received, 2)
    }
}

/// The fake, held to the contract.
final class FakeTorrentEngineContractTests: TorrentEngineContractTests {
    override func makeEngine() async throws -> TorrentEngine { FakeTorrentEngine() }
}
