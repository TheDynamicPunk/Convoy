import XCTest
@testable import DownloadEngine

/// Tests for the gate every long-running helper goes through.
///
/// The bug they exist for: macOS does not stop a child when its parent exits,
/// so a yt-dlp download kept running after Convoy quit, and the bot-check
/// server stayed up on its port. These run real child processes (`/bin/sh`,
/// `/bin/sleep`) because the behaviour that matters is the operating system's:
/// signals, exit statuses, pipes closing when a process dies.
///
/// Each long-running helper here is `exec sleep <n>` with an `n` no other test
/// and no real command uses, so `pgrep -fx` can tell this test's process from
/// any other on the machine.
final class ManagedProcessTests: XCTestCase {

    private var runDirectory: URL!
    private var supervisor: ProcessSupervisor!
    /// Processes started directly (not through the gate), to be killed at the end.
    private var strays: [Process] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("managed-process-tests-\(UUID().uuidString)", isDirectory: true)
        supervisor = ProcessSupervisor(runDirectory: runDirectory)
    }

    override func tearDownWithError() throws {
        supervisor.stopAll(timeout: 5)
        for stray in strays where stray.isRunning { stray.terminate() }
        strays = []
        try? FileManager.default.removeItem(at: runDirectory)
        supervisor = nil
        runDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    }

    private func shell(
        _ script: String,
        grace: TimeInterval = 1,
        environment: [String: String] = [:],
        collectStdout: Bool = false,
        stderrTail: Int = 8192,
        onLine: (@Sendable (String) -> Void)? = nil
    ) throws -> ManagedProcess {
        try supervisor.launch(ManagedProcessSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: environment,
            stopGrace: grace,
            onStdoutLine: onLine,
            collectStdout: collectStdout,
            stderrTailBytes: stderrTail,
            label: "test"
        ))
    }

    private func isAlive(sleeping seconds: Int) -> Bool {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-fx", "sleep \(seconds)"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        return pgrep.terminationStatus == 0
    }

    private func waitUntil(timeout: TimeInterval = 4, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// Runs `operation` with a ceiling, so a broken guard fails a test instead
    /// of hanging the run. Two unstructured tasks race rather than a task
    /// group: a group waits for *every* child before returning, and the
    /// operations tested here cannot always be cancelled, so a process that
    /// never exits would hang the group and the timeout would never be seen.
    /// The operation is left to finish when the process is stopped in tearDown.
    private func within<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()
            Task {
                let value = await operation()
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func exit(of process: ManagedProcess, within seconds: TimeInterval = 8) async -> ManagedExit? {
        await within(seconds) { await process.waitForExit() } ?? nil
    }

    // MARK: - How a helper ends

    func testExitStatusIsReportedAsExited() async throws {
        let failing = try shell("exit 7")
        let failingExit = await exit(of: failing)
        XCTAssertEqual(failingExit, .exited(7))

        let succeeding = try shell("exit 0")
        let succeedingExit = await exit(of: succeeding)
        XCTAssertEqual(succeedingExit, .exited(0))
    }

    func testAHelperKilledByASignalItDidNotReceiveFromUsIsACrash() async throws {
        // This used to be read as a user cancel, because any signal exit was.
        let process = try shell("kill -KILL $$")
        let ended = await exit(of: process)
        XCTAssertEqual(ended, .crashed(signal: 9))
    }

    func testStopReportsStoppedAndTheHelperIsGone() async throws {
        let process = try shell("exec sleep 424201")
        let started = await waitUntil { isAlive(sleeping: 424201) }
        XCTAssertTrue(started)

        process.stop()
        let ended = await exit(of: process)

        XCTAssertEqual(ended, .stopped)
        XCTAssertFalse(isAlive(sleeping: 424201), "the guard must not exit before the helper has")
    }

    func testStopEscalatesToKillForAHelperThatIgnoresTerm() async throws {
        let process = try shell("trap '' TERM; exec sleep 424202", grace: 1)
        let started = await waitUntil { isAlive(sleeping: 424202) }
        XCTAssertTrue(started)

        let began = Date()
        process.stop()
        let ended = await exit(of: process)

        XCTAssertEqual(ended, .stopped)
        XCTAssertFalse(isAlive(sleeping: 424202))
        XCTAssertLessThan(Date().timeIntervalSince(began), 6, "KILL should follow the 1 s grace period")
    }

    func testStopAfterTheProcessHasEndedChangesNothing() async throws {
        let process = try shell("exit 0")
        let first = await exit(of: process)
        XCTAssertEqual(first, .exited(0))

        process.stop()
        let second = await process.waitForExit()
        XCTAssertEqual(second, .exited(0))
        XCTAssertFalse(process.isRunning)
    }

    func testAHelperThatCatchesTermAndExitsZeroAfterAStopIsStillStopped() async throws {
        // A helper that handles SIGTERM and exits cleanly (rqbit is expected
        // to) must not be mistaken for one that finished: the caller would
        // treat a half-done transfer as complete.
        let process = try shell("trap 'exit 0' TERM; while :; do sleep 0.2; done")
        try await Task.sleep(nanoseconds: 500_000_000)   // let the trap be installed

        process.stop()
        let ended = await exit(of: process)

        XCTAssertEqual(ended, .stopped)
    }

    func testWaitingTwiceGivesTheSameAnswer() async throws {
        let process = try shell("exit 3")
        let a = await exit(of: process)
        let b = await process.waitForExit()
        XCTAssertEqual(a, .exited(3))
        XCTAssertEqual(b, .exited(3))
    }

    // MARK: - Waiting with a timeout

    func testWaitingWithATimeoutReturnsTheExitWhenTheHelperEndsFirst() async throws {
        let process = try shell("exit 3")
        let ended = await process.waitForExit(timeout: 10)
        XCTAssertEqual(ended, .exited(3))
    }

    func testWaitingWithATimeoutStopsTheHelperWhenTheTimeoutPasses() async throws {
        let process = try shell("exec sleep 424211")
        let started = await waitUntil { isAlive(sleeping: 424211) }
        XCTAssertTrue(started)

        let began = Date()
        let ended = await process.waitForExit(timeout: 0.5)

        XCTAssertNil(ended)
        XCTAssertLessThan(Date().timeIntervalSince(began), 3, "it should return at the timeout, not wait for the helper")
        let gone = await waitUntil { !isAlive(sleeping: 424211) }
        XCTAssertTrue(gone, "a helper that timed out must be stopped, not left running")
    }

    func testCancellingTheTaskThatIsWaitingStopsTheHelper() async throws {
        // The caller giving up (a sheet closed, a download cancelled) used to
        // leave the helper running with no timeout left to end it.
        let process = try shell("exec sleep 424212")
        let started = await waitUntil { isAlive(sleeping: 424212) }
        XCTAssertTrue(started)

        let waiter = Task { await process.waitForExit(timeout: 60) }
        try await Task.sleep(nanoseconds: 300_000_000)
        waiter.cancel()

        guard let finished = await within(5, { await waiter.value }) else {
            return XCTFail("cancelling the waiting task did not stop the helper")
        }
        XCTAssertEqual(finished, .stopped)
        let gone = await waitUntil { !isAlive(sleeping: 424212) }
        XCTAssertTrue(gone)
    }

    // MARK: - Launching

    func testMissingExecutableThrowsALaunchError() {
        XCTAssertThrowsError(try supervisor.launch(ManagedProcessSpec(
            executable: URL(fileURLWithPath: "/nonexistent/helper")
        ))) { error in
            guard case ManagedProcessError.executableNotFound = error else {
                return XCTFail("expected executableNotFound, got \(error)")
            }
        }
        XCTAssertEqual(supervisor.activeCount, 0)
    }

    func testTheHelperDoesNotInheritTheGuardsPipeDescriptor() async throws {
        // The guard keeps the pipe's read end on fd 3. The helper has no use
        // for it, and a helper can pass it on to its own children.
        let process = try shell("if { : <&3; } 2>/dev/null; then echo open; else echo closed; fi", collectStdout: true)
        _ = await exit(of: process)
        XCTAssertEqual(process.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "closed")
    }

    func testFinishedProcessesDoNotHoldPipeDescriptorsWhileTheyAreRetained() async throws {
        // Callers keep a ManagedProcess for as long as they like (the bot-check
        // server is held for the life of the app). Its output pipes must be
        // closed when it ends, not when it is eventually released.
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let before = openDescriptors()
        var kept: [ManagedProcess] = []
        for _ in 0..<20 {
            let process = try shell("echo hi; echo err >&2", collectStdout: true)
            _ = await exit(of: process)
            kept.append(process)
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the cancel handlers run
        let during = openDescriptors()
        withExtendedLifetime(kept) {}
        XCTAssertLessThan(during - before, 10, "20 finished processes are holding \(during - before) descriptors")
    }

    func testArgumentsReachTheHelperUnchanged() async throws {
        // Spaces, a quote and a `$` must arrive literally: the guard hands
        // them on as "$@", never through the shell's own parsing.
        let sink = LineSink()
        let process = try supervisor.launch(ManagedProcessSpec(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s\n", "a b", "c'd", "$HOME"],
            onStdoutLine: { sink.add($0) }
        ))
        _ = await exit(of: process)
        XCTAssertEqual(sink.lines, ["a b", "c'd", "$HOME"])
    }

    func testNothingIsWrittenToTheRunDirectoryUntilTheProcessIsStarted() {
        // The supervisor registers a helper before it starts it. If the record
        // were written earlier, a sweep running in that gap would see a record
        // that is not on the live list yet and delete a live helper's record.
        _ = ManagedProcess(spec: ManagedProcessSpec(executable: URL(fileURLWithPath: "/bin/sleep")),
                           runDirectory: runDirectory, onExit: { _ in })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: runDirectory.path)) ?? []
        XCTAssertEqual(files, [])
    }

    func testEnvironmentIsPassedThrough() async throws {
        let sink = LineSink()
        let process = try shell("echo $CONVOY_TEST_VALUE",
                                environment: ["CONVOY_TEST_VALUE": "from-the-spec"],
                                onLine: { sink.add($0) })
        _ = await exit(of: process)
        XCTAssertEqual(sink.lines, ["from-the-spec"])
    }

    func testTheHelperDoesNotReadTheGuardsPipeAsItsStdin() async throws {
        // If the helper inherited the pipe, `cat` would wait for the app to
        // close it. With stdin at /dev/null it ends at once.
        let process = try shell("cat >/dev/null; echo done", collectStdout: true)
        let ended = await exit(of: process, within: 4)
        XCTAssertEqual(ended, .exited(0))
        XCTAssertEqual(process.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    // MARK: - Output

    func testLinesSplitOnNewlineAndCarriageReturnAndSkipEmptyOnes() async throws {
        // yt-dlp redraws progress with \r.
        let sink = LineSink()
        let process = try shell("printf 'one\\ntwo\\rthree\\r\\n\\nfour\\n'", onLine: { sink.add($0) })
        _ = await exit(of: process)
        XCTAssertEqual(sink.lines, ["one", "two", "three", "four"])
    }

    func testAFinalLineWithoutANewlineIsStillDelivered() async throws {
        let sink = LineSink()
        let process = try shell("printf 'first\\nlast'", onLine: { sink.add($0) })
        _ = await exit(of: process)
        XCTAssertEqual(sink.lines, ["first", "last"])
    }

    func testAMultiByteCharacterSplitAcrossReadsIsNotLost() async throws {
        // "é" is C3 A9. Writing the halves apart forces them into separate
        // reads. Decoding each chunk on its own, as the old collector did,
        // drops the whole chunk; splitting on bytes first keeps the text.
        let sink = LineSink()
        let process = try shell("printf 'caf\\303'; sleep 0.3; printf '\\251\\n'", onLine: { sink.add($0) })
        _ = await exit(of: process)
        XCTAssertEqual(sink.lines, ["café"])
    }

    func testStdoutCanBeCollectedWholeAndStderrKeepsOnlyItsEnd() async throws {
        let process = try shell(
            "echo '{\"a\":1}'; i=0; while [ $i -lt 400 ]; do printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >&2; i=$((i+1)); done; echo END >&2",
            collectStdout: true,
            stderrTail: 100
        )
        _ = await exit(of: process)
        XCTAssertEqual(process.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines), "{\"a\":1}")
        XCTAssertTrue(process.stderrText.hasSuffix("END"))
        XCTAssertLessThanOrEqual(process.stderrText.utf8.count, 100)
    }

    func testStderrIsDiscardedWhenNoTailIsWanted() async throws {
        let process = try shell("echo oops >&2", stderrTail: 0)
        _ = await exit(of: process)
        XCTAssertEqual(process.stderrText, "")
    }

    func testOutputLargerThanAPipeBufferDoesNotDeadlock() async throws {
        // A pipe holds about 64 KB. A helper that writes more blocks until the
        // reader drains it, so a reader that waited for exit first would hang.
        let process = try shell("i=0; while [ $i -lt 3000 ]; do echo 0123456789012345678901234567890123456789; i=$((i+1)); done",
                                collectStdout: true)
        let ended = await exit(of: process)
        XCTAssertEqual(ended, .exited(0))
        XCTAssertEqual(process.stdoutText.split(separator: "\n").count, 3000)
    }

    // MARK: - Never outliving the app

    func testClosingTheGuardsPipeStopsTheHelperTheWayADyingAppWould() async throws {
        let process = try shell("exec sleep 424204")
        let started = await waitUntil { isAlive(sleeping: 424204) }
        XCTAssertTrue(started)

        process.simulateParentDeath()
        let ended = await exit(of: process)

        XCTAssertNotNil(ended, "the guard never noticed the pipe closing")
        XCTAssertNotEqual(ended, .exited(0))
        XCTAssertFalse(isAlive(sleeping: 424204), "the helper outlived its parent")
    }

    func testAProcessStartedLaterDoesNotInheritTheGuardsPipe() async throws {
        // If a later child held the write end open, the guard would never see
        // end-of-file after the app died, and the helper would be orphaned.
        let process = try shell("exec sleep 424205")
        let started = await waitUntil { isAlive(sleeping: 424205) }
        XCTAssertTrue(started)

        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/sh")
        listing.arguments = ["-c", "ls /dev/fd"]
        let pipe = Pipe()
        listing.standardOutput = pipe
        try listing.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listing.waitUntilExit()

        let open = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        XCTAssertFalse(open.contains(process.guardPipeWriteDescriptor),
                       "the child received the guard pipe's write end (descriptors: \(open))")
    }

    // MARK: - The pid file

    func testPidFileExistsWhileRunningAndIsGoneAfter() async throws {
        let process = try shell("exec sleep 424203")
        let pidFile = runDirectory.appendingPathComponent("\(process.id.uuidString).pid")
        let recordFile = runDirectory.appendingPathComponent("\(process.id.uuidString).exe")

        let written = await waitUntil { FileManager.default.fileExists(atPath: pidFile.path) }
        XCTAssertTrue(written)
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text))
        // The pid is the helper's, not the guard's.
        XCTAssertEqual(ProcessSupervisor.executablePath(ofPID: pid).map(ProcessSupervisor.canonicalPath),
                       ProcessSupervisor.canonicalPath("/bin/sleep"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordFile.path))

        process.stop()
        _ = await exit(of: process)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordFile.path))
    }

    // MARK: - The supervisor

    func testStopAllStopsEveryHelperAndEmptiesTheRegistry() async throws {
        let a = try shell("exec sleep 424208")
        let b = try shell("exec sleep 424209")
        let started = await waitUntil { isAlive(sleeping: 424208) && isAlive(sleeping: 424209) }
        XCTAssertTrue(started)
        XCTAssertEqual(supervisor.activeCount, 2)

        let stillRunning = supervisor.stopAll(timeout: 5)

        XCTAssertEqual(stillRunning, 0)
        XCTAssertEqual(supervisor.activeCount, 0)
        let aExit = await exit(of: a, within: 2)
        let bExit = await exit(of: b, within: 2)
        XCTAssertEqual(aExit, .stopped)
        XCTAssertEqual(bExit, .stopped)
        XCTAssertFalse(isAlive(sleeping: 424208) || isAlive(sleeping: 424209))
    }

    func testStopAllWithNothingRunningReturnsAtOnce() {
        XCTAssertEqual(supervisor.stopAll(timeout: 5), 0)
    }

    // MARK: - Orphans

    /// A helper left behind by an earlier run, as the sweep finds it: alive,
    /// with a pid file and a record of its executable, but no guard.
    private func makeOrphan(sleeping seconds: Int, recordedAs recorded: String) throws -> (process: Process, pidFile: URL, recordFile: URL) {
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/bin/sleep")
        orphan.arguments = ["\(seconds)"]
        try orphan.run()
        strays.append(orphan)

        let name = UUID().uuidString
        let pidFile = runDirectory.appendingPathComponent(name + ".pid")
        let recordFile = runDirectory.appendingPathComponent(name + ".exe")
        try "\(orphan.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)
        try recorded.write(to: recordFile, atomically: true, encoding: .utf8)
        return (orphan, pidFile, recordFile)
    }

    func testSweepStopsAnOrphanedHelperWhoseExecutableMatches() throws {
        let orphan = try makeOrphan(sleeping: 424206, recordedAs: "/bin/sleep")

        supervisor.sweepOrphans()

        XCTAssertFalse(orphan.process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.pidFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.recordFile.path))
    }

    func testSweepNeverTouchesAProcessWhoseExecutableDiffers() throws {
        // A pid the system has since handed to something unrelated.
        let bystander = try makeOrphan(sleeping: 424207, recordedAs: "/bin/echo")

        supervisor.sweepOrphans()

        XCTAssertTrue(bystander.process.isRunning, "the sweep killed a process that was not ours")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bystander.pidFile.path),
                       "the stale record should still be cleared")
    }

    func testSweepLeavesHelpersThisRunStartedAlone() async throws {
        let process = try shell("exec sleep 424210")
        let started = await waitUntil { isAlive(sleeping: 424210) }
        XCTAssertTrue(started)

        supervisor.sweepOrphans()

        XCTAssertTrue(process.isRunning)
        XCTAssertTrue(isAlive(sleeping: 424210))
    }

    func testSweepWithNoRunDirectoryDoesNothing() {
        supervisor.sweepOrphans()   // the directory does not exist yet
    }
}
