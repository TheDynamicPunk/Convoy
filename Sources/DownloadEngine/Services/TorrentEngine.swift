import Foundation

/// Where a torrent being added comes from.
public enum TorrentSource: Equatable, Sendable {
    /// A magnet link, exactly as it was given. Its trackers travel with it.
    case magnet(String)
    case torrentFile(Data)
}

/// What the engine knows about a torrent it has been given.
public struct TorrentDetails: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        /// Path components below the torrent's folder.
        public let path: [String]
        public let length: Int64
        /// Whether it is among the files being downloaded.
        public let isIncluded: Bool
        /// BEP 47 padding entry (`attr` containing `"p"`). Kept in `files` so
        /// file indexes stay aligned with the engine's `only_files` and
        /// `file_progress`, but hidden from user-facing file pickers and counts.
        public let isPadding: Bool

        public init(path: [String], length: Int64, isIncluded: Bool, isPadding: Bool = false) {
            self.path = path
            self.length = length
            self.isIncluded = isIncluded
            self.isPadding = isPadding
        }

        public var displayPath: String { path.joined(separator: "/") }

        /// True for explicit BEP 47 padding entries and conventional `.pad` /
        /// BitComet padding paths reported by engines that omit `attr`.
        public var isHiddenPadding: Bool {
            if isPadding { return true }
            if path.first == ".pad" { return true }
            if let last = path.last, last.hasPrefix("____padding_file_") { return true }
            return false
        }
    }

    public let infoHash: TorrentInfoHash
    public let name: String
    /// The folder the engine writes this torrent's files into.
    public let outputFolder: URL
    public let files: [File]

    public init(infoHash: TorrentInfoHash, name: String, outputFolder: URL, files: [File]) {
        self.infoHash = infoHash
        self.name = name
        self.outputFolder = outputFolder
        self.files = files
    }
}

/// How a torrent is doing right now.
public struct TorrentSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Starting up, or checking data that is already on disk.
        case initializing
        /// Transferring, or waiting for peers.
        case downloading
        /// Everything wanted is here and the engine is still serving it.
        case seeding
        case paused
        /// The engine gave up on it; carries the engine's own description.
        case error(String)
    }

    public var state: State
    /// Bytes of the wanted pieces that are here and checked.
    public var downloadedBytes: Int64
    /// Bytes of the pieces that cover the wanted files. A piece can straddle
    /// a skipped file, so this can exceed the files' own total.
    public var totalBytes: Int64
    public var uploadedBytes: Int64
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double
    public var connectedPeers: Int
    public var connectedSeeds: Int
    /// Peers heard of, connected or not.
    public var seenPeers: Int
    /// Bytes downloaded of each file, in the torrent's file order.
    public var fileProgress: [Int64]
    /// Optional MSB-first piece bitfield (BEP 3 / rqbit `/haves`) for drawing
    /// the live piece map in `SegmentBar`.
    public var pieceBitfield: Data?

    public init(
        state: State,
        downloadedBytes: Int64,
        totalBytes: Int64,
        uploadedBytes: Int64,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        connectedPeers: Int,
        connectedSeeds: Int,
        seenPeers: Int,
        fileProgress: [Int64],
        pieceBitfield: Data? = nil
    ) {
        self.state = state
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.uploadedBytes = uploadedBytes
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.connectedPeers = connectedPeers
        self.connectedSeeds = connectedSeeds
        self.seenPeers = seenPeers
        self.fileProgress = fileProgress
        self.pieceBitfield = pieceBitfield
    }
}

public enum TorrentEngineError: Error, Equatable {
    /// The engine's executable is not installed at this path.
    case helperMissing(path: String)
    /// It started and then did not come up; carries what it printed.
    case helperFailedToStart(String)
    /// It was running and has stopped answering. The next call starts a new one.
    case helperUnavailable
    /// The engine refused the request and said why.
    case rejected(String)
    case notFound
    /// The engine already has this torrent, writing into another folder, and
    /// it did not move. A caller that wants the torrent elsewhere has to
    /// remove it first.
    case alreadyAdded(existingFolder: URL)
    case timedOut
    case unexpectedResponse(String)
}

extension TorrentEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .helperMissing: return "The torrent engine is not installed."
        case .helperFailedToStart(let detail):
            return detail.isEmpty ? "The torrent engine did not start." : "The torrent engine did not start: \(detail)"
        case .helperUnavailable: return "The torrent engine stopped responding."
        case .rejected(let reason): return reason
        case .notFound: return "The torrent is not known to the engine."
        case .alreadyAdded(let folder): return "This torrent is already downloading to \(folder.path)."
        case .timedOut: return "The torrent engine took too long to answer."
        case .unexpectedResponse(let detail): return "The torrent engine gave an unexpected answer: \(detail)"
        }
    }
}

/// Snapshot of the launch-time BitTorrent helper settings that require a
/// helper restart when changed while `rqbit` is already running.
public struct TorrentHelperConfig: Equatable, Sendable {
    /// Ports accepted for peer connections. Below 1024 needs privileges.
    public static let listenPortRange: ClosedRange<Int> = 1024...65535

    /// The highest upload limit, in KB/s. rqbit takes the limit as a non-zero
    /// 32-bit count of bytes per second (9.1.0 refuses 4294967296 with "number
    /// too large"), so a higher limit would stop the helper from starting.
    public static let maxUploadLimitKBps = Int(UInt32.max) / 1024

