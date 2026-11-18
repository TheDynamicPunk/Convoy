import Foundation
import os

/// The one place helper processes are started and stopped.
///
/// Everything that runs a long-lived helper (yt-dlp, the bot-check server, and
/// the torrent helper later) launches it through here, so there is a single
/// answer to "what is Convoy still running?" and a single place that stops it
/// all on quit. See `ManagedProcess` for how a helper is kept from outliving
/// the app.
///
/// A locked class rather than an actor: the app calls `stopAll` from
/// `applicationWillTerminate`, which is synchronous and cannot await.
public final class ProcessSupervisor: @unchecked Sendable {
    public static let shared = ProcessSupervisor(runDirectory: HelperLocations.runDirectory)

    private let runDirectory: URL
    private let lock = NSLock()
    private var active: [UUID: ManagedProcess] = [:]
    private let logger = Logger(subsystem: "Convoy", category: "ProcessSupervisor")

    public init(runDirectory: URL) {
        self.runDirectory = runDirectory
    }

    /// How many helpers are running right now.
    public var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return active.count
    }

    /// Starts a helper under the guard.
    ///
    /// Throws if the executable is missing or not executable, rather than
    /// letting the guard start and fail with exit status 127, so callers keep
    /// getting a launch error the way they did with `Process.run()`.
    public func launch(_ spec: ManagedProcessSpec) throws -> ManagedProcess {
        guard FileManager.default.isExecutableFile(atPath: spec.executable.path) else {
            throw ManagedProcessError.executableNotFound(spec.executable.path)
        }
        let process = ManagedProcess(spec: spec, runDirectory: runDirectory) { [weak self] finished in
            self?.didExit(finished)
        }
        // Registered before it starts, so a helper that ends at once is still
        // found and removed by `didExit`.
        lock.lock(); active[process.id] = process; lock.unlock()
        do {
            try process.start()
        } catch {
            lock.lock(); active[process.id] = nil; lock.unlock()
            throw ManagedProcessError.launchFailed(error.localizedDescription)
        }
        return process
    }

    private func didExit(_ process: ManagedProcess) {
        lock.lock(); active[process.id] = nil; lock.unlock()
    }

    /// Stops every running helper and waits, up to `timeout`, for them to end.
    /// Blocking on purpose: it is called while the app is quitting. Returns
    /// how many were still running when the time ran out (their guard still
    /// stops them once the app is gone).
    @discardableResult
    public func stopAll(timeout: TimeInterval = 3) -> Int {
        lock.lock(); let running = Array(active.values); lock.unlock()
        guard !running.isEmpty else { return 0 }
        logger.notice("stopping \(running.count, privacy: .public) helper process(es)")
        for process in running { process.stop() }
        let deadline = Date().addingTimeInterval(timeout)
        var remaining = 0
        for process in running where !process.waitUntilExited(timeout: max(0, deadline.timeIntervalSinceNow)) {
            remaining += 1
        }
        return remaining
    }

    // MARK: Orphans

    /// Stops helpers an earlier run left behind. The guard normally makes that
    /// impossible; this is the backstop for the guard itself having been
    /// killed. Call it once at launch, off the main thread.
    ///
    /// Each helper records a pid file (written by the guard) and the path of
    /// its executable (written by the app). A process is stopped only if it is
    /// still alive *and* its executable is that same path, so a PID the system
    /// has since handed to something unrelated is never touched.
    public func sweepOrphans() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: runDirectory.path) else { return }
        lock.lock(); let live = Set(active.keys.map(\.uuidString)); lock.unlock()

        for name in names where name.hasSuffix(".pid") {
            let stem = String(name.dropLast(4))
            if live.contains(stem) { continue }
            let pidURL = runDirectory.appendingPathComponent(name)
            let recordURL = runDirectory.appendingPathComponent(stem + ".exe")
            defer {
                try? manager.removeItem(at: pidURL)
                try? manager.removeItem(at: recordURL)
            }
            guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
                  let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  let expected = try? String(contentsOf: recordURL, encoding: .utf8),
                  let actual = Self.executablePath(ofPID: pid),
                  Self.canonicalPath(actual) == Self.canonicalPath(expected.trimmingCharacters(in: .whitespacesAndNewlines))
            else { continue }
            logger.notice("stopping an orphaned helper (pid \(pid, privacy: .public)) left by an earlier run")
            Self.terminate(pid: pid)
        }

        // An executable record with no pid file belongs to a run that ended
        // cleanly, or died before the guard wrote it. Nothing to stop.
        for name in names where name.hasSuffix(".exe") {
            let stem = String(name.dropLast(4))
            if live.contains(stem) { continue }
            if !manager.fileExists(atPath: runDirectory.appendingPathComponent(stem + ".pid").path) {
                try? manager.removeItem(at: runDirectory.appendingPathComponent(name))
            }
        }
    }

    /// The path of the executable a running process was started from.
    static func executablePath(ofPID pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Symlinks resolved, so `/tmp/x` and `/private/tmp/x` compare equal.
    static func canonicalPath(_ path: String) -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &resolved) != nil ? String(cString: resolved) : path
    }

    private static func terminate(pid: Int32) {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 && errno == ESRCH { return }
            usleep(100_000)
        }
        kill(pid, SIGKILL)
    }
}
