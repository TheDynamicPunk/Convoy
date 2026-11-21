import Foundation

/// How long Convoy continues uploading a torrent after its payload finishes.
///
/// The helper (rqbit) has no ratio or time limits of its own, so Convoy
/// enforces the chosen policy by watching the snapshot counters and calling
/// `engine.remove(_:, deleteData: false)` once the target is met.
public enum SeedingPolicy: Equatable, Sendable {
    /// Stop uploading as soon as the payload completes (the default).
    case stopAtCompletion
    /// Keep seeding until `uploadedBytes / totalBytes` reaches this ratio.
    case untilRatio(Double)
    /// Keep seeding for this many seconds after completion.
    case untilDuration(TimeInterval)
}

/// Everything needed to add a torrent download through `DownloadManager`.
///
/// One parameter value rather than a long parameter list (matching the plan's
/// 3.7 decision), carrying either a magnet link or `.torrent` file bytes, an
/// optional pre-parsed `TorrentFile` (from a `.torrent` file or an already-
/// probed magnet), optional file selection, and destination preferences.
public struct TorrentAddRequest: Sendable {
    public let source: TorrentSource
    /// Pre-parsed metadata when available (always for `.torrent` files, or
    /// after a capture-dialog probe for a magnet). Nil for an unprobed magnet.
    public let metadata: TorrentFile?
    /// Destination parent folder. Nil uses `AppSettings.shared.downloadDirectory`.
    public let destinationFolder: URL?
    /// Explicit folder name chosen by the user, or nil to derive from torrent
    /// metadata / magnet display name.
    public let customName: String?
    /// File indexes to download, or nil to download all files in the torrent.
    public let selectedFiles: Set<Int>?
    /// Whether the person explicitly picked `destinationFolder`.
    public let folderIsExplicit: Bool
    /// Start immediately vs. add paused; nil defers to `AppSettings.autoStartDownloads`.
    public let startAutomatically: Bool?
    public let skipConflictCheck: Bool

    public init(
        source: TorrentSource,
        metadata: TorrentFile? = nil,
        destinationFolder: URL? = nil,
        customName: String? = nil,
        selectedFiles: Set<Int>? = nil,
        folderIsExplicit: Bool = false,
        startAutomatically: Bool? = nil,
        skipConflictCheck: Bool = false
    ) {
        self.source = source
        self.metadata = metadata
        self.destinationFolder = destinationFolder
        self.customName = customName
        self.selectedFiles = selectedFiles
        self.folderIsExplicit = folderIsExplicit
        self.startAutomatically = startAutomatically
        self.skipConflictCheck = skipConflictCheck
    }
}

/// Pure helpers for checking volume free space and translating engine disk
/// errors into plain-English messages.
enum TorrentDiskSpace {

    /// Checks whether the volume hosting `folder` has at least `requiredBytes`
    /// available. Returns a plain user-facing message when short, or `nil`
    /// when space is sufficient (or cannot be queried).
    ///
    /// Checks against the torrent's *total* size rather than just the selected
    /// subset because rqbit v9.1.0 allocates deselected files too (plan 14.6).
    static func insufficientSpaceMessage(
        requiredBytes: Int64,
        at folder: URL,
        availableSpace: ((URL) -> Int64?)? = nil
    ) -> String? {
        guard requiredBytes > 0 else { return nil }
        let queryURL = existingAncestor(of: folder)
        let available: Int64?
        if let availableSpace {
            available = availableSpace(queryURL)
        } else {
            available = try? queryURL.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        }
        guard let available, available < requiredBytes else { return nil }
        let volumeName = (try? queryURL.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? queryURL.lastPathComponent
        return "Not enough space on \(volumeName): needs \(ByteFormat.size(requiredBytes)), has \(ByteFormat.size(available))."
    }

    /// Walks up to the nearest existing ancestor so volume queries work even
    /// before the torrent's own subfolder has been created.
    private static func existingAncestor(of url: URL) -> URL {
        var current = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return current
    }

    /// Detects disk-full messages reported by the engine mid-download.
    static func isDiskFullMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("enospc") || lower.contains("no space left on device")
    }
}

/// Manages Convoy's per-task stored `.torrent` copies under
/// `HelperLocations.torrentsDirectory/<taskID>/source.torrent` so resuming
/// after a relaunch or session reset never depends on the original `.torrent`
/// file remaining where it was opened.
enum TorrentStorage {

    static func taskDirectory(for taskID: UUID, base: URL = HelperLocations.torrentsDirectory) -> URL {
        base.appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    static func storedTorrentURL(for taskID: UUID, base: URL = HelperLocations.torrentsDirectory) -> URL {
        taskDirectory(for: taskID, base: base).appendingPathComponent("source.torrent")
    }

    /// Writes `data` atomically into the task's torrent storage directory and
    /// returns the stored file URL.
    @discardableResult
    static func saveTorrentData(_ data: Data, for taskID: UUID, base: URL = HelperLocations.torrentsDirectory) throws -> URL {
        let dir = taskDirectory(for: taskID, base: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = storedTorrentURL(for: taskID, base: base)
        try data.write(to: target, options: .atomic)
        return target
    }

    /// Reads the stored `.torrent` bytes for `taskID`, if present.
    static func loadTorrentData(for taskID: UUID, base: URL = HelperLocations.torrentsDirectory) -> Data? {
        try? Data(contentsOf: storedTorrentURL(for: taskID, base: base))
    }

    /// Removes the per-task torrent directory (called when a torrent task is
    /// cancelled or deleted).
    static func removeTaskDirectory(for taskID: UUID, base: URL = HelperLocations.torrentsDirectory) {
        try? FileManager.default.removeItem(at: taskDirectory(for: taskID, base: base))
    }
}
