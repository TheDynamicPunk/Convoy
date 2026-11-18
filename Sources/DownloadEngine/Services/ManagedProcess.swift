import Foundation
import os

// The single gate every long-running helper process goes through.
//
// Why it exists: macOS does not stop a child when its parent exits. A parent
// that quits, crashes or is killed leaves the child running, reparented to
// launchd. For yt-dlp that meant a download kept going (and kept using the
// network) after Convoy was gone, and the bot-check server stayed up on its
// port. Foundation's `Process.terminate()` only helps while the app is alive
// and remembers to call it, and nothing was calling it on quit.
//
// How it works: every helper is started through a small bash guard. The app
// keeps the write end of a pipe that is the guard's stdin. When the app dies
// for any reason the kernel closes that pipe, the guard's blocking `read`
// returns end-of-file, and the guard stops the helper (SIGTERM, a grace
// period, then SIGKILL). No polling and no PID guessing, and it covers
// `kill -9`, a crash and a power loss alike.
//
// The guard also keeps the helper's *exit* indistinguishable from running it
// directly: it passes the helper's exit status through, and when the helper
// dies from a signal it re-raises that signal on itself, so `Process` still
// reports `.uncaughtSignal` and a status the caller can read. And on a stop it
// waits for the helper to really finish before exiting, so a termination
// handler never fires while the helper is still flushing a partial file.

// MARK: - Public types

/// What to run, and how Convoy should treat its output and its shutdown.
public struct ManagedProcessSpec: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Added to, and overriding, the app's own environment. Empty means the
    /// helper inherits the environment unchanged.
    public var environment: [String: String]
    /// How long a stop waits for a clean exit after SIGTERM before SIGKILL.
    public var stopGrace: TimeInterval
    /// Called once per complete line of stdout, on a background queue. Lines
    /// end at `\n` or `\r` (yt-dlp redraws progress with `\r`); empty lines are
    /// skipped.
    public var onStdoutLine: (@Sendable (String) -> Void)?
    /// Keep all of stdout, for output that is parsed whole (`--dump-json`).
    public var collectStdout: Bool
    /// How many bytes from the end of stderr to keep. Zero sends stderr to
    /// /dev/null. Bounded so a runaway helper cannot grow it without limit.
    public var stderrTailBytes: Int
    /// Used in log lines.
    public var label: String

    /// With neither `onStdoutLine` nor `collectStdout`, stdout goes to
    /// /dev/null and no pipe is read.
    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        stopGrace: TimeInterval = 2,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        collectStdout: Bool = false,
        stderrTailBytes: Int = 8192,
        label: String? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.stopGrace = stopGrace
        self.onStdoutLine = onStdoutLine
        self.collectStdout = collectStdout
        self.stderrTailBytes = stderrTailBytes
        self.label = label ?? executable.lastPathComponent
    }
}

/// Lets exactly one of several racing tasks deliver an answer.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// How a managed process ended.
public enum ManagedExit: Equatable, Sendable {
    /// It exited on its own with this status (0 is success).
    case exited(Int32)
    /// Convoy asked it to stop before it ended, and it did, however it ended.
    /// A user action, not a failure.
    case stopped
    /// It was killed by a signal Convoy did not send: a crash.
    case crashed(signal: Int32)
}

public enum ManagedProcessError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Couldn't start \((path as NSString).lastPathComponent): it isn't installed or isn't executable."
        case .launchFailed(let detail):
            return "Couldn't start a helper process: \(detail)"
        }
    }
}

// MARK: - ManagedProcess

/// One running helper. Create it with `ProcessSupervisor.launch`.
public final class ManagedProcess: @unchecked Sendable {
    public let id = UUID()
    public let label: String

    private let spec: ManagedProcessSpec
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe: Pipe?
    private let stderrPipe: Pipe?
    private let output: OutputBuffer
    /// Serial: every pipe read and the finishing step run here, so output is
    /// delivered in order and nothing races the final drain.
    private let queue: DispatchQueue
    private let runDirectory: URL?
    // Set in `start()`, before the guard runs; read only after it has ended.
    private var pidFile: URL?
    private var executableRecord: URL?
    private let onExit: @Sendable (ManagedProcess) -> Void
    private let exited = DispatchGroup()
    private let logger = Logger(subsystem: "Convoy", category: "ManagedProcess")

    private let lock = NSLock()
    private var stopRequested = false
    private var started = false
    private var result: ManagedExit?
    private var waiters: [CheckedContinuation<ManagedExit, Never>] = []
    // Touched only on `queue`.
    private var stdoutReader: PipeReader?
    private var stderrReader: PipeReader?

