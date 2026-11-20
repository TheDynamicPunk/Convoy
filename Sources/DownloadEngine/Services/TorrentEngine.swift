import Foundation

/// Where a torrent being added comes from.
enum TorrentSource: Equatable, Sendable {
    /// A magnet link, exactly as it was given. Its trackers travel with it.
    case magnet(String)
    case torrentFile(Data)
}

/// What the engine knows about a torrent it has been given.
struct TorrentDetails: Equatable, Sendable {
    struct File: Equatable, Sendable {
        /// Path components below the torrent's folder.
        let path: [String]
        let length: Int64
        /// Whether it is among the files being downloaded.
        let isIncluded: Bool
    }

    let infoHash: TorrentInfoHash
    let name: String
    /// The folder the engine writes this torrent's files into.
    let outputFolder: URL
    let files: [File]
}

/// How a torrent is doing right now.
struct TorrentSnapshot: Equatable, Sendable {
    enum State: Equatable, Sendable {
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

    var state: State
    /// Bytes of the wanted pieces that are here and checked.
    var downloadedBytes: Int64
    /// Bytes of the pieces that cover the wanted files. A piece can straddle
    /// a skipped file, so this can exceed the files' own total.
    var totalBytes: Int64
    var uploadedBytes: Int64
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var connectedPeers: Int
    var connectedSeeds: Int
    /// Peers heard of, connected or not.
    var seenPeers: Int
    /// Bytes downloaded of each file, in the torrent's file order.
    var fileProgress: [Int64]
}

enum TorrentEngineError: Error, Equatable {
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
    var errorDescription: String? {
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
}

extension TorrentEngine {
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
                        continuation.yield(try await self.snapshot(of: torrent))
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
