import Foundation
@testable import DownloadEngine

/// A torrent engine with no network and no process, for tests of everything
/// that sits above one.
///
/// It is held to the same `TorrentEngineContractTests` the real adapter is,
/// so what it does on `add`, `remove` and a repeated `add` is what the real
/// engine was seen to do (see the plan, 14.2 and the captured responses), not
/// what is convenient. Beyond that it is scriptable: `makeResolvable` says
/// which magnet links "find peers", and `simulate` bends a torrent's snapshot
/// to whatever a test needs.
final class FakeTorrentEngine: TorrentEngine, @unchecked Sendable {

    private struct Entry {
        let file: TorrentFile
        let folder: URL
        var included: Set<Int>
        var isPaused = false
        var createdFiles: [URL] = []
        var overrides: [(inout TorrentSnapshot) -> Void] = []
    }

    private let lock = NSLock()
    private var entries: [TorrentInfoHash: Entry] = [:]
    private var magnets: [String: TorrentFile] = [:]

    /// Runs `body` holding the lock. The lock calls live in a synchronous
    /// function so the async protocol methods below never call them directly.
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    /// Makes a magnet link resolvable: `probe` and `add` of a magnet with this
    /// info hash behave as if peers were found and sent this metadata.
    func makeResolvable(_ file: TorrentFile) {
        locked { magnets[file.infoHash.hex] = file }
    }

    /// Changes what `snapshot` reports for a torrent from now on, on top of
    /// the defaults and of earlier calls.
    func simulate(_ torrent: TorrentInfoHash, _ change: @escaping (inout TorrentSnapshot) -> Void) {
        locked { entries[torrent]?.overrides.append(change) }
    }

    // MARK: - TorrentEngine

    func probe(magnet: String) async throws -> TorrentFile {
        let parsed: MagnetURI
        do { parsed = try MagnetURI(magnet) } catch { throw TorrentEngineError.rejected("\(error)") }
        return try locked {
            guard let file = magnets[parsed.infoHash.hex] else {
                throw TorrentEngineError.rejected("no known way to resolve peers")
            }
            return file
        }
    }

    func add(_ source: TorrentSource, into folder: URL, files: Set<Int>?) async throws -> TorrentDetails {
        let file: TorrentFile
        switch source {
        case .torrentFile(let data):
            do { file = try TorrentFile(data) } catch { throw TorrentEngineError.rejected("error decoding torrent: \(error)") }
        case .magnet(let text):
            file = try await probe(magnet: text)
        }
        return try locked { try addLocked(file, into: folder, files: files) }
    }

    func details(of torrent: TorrentInfoHash) async throws -> TorrentDetails {
        try locked { Self.details(of: try entry(torrent)) }
    }

    func setSelectedFiles(_ files: Set<Int>, of torrent: TorrentInfoHash) async throws {
        try locked {
            var entry = try entry(torrent)
            try Self.validate(selection: files, fileCount: entry.file.files.count)
            for index in files.subtracting(entry.included).sorted() {
                let target = Self.target(of: entry.file, index: index, in: entry.folder)
                if !FileManager.default.fileExists(atPath: target.path) {
                    try Self.createFile(at: target, length: entry.file.files[index].length)
                    entry.createdFiles.append(target)
                }
            }
            entry.included = files
            entries[torrent] = entry
        }
    }

    func snapshot(of torrent: TorrentInfoHash) async throws -> TorrentSnapshot {
        try locked {
            let entry = try entry(torrent)
            var snapshot = TorrentSnapshot(
                state: entry.isPaused ? .paused : .downloading,
                downloadedBytes: 0,
                totalBytes: entry.file.files.indices.filter(entry.included.contains)
                    .reduce(0) { $0 + entry.file.files[$1].length },
                uploadedBytes: 0,
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                connectedPeers: 0,
                connectedSeeds: 0,
                seenPeers: 0,
                fileProgress: Array(repeating: 0, count: entry.file.files.count)
            )
            for change in entry.overrides { change(&snapshot) }
            return snapshot
        }
    }

    func pause(_ torrent: TorrentInfoHash) async throws {
        try locked {
            var entry = try entry(torrent)
            entry.isPaused = true
            entries[torrent] = entry
        }
    }

    func resume(_ torrent: TorrentInfoHash) async throws {
        try locked {
            var entry = try entry(torrent)
            entry.isPaused = false
            entries[torrent] = entry
        }
    }

    func remove(_ torrent: TorrentInfoHash, deleteData: Bool) async throws {
        try locked {
            let entry = try entry(torrent)
            if deleteData {
                for url in entry.createdFiles { try? FileManager.default.removeItem(at: url) }
            }
            entries[torrent] = nil
        }
    }

    // MARK: - Internals (call with the lock held)

    private func entry(_ torrent: TorrentInfoHash) throws -> Entry {
        guard let entry = entries[torrent] else { throw TorrentEngineError.notFound }
        return entry
    }

    private func addLocked(_ file: TorrentFile, into folder: URL, files: Set<Int>?) throws -> TorrentDetails {
        // Refused before anything exists, so a refusal leaves nothing behind.
        if let files { try Self.validate(selection: files, fileCount: file.files.count) }

        if let existing = entries[file.infoHash] {
            // The engine hands back the torrent it already has, wherever that
            // is, and does not move it.
            guard Self.same(existing.folder, folder) else {
                throw TorrentEngineError.alreadyAdded(existingFolder: existing.folder)
            }
            return Self.details(of: existing)
        }

        let included = files ?? Set(file.files.indices)
        let wanted = file.files.indices.filter(included.contains)
        let targets = wanted.map { Self.target(of: file, index: $0, in: folder) }

        // Existing files are never touched: refuse before creating anything.
        if let clash = targets.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw TorrentEngineError.rejected(
                "error adding torrent: error creating a new file (because allow_overwrite = false) \"\(clash.path)\": File exists (os error 17)")
        }

        var entry = Entry(file: file, folder: folder, included: included)
        for (index, target) in zip(wanted, targets) {
            try Self.createFile(at: target, length: file.files[index].length)
            entry.createdFiles.append(target)
        }
        entries[file.infoHash] = entry
        return Self.details(of: entry)
    }

    /// The one rule for choosing files, shared by `add` and `setSelectedFiles`
    /// and held to the real engine by the contract suite: choosing no files, or
    /// a file the torrent does not have, is refused.
    private static func validate(selection files: Set<Int>, fileCount: Int) throws {
        if files.isEmpty { throw TorrentEngineError.rejected("No files were selected.") }
        if let bad = files.sorted().first(where: { !(0..<fileCount).contains($0) }) {
            throw TorrentEngineError.rejected("file id \(bad) is out of range")
        }
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    private static func target(of file: TorrentFile, index: Int, in folder: URL) -> URL {
        file.files[index].path.reduce(folder) { $0.appendingPathComponent($1) }
    }

    /// A file at its full length from the start, as the real engine writes it.
    private static func createFile(at url: URL, length: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TorrentEngineError.rejected("could not create \(url.path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(length))
    }

    private static func details(of entry: Entry) -> TorrentDetails {
        TorrentDetails(
            infoHash: entry.file.infoHash,
            name: entry.file.name,
            outputFolder: entry.folder,
            files: entry.file.files.enumerated().map { index, file in
                TorrentDetails.File(path: file.path, length: file.length, isIncluded: entry.included.contains(index))
            }
        )
    }
}