    init(spec: ManagedProcessSpec, runDirectory: URL?, onExit: @escaping @Sendable (ManagedProcess) -> Void) {
        self.spec = spec
        self.label = spec.label
        self.onExit = onExit
        self.queue = DispatchQueue(label: "Convoy.ManagedProcess.\(spec.label)")
        let wantsStdout = spec.onStdoutLine != nil || spec.collectStdout
        self.stdoutPipe = wantsStdout ? Pipe() : nil
        self.stderrPipe = spec.stderrTailBytes > 0 ? Pipe() : nil
        self.output = OutputBuffer(
            onLine: spec.onStdoutLine,
            collectsStdout: spec.collectStdout,
            stderrLimit: spec.stderrTailBytes
        )

        self.runDirectory = runDirectory
    }

    // MARK: State

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && result == nil
    }

    /// The guard's process id (the helper itself is its child).
    public var processIdentifier: Int32 { process.processIdentifier }

    /// All of stdout, when the spec asked for it. Complete once the process
    /// has exited.
    public var stdoutText: String { output.stdoutText() }

    /// The last bytes of stderr, trimmed. Complete once the process has exited.
    public var stderrText: String { output.stderrText() }

    /// Waits for the process to end. Safe to call more than once, and after
    /// the process has already ended.
    public func waitForExit() async -> ManagedExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Like `waitForExit()`, but gives up after `timeout` seconds: it then stops
    /// the helper and returns nil.
    ///
    /// If the calling task is cancelled (a sheet closed, a download cancelled)
    /// the helper is stopped as well and this returns `.stopped`. A bare
    /// `waitForExit()` is not cancellable, so a caller that raced it against a
    /// timer would, on cancellation, lose the timer and leave the helper
    /// running with nothing left to end it.
    public func waitForExit(timeout: TimeInterval) async -> ManagedExit? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ManagedExit?, Never>) in
                let gate = OnceGate()
                let timer = Task {
                    try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                    guard !Task.isCancelled, gate.claim() else { return }
                    self.stop()
                    continuation.resume(returning: nil)
                }
                Task {
                    let ended = await self.waitForExit()
                    timer.cancel()
                    if gate.claim() { continuation.resume(returning: ended) }
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    /// Asks the helper to stop: SIGTERM, then SIGKILL after the spec's grace
    /// period. Returns immediately; `waitForExit()` reports `.stopped` once it
    /// is gone. Does nothing if it has already ended.
    public func stop() {
        lock.lock()
        stopRequested = true
        let running = started && result == nil
        lock.unlock()
        guard running else { return }

        // The signal goes to the guard, which forwards it to the helper and
        // waits for the helper to finish.
        if process.isRunning { process.terminate() }

        // Backstop for a guard that is itself stuck: if nothing has ended well
        // after the grace period, kill both outright.
        let delay = spec.stopGrace + 2
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.killIfStillRunning()
        }
    }

    // MARK: Internals

    /// Blocks until the process has ended or the timeout passes. Used by the
    /// supervisor at app quit, which cannot await.
    func waitUntilExited(timeout: TimeInterval) -> Bool {
        exited.wait(timeout: .now() + timeout) == .success
    }

    /// Closes the pipe the guard watches, as a dying app would. Tests only.
    func simulateParentDeath() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    /// The descriptor number of the write end of the guard's pipe. Tests only,
    /// and only while the process is running (the end is closed afterwards).
    var guardPipeWriteDescriptor: Int32 { stdinPipe.fileHandleForWriting.fileDescriptor }

    /// The run-directory records let a later launch find a helper this one left
    /// behind if the guard itself is ever killed. Best effort: failing to write
    /// them must not stop the helper from running.
    ///
    /// Written from `start()`, never from `init`. The supervisor registers a
    /// helper before it starts it; a sweep that ran between writing the record
    /// and registering would find a record that is not on the live list yet,
    /// take it for a leftover and delete it.
    private func writeRecords() {
        guard let runDirectory else { return }
        let name = id.uuidString
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            let recordURL = runDirectory.appendingPathComponent(name + ".exe")
            try spec.executable.path.write(to: recordURL, atomically: true, encoding: .utf8)
            executableRecord = recordURL
            pidFile = runDirectory.appendingPathComponent(name + ".pid")
        } catch {
            executableRecord = nil
            pidFile = nil
        }
    }

    func start() throws {
        writeRecords()
        var arguments = [
            "-c", Self.guardScript, "managed-guard",
            String(Int(max(1, spec.stopGrace.rounded(.up)))),
            pidFile?.path ?? "-",
            spec.executable.path,
        ]
        arguments += spec.arguments
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = arguments
        if !spec.environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        }

        // Close-on-exec on every parent-side end, so a process this app starts
        // later cannot inherit the write end of the guard's pipe and keep it
        // open after the app is gone.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = stdinPipe

        if let stdoutPipe {
            process.standardOutput = stdoutPipe
            stdoutReader = PipeReader(handle: stdoutPipe.fileHandleForReading, queue: queue) { [output] in
                output.appendStdout($0)
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        if let stderrPipe {
            process.standardError = stderrPipe
            stderrReader = PipeReader(handle: stderrPipe.fileHandleForReading, queue: queue) { [output] in
                output.appendStderr($0)
            }
        } else {
            process.standardError = FileHandle.nullDevice
        }

        exited.enter()
        process.terminationHandler = { [self] _ in
            queue.async { self.finalize() }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutReader?.close(); stderrReader?.close()
            removeRecords()
            exited.leave()
            throw error
        }
        lock.lock(); started = true; lock.unlock()
        logger.notice("started \(self.label, privacy: .public) (guard pid \(self.process.processIdentifier, privacy: .public))")
    }

    /// Runs on `queue` once the guard has exited.
    private func finalize() {
        // Whatever is still sitting in the pipes, before reading the result.
        stdoutReader?.drain(); stderrReader?.drain()
        output.flush()
        stdoutReader?.close(); stderrReader?.close()
        process.terminationHandler = nil

        let reason = process.terminationReason
        let status = process.terminationStatus

        lock.lock()
        let wasStopped = stopRequested
        // Once a stop has been asked for, however the helper ends is a stop:
        // killed, exited non-zero, or caught SIGTERM and exited 0. The last
        // matters. A helper that shuts down cleanly mid-transfer has not
        // finished, and reporting it as `.exited(0)` would have the caller
        // treat half-done work as complete. The cost is the opposite race: a
        // helper that finishes at the very instant of a stop is reported as
        // stopped, and the caller resumes and finds the work already done.
        let outcome: ManagedExit
        if wasStopped {
            outcome = .stopped
        } else if reason == .uncaughtSignal {
            outcome = .crashed(signal: status)
        } else {
            outcome = .exited(status)
        }
        result = outcome
        let pending = waiters
        waiters = []
        lock.unlock()

        try? stdinPipe.fileHandleForWriting.close()
        removeRecords()
        logger.notice("\(self.label, privacy: .public) ended: \(String(describing: outcome), privacy: .public)")

        onExit(self)
        exited.leave()
        for continuation in pending { continuation.resume(returning: outcome) }
    }

    private func removeRecords() {
        if let pidFile { try? FileManager.default.removeItem(at: pidFile) }
        if let executableRecord { try? FileManager.default.removeItem(at: executableRecord) }
    }

    private func killIfStillRunning() {
        lock.lock(); let stillRunning = started && result == nil; lock.unlock()
        guard stillRunning else { return }
        logger.error("\(self.label, privacy: .public) did not stop in time; killing it")
        if let pidFile,
           let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let child = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), child > 1 {
            kill(child, SIGKILL)
        }
        kill(process.processIdentifier, SIGKILL)
    }

    // MARK: The guard

    // Validated against a stand-in helper and against the real rqbit; see
    // docs/torrent-implementation-plan.md section 14.10 for the checks behind
    // each line. Passed to `bash -c`, so there is no extra file to bundle:
    //   bash -c <script> managed-guard <grace> <pidfile|-> <exe> [args...]
    // `managed-guard` is $0, so after `shift 2` "$@" is the helper and its
    // arguments.
    static let guardScript = #"""
