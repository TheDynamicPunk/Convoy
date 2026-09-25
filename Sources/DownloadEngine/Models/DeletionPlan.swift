import Foundation

/// What deleting one download actually costs, which is not what its status
/// alone suggests.
///
/// A finished download's file is never touched unless the person explicitly
/// opts in, so removing its row costs nothing. Everything unfinished —
/// `.failed` very much included, since `retryFailed` resumes from the same
/// on-disk segments in place — has its temp files wiped by
/// `DownloadTask.cleanupTempFiles()` on the way out, and those bytes are
/// unrecoverable. That asymmetry is the whole reason the confirmation exists.
public enum DeletionImpact: Sendable, Equatable {
    /// Completed, file still on disk. `bytes` is what trashing it would free.
    case finishedFile(bytes: Int64)
    /// Completed, but the file has already been moved or deleted elsewhere.
    case finishedFileMissing
    /// Unfinished, with partial bytes on disk that deletion discards.
    case discardsProgress(bytes: Int64)
    /// Nothing on disk either way — queued, never started, or already cancelled.
    case nothingToLose
}

/// The classified consequences of one delete request, shared by every entry
/// point (single row, multi-selection, whole category) so they can't drift
/// apart in what they tell the person.
@MainActor
public struct DeletionPlan {
    public struct Item: Identifiable {
        public let id: DownloadTask.ID
        public let filename: String
        public let impact: DeletionImpact
        /// Drives the retry-specific wording: a failed download's partial
        /// bytes are resumable, so discarding them costs more than "failed"
        /// implies.
        public let isFailed: Bool
        /// Display name of the folder the finished file sits in, so the copy
        /// can name where it's being left behind. Nil for unfinished tasks.
        public let folderName: String?
    }

    public let items: [Item]

    public init(tasks: [DownloadTask]) {
        items = tasks.map { task in
            let isFailed: Bool
            if case .failed = task.status { isFailed = true } else { isFailed = false }
            let impact = Self.impact(of: task)
            let folderName: String? = {
                guard case .finishedFile = impact else { return nil }
                return task.destinationURL.deletingLastPathComponent().lastPathComponent
            }()
            return Item(
                id: task.id,
                filename: task.filename,
                impact: impact,
                isFailed: isFailed,
                folderName: folderName
            )
        }
    }

    private static func impact(of task: DownloadTask) -> DeletionImpact {
        guard task.status == .completed else {
            return task.downloadedBytes > 0
                ? .discardsProgress(bytes: task.downloadedBytes)
                : .nothingToLose
        }
        // Reading the size doubles as the existence check — a file that's
        // been moved or deleted since it finished has nothing to offer.
        guard let values = try? task.destinationURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return .finishedFileMissing
        }
        return .finishedFile(bytes: Int64(size))
    }

    // MARK: - Aggregates

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    /// The only item, when there's exactly one — the copy is meaningfully
    /// different (and much more specific) in that case.
    public var single: Item? { items.count == 1 ? items.first : nil }

    /// True when every item costs nothing to delete — no bytes on disk to
    /// discard, and no finished file to decide the fate of. When this holds,
    /// the confirmation sheet has nothing to say beyond "deleted", so the
    /// caller skips it entirely rather than prompting for a decision that
    /// has no real content.
    public var isTriviallyDeletable: Bool {
        items.allSatisfy { item in
            switch item.impact {
            case .nothingToLose, .finishedFileMissing: return true
            case .finishedFile, .discardsProgress: return false
            }
        }
    }

    /// Finished downloads whose file is still on disk, i.e. the ones the
    /// Trash opt-in can actually act on.
    public var trashableCount: Int {
        items.filter { if case .finishedFile = $0.impact { return true } else { return false } }.count
    }

    public var trashableBytes: Int64 {
        items.reduce(0) { total, item in
            if case .finishedFile(let bytes) = item.impact { return total + bytes }
            return total
        }
    }

    public var progressDiscardingCount: Int {
        items.filter { if case .discardsProgress = $0.impact { return true } else { return false } }.count
    }

    public var progressDiscardingBytes: Int64 {
        items.reduce(0) { total, item in
            if case .discardsProgress(let bytes) = item.impact { return total + bytes }
            return total
        }
    }
}

/// What a completed delete actually managed to do. Trash failures are
/// reported rather than thrown: the rows always leave the list, so the caller
/// needs to say what couldn't be trashed without implying nothing happened.
public struct DeletionOutcome: Sendable {
    public let removedCount: Int
    public let trashedCount: Int
    public let trashFailureCount: Int

    public init(removedCount: Int, trashedCount: Int, trashFailureCount: Int) {
        self.removedCount = removedCount
        self.trashedCount = trashedCount
        self.trashFailureCount = trashFailureCount
    }
}
