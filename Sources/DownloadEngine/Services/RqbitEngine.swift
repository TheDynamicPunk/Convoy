import Foundation

/// The torrent engine backed by rqbit: starts the helper when it is first
/// needed, replaces it if it has died, and otherwise passes every call to
/// `RqbitClient`.
///
/// The helper is launched through `ProcessSupervisor`, so it is stopped when
/// Convoy quits and cannot outlive a crash. Each launch picks fresh ports and
/// a fresh secret: the control port is on loopback only, and the secret is
/// what stops any other process on the machine from driving it. The helper
/// keeps its own session state in `sessionDirectory`, so torrents that were
/// running when it died are picked up again by the next one.
///
/// Two helpers must never run against one session folder, and an actor lets
/// other work in whenever it waits, so the rules that prevent that are:
///
/// - A launch cleans up after itself. However it ends other than with a helper
///   serving, the helper it started is stopped and gone before the launch
///   finishes.
/// - Retiring a helper is serialised through `retiring`, and nothing starts a
///   new helper until the last one retired has exited.
/// - `stop()` is a barrier: when it returns, no helper it knew of is left, and
///   calls that were waiting on one are told it was stopped rather than
///   starting another.
/// - A failure evicts the helper that failed, identified by `id`, never
///   whichever one is current by the time the failure is handled.
actor RqbitEngine: TorrentEngine {

    struct Options: Sendable {
        var executable: URL
        /// Where the helper keeps what it needs to resume torrents.
        var sessionDirectory: URL
        /// The helper insists on a default output folder. Every add here names
        /// its own, so nothing is ever written to this one.
        var defaultOutputFolder: URL
        /// Bytes per second. These are launch flags in rqbit, not something
        /// that can change while it runs.
        var uploadLimit: Int?
        var downloadLimit: Int?
        /// Fixed peer listening port (`1024...65535`), or nil for a random free port.
        var peerPort: UInt16?
        var enableUPnP: Bool
        var enableLSD: Bool
        var persistDHT: Bool
        /// Added before the subcommand. A seam for tests, which switch off
        /// the network parts of the helper.
        var extraArguments: [String]
        /// How long to wait for a new helper to start answering.
        var startTimeout: TimeInterval

        init(
            executable: URL = URL(fileURLWithPath: HelperLocations.rqbit),
            sessionDirectory: URL = HelperLocations.torrentsDirectory.appendingPathComponent("session", isDirectory: true),
            defaultOutputFolder: URL = HelperLocations.torrentsDirectory.appendingPathComponent("incoming", isDirectory: true),
            uploadLimit: Int? = nil,
            downloadLimit: Int? = nil,
            peerPort: UInt16? = nil,
            enableUPnP: Bool = false,
            enableLSD: Bool = false,
            persistDHT: Bool = false,
            extraArguments: [String] = [],
            startTimeout: TimeInterval = 20
        ) {
            self.executable = executable
            self.sessionDirectory = sessionDirectory
            self.defaultOutputFolder = defaultOutputFolder
            self.uploadLimit = uploadLimit
            self.downloadLimit = downloadLimit
            self.peerPort = peerPort
            self.enableUPnP = enableUPnP
            self.enableLSD = enableLSD
            self.persistDHT = persistDHT
            self.extraArguments = extraArguments
            self.startTimeout = startTimeout
        }
    }

    private struct Running: Sendable {
        /// Names this helper for as long as the engine lives, so a failure can
        /// be charged to the helper that had it and no other.
        let id = UUID()
        let process: ManagedProcess
        let client: RqbitClient
        let launchedConfig: TorrentHelperConfig
    }

    /// A launch that found its port taken between choosing it and the helper
    /// binding it. Retried with new ports; never seen outside this file.
    private enum LaunchAttempt: Error {
        case portTaken(String)
    }

    private let options: Options
    private let optionsProvider: (@Sendable () async -> Options)?
    private let supervisor: ProcessSupervisor
    private let clientConfiguration: URLSessionConfiguration

    private var running: Running?
    private var starting: (id: UUID, task: Task<Running, Error>)?
    /// The last helper to be retired, and, chained behind it, every one before.
    /// Awaiting it means every retired helper has exited.
    private var retiring: Task<Void, Never>?
    /// Counts `stop()` calls, so a call that was already under way when one
    /// happened can tell, and fail rather than start a helper afterwards.
    private var generation = 0

    init(
        options: Options = Options(),
        optionsProvider: (@Sendable () async -> Options)? = nil,
        supervisor: ProcessSupervisor = .shared,
        clientConfiguration: URLSessionConfiguration = .cookieless
    ) {
        self.options = options
        self.optionsProvider = optionsProvider
        self.supervisor = supervisor
        self.clientConfiguration = clientConfiguration
    }

    /// The command line for the helper. Global options come before the
    /// subcommand; the output folder is the subcommand's last argument.
    static func launchArguments(
        apiPort: UInt16,
        peerPort: UInt16,
        sessionDirectory: URL,
        defaultOutputFolder: URL,
        uploadLimit: Int?,
        downloadLimit: Int?,
        enableUPnP: Bool = false,
        enableLSD: Bool = false,
        persistDHT: Bool = false,
        extra: [String]
    ) -> [String] {
        var arguments = [
            "--http-api-listen-addr", "127.0.0.1:\(apiPort)",
            "--listen-port", "\(peerPort)",
        ]
        // Phase 0 found these on by default in rqbit; Convoy keeps them off
        // unless explicitly opted in from Settings → Torrents.
        if !persistDHT { arguments.append("--disable-dht-persistence") }
        if !enableUPnP { arguments.append("--disable-upnp-port-forward") }
        if !enableLSD { arguments.append("--disable-lsd") }
        if let uploadLimit { arguments += ["--ratelimit-upload", "\(uploadLimit)"] }
        if let downloadLimit { arguments += ["--ratelimit-download", "\(downloadLimit)"] }
        arguments += extra
        arguments += ["server", "start", "--persistence-location", sessionDirectory.path, defaultOutputFolder.path]
        return arguments
    }

    func activeHelperConfig() async -> TorrentHelperConfig? {
        guard let running, running.process.isRunning else { return nil }
        return running.launchedConfig
    }

    /// Stops the helper and waits for it to be gone, including one that is
    /// still starting. The next call starts a new one.
    func stop() async {
        generation += 1
        if let starting {
            starting.task.cancel()
            // The launch stops and waits for its own helper before it ends,
            // so waiting for the launch is waiting for that.
            _ = try? await starting.task.value
        }
        if let running { retire(running) }
        await retiring?.value
    }

    // MARK: - TorrentEngine

    func probe(magnet: String) async throws -> TorrentFile {
        try await call { try await $0.probe(magnet: magnet) }
    }

    func add(_ source: TorrentSource, into folder: URL, files: Set<Int>?) async throws -> TorrentDetails {
        try await call { try await $0.add(source, into: folder, files: files) }
    }

    func details(of torrent: TorrentInfoHash) async throws -> TorrentDetails {
        try await call { try await $0.details(of: torrent) }
    }

    func setSelectedFiles(_ files: Set<Int>, of torrent: TorrentInfoHash) async throws {
        try await call { try await $0.setSelectedFiles(files, of: torrent) }
    }

    func snapshot(of torrent: TorrentInfoHash) async throws -> TorrentSnapshot {
        try await call { try await $0.snapshot(of: torrent) }
    }

    func pause(_ torrent: TorrentInfoHash) async throws {
        try await call { try await $0.pause(torrent) }
    }

    func resume(_ torrent: TorrentInfoHash) async throws {
        try await call { try await $0.resume(torrent) }
    }

    func remove(_ torrent: TorrentInfoHash, deleteData: Bool) async throws {
        var attempts = 0
        try await call { client in
            attempts += 1
            do {
                try await client.remove(torrent, deleteData: deleteData)
            } catch TorrentEngineError.notFound where attempts > 1 {
                // The first attempt died with its helper. If the replacement,
                // which restored the session, no longer has the torrent, the
                // removal happened.
            }
        }
    }

    func pieceBitfield(of torrent: TorrentInfoHash) async -> Data? {
        try? await call { await $0.pieceBitfield(of: torrent) }
    }

    // MARK: - Calls

    /// Runs `operation` against a running helper. If that helper turns out to
    /// be gone, evicts it, starts a replacement and tries once more, which is
    /// safe for every operation here: each is idempotent, or (remove) read
    /// that way by its caller above.
    ///
    /// A call that was under way when `stop()` was called does not retry, so
    /// stopping the engine cannot be followed by a helper it did not ask for.
    private func call<T: Sendable>(_ operation: (RqbitClient) async throws -> T) async throws -> T {
        let started = generation
        var attempt = 0
        while true {
            let helper = try await current()
            do {
                return try await operation(helper.client)
            } catch where Self.helperIsGone(error) {
                // Charged to the helper that failed, not to whatever is current.
                if running?.id == helper.id { retire(helper) }
                attempt += 1
                if attempt > 1 || generation != started || Task.isCancelled {
                    if Task.isCancelled { throw CancellationError() }
                    throw TorrentEngineError.helperUnavailable
                }
            }
        }
    }

    /// Whether an error means the helper is not there to answer. A cancelled
    /// request counts when nobody cancelled the caller: it was cancelled by
    /// the helper's own retirement.
    private static func helperIsGone(_ error: Error) -> Bool {
        if case TorrentEngineError.helperUnavailable = error { return true }
        return error is CancellationError && !Task.isCancelled
    }

    // MARK: - The helper's life

    /// A running helper, starting one if there is none. Callers that arrive
    /// while one is starting wait for that launch rather than starting a
    /// second.
    private func current() async throws -> Running {
        while true {
            // A helper still shutting down must be gone before another starts.
            await retiring?.value

            if let running {
                if running.process.isRunning { return running }
                retire(running) // it has exited; clear it away, then look again
                continue
            }
            if let starting {
                return try await outcome(of: starting.task)
            }

            let id = UUID()
            let task = Task { () async throws -> Running in
                // Freed when the launch ends, by the launch itself, so no
                // waiter can find a finished launch still in the slot.
                defer { if self.starting?.id == id { self.starting = nil } }
                let helper = try await self.launch()
                self.running = helper
                return helper
            }
            starting = (id, task)
            return try await outcome(of: task)
        }
    }

    /// What a launch came to. A launch cancelled by `stop()` is reported to
    /// callers that were not themselves cancelled as the helper having been
    /// stopped, which is what it is.
    private func outcome(of launch: Task<Running, Error>) async throws -> Running {
        do {
            return try await launch.value
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            throw TorrentEngineError.helperUnavailable
        }
    }

    /// Takes a helper out of service: forgets it, stops it, waits for it to
    /// exit and closes its connections. Queued behind earlier retirements.
    private func retire(_ old: Running) {
        if running?.id == old.id { running = nil }
        let previous = retiring
        retiring = Task {
            await previous?.value
            old.process.stop()
            _ = await old.process.waitForExit()
            old.client.invalidate()
        }
    }

    /// Starts a helper, trying again with new ports if another process took
    /// one in the moment between choosing it and the helper binding it.
    private func launch() async throws -> Running {
        var detail = ""
        for _ in 0..<3 {
            do {
                return try await launchOnce()
            } catch LaunchAttempt.portTaken(let output) {
                detail = output
            }
        }
        throw TorrentEngineError.helperFailedToStart(detail)
    }

    private func launchOnce() async throws -> Running {
        let activeOptions = await optionsProvider?() ?? options
        let apiPort: UInt16
        let peerPort: UInt16
        let secret: String
        do {
            var chosenAPI = try LoopbackHelper.freePort()
            if let fixedPeer = activeOptions.peerPort, TorrentHelperConfig.listenPortRange.contains(Int(fixedPeer)) {
                var tries = 0
                while chosenAPI == fixedPeer && tries < 10 {
                    chosenAPI = try LoopbackHelper.freePort()
                    tries += 1
                }
                guard chosenAPI != fixedPeer else { throw LoopbackHelper.Failure.noFreePort }
                peerPort = fixedPeer
            } else {
                var candidate = try LoopbackHelper.freePort()
                var tries = 0
                while candidate == chosenAPI && tries < 10 {
                    candidate = try LoopbackHelper.freePort()
                    tries += 1
                }
                guard candidate != chosenAPI else { throw LoopbackHelper.Failure.noFreePort }
                peerPort = candidate
            }
            apiPort = chosenAPI
            secret = try LoopbackHelper.randomSecret()
            try FileManager.default.createDirectory(at: activeOptions.sessionDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: activeOptions.defaultOutputFolder, withIntermediateDirectories: true)
        } catch {
            throw TorrentEngineError.helperFailedToStart("it could not be prepared to start: \(error.localizedDescription)")
        }

        let spec = ManagedProcessSpec(
            executable: activeOptions.executable,
            arguments: Self.launchArguments(
                apiPort: apiPort, peerPort: peerPort,
                sessionDirectory: activeOptions.sessionDirectory,
                defaultOutputFolder: activeOptions.defaultOutputFolder,
                uploadLimit: activeOptions.uploadLimit, downloadLimit: activeOptions.downloadLimit,
                enableUPnP: activeOptions.enableUPnP,
                enableLSD: activeOptions.enableLSD,
                persistDHT: activeOptions.persistDHT,
                extra: activeOptions.extraArguments),
            // The secret travels in the environment, as rqbit requires; the
            // control port itself is loopback-only.
            environment: ["RQBIT_HTTP_BASIC_AUTH_USERPASS": "\(RqbitClient.user):\(secret)"],
            stopGrace: 5,
            stderrTailBytes: 8192,
            label: "rqbit"
        )

        let process: ManagedProcess
        do {
            process = try supervisor.launch(spec)
        } catch ManagedProcessError.executableNotFound(let path) {
            throw TorrentEngineError.helperMissing(path: path)
        } catch {
            throw TorrentEngineError.helperFailedToStart(error.localizedDescription)
        }

        // From here a helper exists. However this ends other than with it
        // serving, it is stopped and gone before this returns or throws, so
        // a cancelled or failed launch can never leave one behind.
        let client = RqbitClient(
            baseURL: URL(string: "http://127.0.0.1:\(apiPort)")!, secret: secret, configuration: clientConfiguration)
        do {
            try await waitUntilAnswering(client, process: process, timeout: activeOptions.startTimeout)
            // stop() may have cancelled this after the helper answered and
            // before this resumed. Nothing suspends between this check and
            // the caller recording the helper, so a stop cannot slip in after.
            try Task.checkCancellation()
            let launchedConfig = TorrentHelperConfig(
                uploadLimitBytesPerSecond: activeOptions.uploadLimit,
                listenPort: activeOptions.peerPort,
                enableUPnP: activeOptions.enableUPnP,
                enableLSD: activeOptions.enableLSD,
                persistDHT: activeOptions.persistDHT
            )
            return Running(process: process, client: client, launchedConfig: launchedConfig)
        } catch LaunchAttempt.portTaken(let output) {
            client.invalidate()
            process.stop()
            _ = await process.waitForExit()
            // If the user pinned a fixed peer port and the collision wasn't on
            // our randomly chosen loopback API port, fail fast with an
            // actionable message instead of retrying the same occupied port 3x.
            if let fixedPeer = activeOptions.peerPort,
               TorrentHelperConfig.listenPortRange.contains(Int(fixedPeer)),
               !output.contains("127.0.0.1:\(apiPort)") {
                throw TorrentEngineError.helperFailedToStart(
                    "Port \(fixedPeer) is already in use. Choose another port or set it to 0 in Settings → Torrents."
                )
            }
            throw LaunchAttempt.portTaken(output)
        } catch {
            client.invalidate()
            process.stop()
            _ = await process.waitForExit()
            throw error
        }
    }

    private func waitUntilAnswering(_ client: RqbitClient, process: ManagedProcess, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !process.isRunning {
                // Let its last words arrive before reading them.
                _ = await process.waitForExit(timeout: 1)
                let output = process.stderrText
                // Looked for in everything it printed, not just the tail that
                // is shown: more lines can follow the one that matters.
                if output.contains("Address already in use") {
                    throw LaunchAttempt.portTaken(Self.lastLines(of: output))
                }
                throw TorrentEngineError.helperFailedToStart(Self.lastLines(of: output))
            }
            do {
                try await client.ping()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not answering yet.
            }
            if Date() >= deadline {
                throw TorrentEngineError.helperFailedToStart(
                    "it did not answer within \(Int(timeout)) seconds")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The tail of what the helper printed: enough to say why, short enough
    /// to show.
    private static func lastLines(of text: String, count: Int = 6) -> String {
        text.split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }
}