# usage: bash -c '<this script>' managed-guard <grace-seconds> <pidfile|-> <command> [args...]
# The app keeps the write end of the pipe on our stdin. If the app dies for any
# reason the blocking read below returns EOF and we stop the helper.
GRACE=$1; PIDFILE=$2; shift 2
exec 3<&0
"$@" </dev/null 3<&- &            # the helper gets no stdin and not our pipe
CHILD=$!
[ "$PIDFILE" != "-" ] && echo "$CHILD" > "$PIDFILE"

stop_child() {                  # TERM, wait up to GRACE s for a clean exit, then KILL
  kill -TERM "$CHILD" 2>/dev/null
  i=0
  while kill -0 "$CHILD" 2>/dev/null && [ "$i" -lt $((GRACE * 10)) ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$CHILD" 2>/dev/null
}
trap 'stop_child' TERM INT HUP USR1
( read -r _ <&3; kill -USR1 $$ ) >/dev/null 2>&1 &   # parent gone -> same stop path
WATCHER=$!

rc=0
while :; do                              # a trapped signal interrupts `wait`; loop until the child is really gone
  wait "$CHILD"; rc=$?
  kill -0 "$CHILD" 2>/dev/null && continue
  # Child is gone. If that wait was cut short by our own trap its status is the
  # signal's, not the helper's, so collect the helper's real status now.
  # (127 = already collected, keep rc.)
  wait "$CHILD" 2>/dev/null; rc2=$?
  [ "$rc2" -ne 127 ] && rc=$rc2
  break
done
kill "$WATCHER" 2>/dev/null; wait "$WATCHER" 2>/dev/null
[ "$PIDFILE" != "-" ] && rm -f "$PIDFILE"
trap '' USR1                    # a late "parent gone" signal must not kill us now
trap - TERM INT HUP
# Mirror how the helper ended, so the app sees the same exit status or the same fatal signal.
if [ "$rc" -gt 128 ]; then kill -"$((rc - 128))" $$ 2>/dev/null; sleep 0.2; fi
exit "$rc"
"""#
}

// MARK: - Reading the pipes

/// Reads one pipe without ever blocking: a dispatch read source on the
/// process's serial queue, with the descriptor set non-blocking so the final
/// drain after the process ends cannot hang on a grandchild that still holds
/// the pipe open.
private final class PipeReader {
    private let handle: FileHandle
    private let source: DispatchSourceRead
    private let onData: (Data) -> Void
    private var closed = false   // owning queue only

    init(handle: FileHandle, queue: DispatchQueue, onData: @escaping (Data) -> Void) {
        self.handle = handle
        self.onData = onData
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        // The descriptor must stay open until the source has fully cancelled,
        // and is closed there, so a finished process that a caller still holds
        // does not keep its pipes open until it is eventually released.
        source.setCancelHandler { [handle] in try? handle.close() }
        source.resume()
    }

    /// Reads everything available right now.
    func drain() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                onData(Data(buffer[0..<count]))
            } else if count == 0 {
                close()          // end of file
                return
            } else if errno == EINTR {
                continue
            } else {
                return           // EAGAIN: nothing more for now
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
    }
}

/// Both of a helper's output streams in one place, replacing the two private
/// collectors that used to live beside the yt-dlp call sites. A locked class
/// because the pipe reads happen off the caller's actor.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?
    private let collectsStdout: Bool
    private let stderrLimit: Int
    private var lineRemainder = Data()
    private var stdoutAll = Data()
    private var stderrTail = Data()

    init(onLine: (@Sendable (String) -> Void)?, collectsStdout: Bool, stderrLimit: Int) {
        self.onLine = onLine
        self.collectsStdout = collectsStdout
        self.stderrLimit = stderrLimit
    }

    private static func isSeparator(_ byte: UInt8) -> Bool { byte == 0x0A || byte == 0x0D }

    func appendStdout(_ chunk: Data) {
        var lines: [String] = []
        lock.lock()
        if collectsStdout { stdoutAll.append(chunk) }
        if onLine != nil {
            lineRemainder.append(chunk)
            // Split on the raw bytes, then decode each line, so a chunk that
            // ends in the middle of a multi-byte character cannot corrupt or
            // drop text the way decoding a whole chunk would.
            if let lastSeparator = lineRemainder.lastIndex(where: Self.isSeparator) {
                let complete = lineRemainder[lineRemainder.startIndex...lastSeparator]
                lines = complete.split(whereSeparator: Self.isSeparator).map { String(decoding: $0, as: UTF8.self) }
                lineRemainder = Data(lineRemainder[(lastSeparator + 1)...])
            }
        }
        lock.unlock()
        if let onLine { for line in lines { onLine(line) } }
    }

    /// Delivers a final line that never got its newline.
    func flush() {
        var last: String?
        lock.lock()
        if onLine != nil, !lineRemainder.isEmpty {
            last = String(decoding: lineRemainder, as: UTF8.self)
            lineRemainder = Data()
        }
        lock.unlock()
        if let last, let onLine { onLine(last) }
    }

    func appendStderr(_ chunk: Data) {
        guard stderrLimit > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail.append(chunk)
        if stderrTail.count > stderrLimit {
            stderrTail = Data(stderrTail.suffix(stderrLimit))
        }
    }

    func stdoutText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stdoutAll, as: UTF8.self)
    }

    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