    /// The limit as bytes per second for rqbit, or nil for none (0 or below),
    /// held to what rqbit accepts.
    public static func uploadBytesPerSecond(forKBps kbps: Int) -> Int? {
        kbps > 0 ? min(kbps, maxUploadLimitKBps) * 1024 : nil
    }

    /// The stored port as a fixed one, or nil to let the helper take a free
    /// port each time it starts (0, or anything outside `listenPortRange`).
    public static func fixedPort(from stored: Int) -> UInt16? {
        listenPortRange.contains(stored) ? UInt16(stored) : nil
    }

    public var uploadLimitBytesPerSecond: Int?
    public var listenPort: UInt16?
    public var enableUPnP: Bool
    public var enableLSD: Bool
    public var persistDHT: Bool

    public init(
        uploadLimitBytesPerSecond: Int? = nil,
        listenPort: UInt16? = nil,
        enableUPnP: Bool = false,
        enableLSD: Bool = false,
        persistDHT: Bool = false
    ) {
        self.uploadLimitBytesPerSecond = uploadLimitBytesPerSecond
        self.listenPort = listenPort
        self.enableUPnP = enableUPnP
        self.enableLSD = enableLSD
        self.persistDHT = persistDHT
    }

    @MainActor
    public static func current(from settings: AppSettings) -> TorrentHelperConfig {
        let uploadBytes = uploadBytesPerSecond(forKBps: settings.torrentUploadLimitKBps)
        let fixedPort = fixedPort(from: settings.torrentListenPort)
        return TorrentHelperConfig(
            uploadLimitBytesPerSecond: uploadBytes,
            listenPort: fixedPort,
            enableUPnP: settings.torrentEnableUPnP,
            enableLSD: settings.torrentEnableLSD,
            persistDHT: settings.torrentPersistDHT
        )
    }
}

/// The torrent engine as the rest of the app sees it.
///
/// Torrents are named by their info hash, not by any id the engine assigns,
/// so a torrent can be found again after the engine restarts, and a task that
/// stored the hash needs nothing else to reattach to it.
protocol TorrentEngine: Sendable {
    /// The `.torrent` for a magnet link, fetched from the swarm. Can take as
    /// long as peers take to answer; cancelling the calling task abandons it.
    func probe(magnet: String) async throws -> TorrentFile

    /// Starts a torrent writing into `folder`. `files` is the set of file
    /// indexes to download, or nil for all of them.
    ///
    /// Choosing files follows one rule, here and in `setSelectedFiles`: an
    /// empty set, or an index the torrent has no file for, is refused with
    /// `.rejected`, and a refusal changes nothing (no torrent is added, no file
    /// is created). Choosing no files is not a way to stop a download; that is
    /// `pause`.
    ///
    /// If the engine already has this torrent in the same folder this returns
    /// it unchanged; in another folder it throws `.alreadyAdded`. Files that
    /// already exist at the targets are never overwritten: the add is
    /// refused with `.rejected` instead.
    func add(_ source: TorrentSource, into folder: URL, files: Set<Int>?) async throws -> TorrentDetails

    func details(of torrent: TorrentInfoHash) async throws -> TorrentDetails
    /// Changes which files are downloaded. Same rule as in `add`.
    func setSelectedFiles(_ files: Set<Int>, of torrent: TorrentInfoHash) async throws
    func snapshot(of torrent: TorrentInfoHash) async throws -> TorrentSnapshot
    func pause(_ torrent: TorrentInfoHash) async throws
    func resume(_ torrent: TorrentInfoHash) async throws

    /// Stops and forgets the torrent. Its files stay on disk unless
    /// `deleteData` is true.
    func remove(_ torrent: TorrentInfoHash, deleteData: Bool) async throws

    /// Optional MSB-first bitfield of completed pieces for the progress bar.
    func pieceBitfield(of torrent: TorrentInfoHash) async -> Data?

    /// The launch-time config of the currently running helper, or `nil` when
    /// no helper process is running.
    func activeHelperConfig() async -> TorrentHelperConfig?

    /// Stops any underlying helper process so the next call starts a fresh one.
    func stop() async
}

extension TorrentEngine {
    func pieceBitfield(of torrent: TorrentInfoHash) async -> Data? { nil }
    func activeHelperConfig() async -> TorrentHelperConfig? { nil }
    func stop() async {}

    /// A snapshot now and then every `interval`, until the torrent is removed
    /// (the stream then ends normally), an error occurs (it ends with that
    /// error) or the consumer stops listening.
    ///
    /// Only the latest snapshot is kept for a consumer that is behind: a
    /// snapshot is a state, not an event, and an unbounded queue would grow
    /// for as long as nobody was reading it.
    ///
    /// One implementation for every engine, so the fake that tests run
    /// against cannot behave differently from the real adapter here.
    func updates(
        of torrent: TorrentInfoHash,
        every interval: Duration = .seconds(1)
    ) -> AsyncThrowingStream<TorrentSnapshot, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        var snap = try await self.snapshot(of: torrent)
                        if snap.state == .downloading, snap.pieceBitfield == nil {
                            snap.pieceBitfield = await self.pieceBitfield(of: torrent)
                        }
                        continuation.yield(snap)
                    } catch TorrentEngineError.notFound {
                        continuation.finish()
                        return
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                    do { try await Task.sleep(for: interval) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
