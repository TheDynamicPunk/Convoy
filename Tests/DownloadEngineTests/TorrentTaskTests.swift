import XCTest
@testable import DownloadEngine

@MainActor
final class TorrentTaskTests: XCTestCase {

    private var rootDir: URL!
    private var downloadsDir: URL!
    private var torrentsDir: URL!
    private var persistenceURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convoy-torrent-tests-\(UUID().uuidString)", isDirectory: true)
        downloadsDir = rootDir.appendingPathComponent("Downloads", isDirectory: true)
        torrentsDir = rootDir.appendingPathComponent("torrents", isDirectory: true)
        persistenceURL = rootDir.appendingPathComponent("downloads.json")
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: torrentsDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let rootDir {
            try? FileManager.default.removeItem(at: rootDir)
        }
        try await super.tearDown()
    }

    private func makeManager(
        engine: any TorrentEngine,
        maxConcurrent: Int = 2,
        availableSpace: ((URL) -> Int64?)? = nil,
        seedingPolicy: SeedingPolicy = .stopAtCompletion
    ) -> DownloadManager {
        DownloadManager(
            torrentEngine: engine,
            persistenceURL: persistenceURL,
            torrentsDirectory: torrentsDir,
            maxConcurrentOverride: maxConcurrent,
            torrentAvailableSpaceProvider: availableSpace,
            torrentPollInterval: .milliseconds(15),
            torrentSeedingPolicyProvider: { seedingPolicy }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return condition()
    }

    // MARK: - Lifecycle: start, progress, completion

    func testTorrentFileDownloadsAndStopsAtCompletionByDefault() async throws {
        let engine = FakeTorrentEngine()
        let manager = makeManager(engine: engine, seedingPolicy: .stopAtCompletion)
        let torrentFile = try TorrentFile(TorrentFixtures.dataB)

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataB),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        XCTAssertTrue(task.isTorrent)
        XCTAssertEqual(task.torrentInfoHash, torrentFile.infoHash)
        XCTAssertEqual(task.filename, "pack")
        XCTAssertEqual(task.totalBytes, torrentFile.totalSize)
        XCTAssertEqual(task.status, .paused)

        // Start in background, then simulate completion on the fake engine.
        let run = Task { try? await manager.resumeDownload(task) }
        let started = await waitUntil { task.status == .downloading }
        XCTAssertTrue(started)

        engine.simulate(torrentFile.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentFile.totalSize
            snap.totalBytes = torrentFile.totalSize
            snap.connectedPeers = 4
            snap.connectedSeeds = 2
        }

        let completed = await waitUntil { task.status == .completed && manager.completedTasks.contains(where: { $0.id == task.id }) }
        await run.value

        XCTAssertTrue(completed)
        XCTAssertFalse(task.isSeeding)
        XCTAssertEqual(manager.activeCount, 0)

        // Default policy forgets the torrent from the engine while keeping files on disk.
        do {
            _ = try await engine.snapshot(of: torrentFile.infoHash)
            XCTFail("Expected torrent to be forgotten from engine on stopAtCompletion")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.appendingPathComponent("c.bin").path))
    }

    func testMagnetProbesMetadataAdoptsNameAndStoresTorrentFile() async throws {
        let engine = FakeTorrentEngine()
        let torrentFile = try TorrentFile(TorrentFixtures.dataB)
        engine.makeResolvable(torrentFile)

        let manager = makeManager(engine: engine, seedingPolicy: .stopAtCompletion)
        let magnet = "magnet:?xt=urn:btih:\(TorrentFixtures.hashB)"

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .magnet(magnet),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))
        XCTAssertEqual(task.filename, "Torrent \(TorrentFixtures.hashB.prefix(8))")

        let run = Task { try? await manager.resumeDownload(task) }
        let downloading = await waitUntil { task.status == .downloading }
        XCTAssertTrue(downloading)
        XCTAssertEqual(task.filename, "pack")
        XCTAssertEqual(task.filenameSource, .torrentName)
        XCTAssertEqual(task.torrentFiles.count, 2)
        XCTAssertNotNil(TorrentStorage.loadTorrentData(for: task.id, base: torrentsDir))

        engine.simulate(torrentFile.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentFile.totalSize
            snap.totalBytes = torrentFile.totalSize
        }

        let completed = await waitUntil { task.status == .completed }
        await run.value
        XCTAssertTrue(completed)
    }

    func testHelperFailureDuringMagnetMetadataFetchFailsPlainlyWithoutHanging() async throws {
        let engine = FakeTorrentEngine()
        // Do NOT call makeResolvable: probe() will reject.
        let manager = makeManager(engine: engine)
        let magnet = "magnet:?xt=urn:btih:\(TorrentFixtures.hashA)"

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .magnet(magnet),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        try? await manager.resumeDownload(task)

        if case .failed(let error) = task.status {
            XCTAssertNotNil(error)
        } else {
            XCTFail("Expected .failed status when magnet probe fails, got \(task.status)")
        }
        XCTAssertEqual(manager.activeCount, 0)
    }

    // MARK: - Pause, Resume, Cancel & Runtime File Selection

    func testPauseAndResumeReattachesWithoutRestarting() async throws {
        let engine = FakeTorrentEngine()
        let torrentFile = try TorrentFile(TorrentFixtures.dataB)
        let manager = makeManager(engine: engine)

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataB),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let run1 = Task { try? await manager.resumeDownload(task) }
        let started = await waitUntil { task.status == .downloading }
        XCTAssertTrue(started)

        await manager.pauseDownload(task)
        await run1.value
        XCTAssertEqual(task.status, .paused)
        XCTAssertEqual(manager.activeCount, 0)

        let pausedSnap = try await engine.snapshot(of: torrentFile.infoHash)
        XCTAssertEqual(pausedSnap.state, .paused)

        // Change file selection while paused, then resume to completion.
        try await task.setSelectedTorrentFiles([1])
        let details = try await engine.details(of: torrentFile.infoHash)
        XCTAssertEqual(details.files.map(\.isIncluded), [false, true])

        let run2 = Task { try? await manager.resumeDownload(task) }
        let resumed = await waitUntil { task.status == .downloading }
        XCTAssertTrue(resumed)

        engine.simulate(torrentFile.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = 4
            snap.totalBytes = 4
        }

        let completed = await waitUntil { task.status == .completed }
        await run2.value
        XCTAssertTrue(completed)
    }

    func testCancelRemovesTorrentFromEngineAndCleansStoredMetadata() async throws {
        let engine = FakeTorrentEngine()
        let torrentFile = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine)

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))
        XCTAssertNotNil(TorrentStorage.loadTorrentData(for: task.id, base: torrentsDir))

        let run = Task { try? await manager.resumeDownload(task) }
        let started = await waitUntil { task.status == .downloading }
        XCTAssertTrue(started)

        await manager.cancelDownload(task)
        await run.value

        XCTAssertEqual(task.status, .cancelled)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertNil(TorrentStorage.loadTorrentData(for: task.id, base: torrentsDir))
        do {
            _ = try await engine.snapshot(of: torrentFile.infoHash)
            XCTFail("Expected cancelled torrent to be removed from engine")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - Seeding Policy & Concurrency

    func testSeedingUntilRatioReleasesConcurrencySlotAndStopsWhenRatioReached() async throws {
        let engine = FakeTorrentEngine()
        let torrentA = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine, maxConcurrent: 1, seedingPolicy: .untilRatio(1.0))

        let taskA = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))
        let taskB = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataB),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let runA = Task { try? await manager.resumeDownload(taskA) }
        let aStarted = await waitUntil { taskA.status == .downloading }
        XCTAssertTrue(aStarted)
        XCTAssertEqual(manager.activeCount, 1)

        // Task B hits maxConcurrent=1 and queues as .waiting.
        try await manager.resumeDownload(taskB)
        XCTAssertEqual(taskB.status, .waiting)

        // Task A finishes payload and begins seeding; it must release the slot so B starts!
        engine.simulate(torrentA.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentA.totalSize
            snap.totalBytes = torrentA.totalSize
            snap.uploadedBytes = 1
            snap.uploadBytesPerSecond = 500
        }

        let aSeedingAndBRunning = await waitUntil {
            taskA.status == .completed && taskA.isSeeding && taskB.status == .downloading
        }
        await runA.value
        XCTAssertTrue(aSeedingAndBRunning)

        // Simulate A reaching ratio 1.0 (uploaded >= totalSize).
        engine.simulate(torrentA.infoHash) { snap in
            snap.uploadedBytes = torrentA.totalSize
        }

        let aStoppedSeeding = await waitUntil { !taskA.isSeeding }
        XCTAssertTrue(aStoppedSeeding)
        XCTAssertEqual(taskA.uploadSpeed, 0)

        // Verify upload actually stopped (torrent forgotten from engine).
        do {
            _ = try await engine.snapshot(of: torrentA.infoHash)
            XCTFail("Expected torrent A to be removed from engine once ratio target met")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }

        // Clean up task B.
        await manager.cancelDownload(taskB)
    }

    func testSeedingUntilDurationStopsAfterElapsedTime() async throws {
        let engine = FakeTorrentEngine()
        let torrentA = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine, seedingPolicy: .untilDuration(0.05))

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let run = Task { try? await manager.resumeDownload(task) }
        _ = await waitUntil { task.status == .downloading }
        engine.simulate(torrentA.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentA.totalSize
            snap.totalBytes = torrentA.totalSize
            snap.uploadBytesPerSecond = 250
        }

        let startedSeeding = await waitUntil { task.status == .completed && task.isSeeding }
        await run.value
        XCTAssertTrue(startedSeeding)

        let stoppedSeeding = await waitUntil { !task.isSeeding }
        XCTAssertTrue(stoppedSeeding)
        XCTAssertEqual(task.uploadSpeed, 0)
        do {
            _ = try await engine.snapshot(of: torrentA.infoHash)
            XCTFail("Expected torrent to be removed from engine once seeding duration elapsed")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testManualStopSeedingStopsUploadAndKeepsFiles() async throws {
        let engine = FakeTorrentEngine()
        let torrentA = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine, seedingPolicy: .untilRatio(5.0))

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let run = Task { try? await manager.resumeDownload(task) }
        _ = await waitUntil { task.status == .downloading }
        engine.simulate(torrentA.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentA.totalSize
            snap.totalBytes = torrentA.totalSize
            snap.uploadedBytes = 1
        }
        let seeding = await waitUntil { task.status == .completed && task.isSeeding }
        await run.value
        XCTAssertTrue(seeding)

        await task.stopSeeding()
        XCTAssertFalse(task.isSeeding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.destinationURL.appendingPathComponent("abc").path))
        do {
            _ = try await engine.snapshot(of: torrentA.infoHash)
            XCTFail("Expected stopSeeding() to remove torrent from engine")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }
    }

    // MARK: - Disk Space & ENOSPC

    func testInsufficientDiskSpacePausesWithPlainMessageBeforeAddingToEngine() async throws {
        let engine = FakeTorrentEngine()
        let torrentB = try TorrentFile(TorrentFixtures.dataB) // totalSize = 7 bytes
        let manager = makeManager(
            engine: engine,
            availableSpace: { _ in 3 } // smaller than whole torrent (7 bytes), even if only 3-byte file is selected
        )

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataB),
            destinationFolder: downloadsDir,
            selectedFiles: [0], // 3 bytes selected, but whole torrent is 7 bytes
            startAutomatically: false
        ))

        try await manager.resumeDownload(task)

        XCTAssertEqual(task.status, .paused)
        XCTAssertTrue(task.activityMessage?.contains("Not enough space") == true)
        XCTAssertEqual(manager.activeCount, 0)

        // Never added to the engine.
        do {
            _ = try await engine.snapshot(of: torrentB.infoHash)
            XCTFail("Expected torrent not to be added when disk space is insufficient")
        } catch let error as TorrentEngineError {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testDiskFullMidDownloadMapsENOSPCToPlainFailure() async throws {
        let engine = FakeTorrentEngine()
        let torrentA = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine)

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let run = Task { try? await manager.resumeDownload(task) }
        let started = await waitUntil { task.status == .downloading }
        XCTAssertTrue(started)

        engine.simulate(torrentA.infoHash) { snap in
            snap.state = .error("error writing piece: ENOSPC: No space left on device")
        }

        let failed = await waitUntil {
            if case .failed = task.status { return true }
            return false
        }
        await run.value
        XCTAssertTrue(failed)
        if case .failed(let error) = task.status {
            XCTAssertEqual(
                error?.localizedDescription,
                DownloadError.torrentDiskFull.errorDescription
            )
        }
    }

    // MARK: - Duplicate Detection (Magnet vs .torrent)

    func testMagnetAndTorrentFileWithSameInfoHashTriggerDuplicateConflict() async throws {
        let engine = FakeTorrentEngine()
        let manager = makeManager(engine: engine)

        _ = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let magnet = "magnet:?xt=urn:btih:\(TorrentFixtures.hashA)&dn=different-name"
        do {
            _ = try await manager.addTorrentDownload(TorrentAddRequest(
                source: .magnet(magnet),
                destinationFolder: downloadsDir,
                startAutomatically: false
            ))
            XCTFail("Expected DownloadConflictError for matching info hash")
        } catch is DownloadConflictError {
            XCTAssertNotNil(manager.pendingConflict)
            XCTAssertEqual(manager.pendingConflict?.existingTask.torrentInfoHash?.hex, TorrentFixtures.hashA)
        }
    }

    // MARK: - Persistence & Relaunch Reattach

    func testPersistenceRoundTripsTorrentAndRestoresAsPausedOnRelaunch() async throws {
        // Scope manager1 so it releases its DownloadListLock before manager2
        // launches, matching an actual app quit and relaunch.
        let savedTaskID: UUID
        do {
            let engine = FakeTorrentEngine()
            let manager1 = makeManager(engine: engine)
            let task = try await manager1.addTorrentDownload(TorrentAddRequest(
                source: .torrentFile(TorrentFixtures.dataB),
                destinationFolder: downloadsDir,
                selectedFiles: [1],
                startAutomatically: false
            ))
            manager1.saveBeforeTermination()
            savedTaskID = task.id
        }

        // Relaunch with a brand-new manager reading the same persistenceURL and torrentsDir.
        let engine2 = FakeTorrentEngine()
        let manager2 = makeManager(engine: engine2)
        XCTAssertEqual(manager2.tasks.count, 1)
        let restored = try XCTUnwrap(manager2.tasks.first)
        XCTAssertEqual(restored.id, savedTaskID)
        XCTAssertEqual(restored.status, .paused)
        XCTAssertEqual(restored.torrentInfoHash?.hex, TorrentFixtures.hashB)
        if case .torrent(let t) = restored.kind {
            XCTAssertEqual(t.selectedFiles, [1])
            XCTAssertEqual(t.wholeTorrentSize, 7)
        } else {
            XCTFail("Expected restored task to have .torrent kind")
        }

        // Resuming on a fresh engine re-adds from stored `.torrent` and completes.
        let run = Task { try? await manager2.resumeDownload(restored) }
        let started = await waitUntil { restored.status == .downloading }
        XCTAssertTrue(started)

        let hashB = try XCTUnwrap(TorrentInfoHash(hex: TorrentFixtures.hashB))
        engine2.simulate(hashB) { snap in
            snap.state = .seeding
            snap.downloadedBytes = 4
            snap.totalBytes = 4
        }
        let completed = await waitUntil { restored.status == .completed }
        await run.value
        XCTAssertTrue(completed)
    }

    func testLegacyDownloadsJSONWithoutTorrentFieldDecodesAsDirect() throws {
        let id = UUID()
        let legacyJSON = """
        [
          {
            "id": "\(id.uuidString)",
            "url": "https://example.invalid/archive.zip",
            "destinationPath": "\(downloadsDir.appendingPathComponent("archive.zip").path)",
            "originalName": "archive.zip",
            "priorityRaw": 1,
            "segmentCount": 8,
            "kind": "active",
            "totalBytes": 1024,
            "downloadedBytes": 512
          }
        ]
        """
        let decoded = try JSONDecoder().decode([PersistedDownloadTask].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].downloadKind, .direct)
        XCTAssertNil(decoded[0].torrent)
    }

    // MARK: - TemporaryStorage, DeletionPlan & LinkInfoProbe

    func testTemporaryStorageNeverReportsTorrentStateAsOrphan() throws {
        let id = UUID()
        try TorrentStorage.saveTorrentData(TorrentFixtures.dataA, for: id, base: torrentsDir)
        let report = TemporaryStorage.report(knownTaskIDs: [], in: torrentsDir)
        XCTAssertTrue(report.isEmpty)
    }

    func testDeletionPlanMeasuresCompletedTorrentFolderAndFlagsSeeding() async throws {
        let engine = FakeTorrentEngine()
        let torrentA = try TorrentFile(TorrentFixtures.dataA)
        let manager = makeManager(engine: engine, seedingPolicy: .untilRatio(2.0))

        let task = try await manager.addTorrentDownload(TorrentAddRequest(
            source: .torrentFile(TorrentFixtures.dataA),
            destinationFolder: downloadsDir,
            startAutomatically: false
        ))

        let run = Task { try? await manager.resumeDownload(task) }
        _ = await waitUntil { task.status == .downloading }
        engine.simulate(torrentA.infoHash) { snap in
            snap.state = .seeding
            snap.downloadedBytes = torrentA.totalSize
            snap.totalBytes = torrentA.totalSize
        }
        _ = await waitUntil { task.status == .completed && task.isSeeding }
        await run.value

        let plan = DeletionPlan(tasks: [task])
        XCTAssertTrue(plan.hasSeedingItems)
        XCTAssertFalse(plan.isTriviallyDeletable)
        if case .finishedFile(let bytes) = plan.single?.impact {
            XCTAssertEqual(bytes, torrentA.totalSize)
        } else {
            XCTFail("Expected .finishedFile impact for completed torrent folder, got \(String(describing: plan.single?.impact))")
        }

        // Deleting stops seeding and removes the row.
        let outcome = await manager.delete(taskIDs: [task.id], moveFilesToTrash: false)
        XCTAssertEqual(outcome.removedCount, 1)
        XCTAssertFalse(task.isSeeding)
    }

    func testLinkInfoProbeSkipsMagnetLinks() async {
        let magnetURL = URL(string: "magnet:?xt=urn:btih:\(TorrentFixtures.hashA)")!
        let info = await LinkInfoProbe.fetch(url: magnetURL, headers: [:])
        XCTAssertNil(info)
    }
}
