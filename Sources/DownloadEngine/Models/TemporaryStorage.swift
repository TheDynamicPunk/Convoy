import Foundation

/// Leftovers this app has in the system temp folder that no download can ever
/// use again.
///
/// Only orphans. Files belonging to a download that still exists are not
/// "temporary files" from anyone's point of view — they are that download's
/// progress, and a paused download resumes from exactly those bytes. They are
/// not reported, not totalled, and not offered, so no control in the app can
/// destroy resumable progress by being pressed.
///
/// Orphan means one thing in this app: no task in the list claims this id.
/// The Settings control and the size notice both come through here, on the
/// same known ids and the same filename shapes.
///
/// Nothing deletes these automatically. A row's own files go when the row
/// goes; what a crashed run stranded stays until someone clears it, which is
/// what the notice exists to prompt.
public struct TemporaryStorageReport: Sendable {
    public struct Entry: Sendable {
        public let url: URL
        public let bytes: Int64
        /// The download this was named for. Nil when the name carries no
        /// readable id — which makes it an orphan by definition.
        public let taskID: UUID?
    }

    public let orphaned: [Entry]

    public var totalBytes: Int64 { orphaned.reduce(0) { $0 + $1.bytes } }
    public var isEmpty: Bool { orphaned.isEmpty }
}

/// Finds and removes this app's unreachable leftovers in the temp folder.
public enum TemporaryStorage {

    /// Loose per-segment files, named `<task id>-segment-<n>.tmp` beside the
    /// scratch directories rather than inside one.
    private static let segmentMarker = "-segment-"

    /// Measures what this app has left in `container` that nothing can claim.
    ///
    /// `knownTaskIDs` is every download still in the list, finished included.
    ///
    /// No time boundary: nothing here deletes on its own any more. The only
    /// caller that deletes is the Settings button, and it re-derives the known
    /// ids at the moment of deleting rather than trusting this report's age.
    ///
    /// Pure filesystem work, and not actor-isolated: sizing a scratch
    /// directory walks every segment file in it, and there can be hundreds.
    public static func report(
        knownTaskIDs: Set<UUID>,
        in container: URL = FileManager.default.temporaryDirectory
    ) -> TemporaryStorageReport {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: container.path) else {
            return TemporaryStorageReport(orphaned: [])
        }

        var orphaned: [TemporaryStorageReport.Entry] = []
        for name in names {
            guard let leftover = classify(name) else { continue }
            // Claimed by a download that still exists — not ours to touch,
            // whether it is running, paused or finished.
            if let id = leftover.taskID, knownTaskIDs.contains(id) { continue }

            let url = container.appendingPathComponent(name)
            orphaned.append(.init(url: url, bytes: size(of: url), taskID: leftover.taskID))
        }
        return TemporaryStorageReport(orphaned: orphaned)
    }

    /// Deletes `entries` and returns the bytes actually freed.
    ///
    /// Counts what it managed to remove rather than what it set out to: a file
    /// that vanished between the report and the button should not be reported
    /// to the person as space they got back.
    @discardableResult
    public static func remove(_ entries: [TemporaryStorageReport.Entry]) -> Int64 {
        entries.reduce(0) { freed, entry in
            do {
                try FileManager.default.removeItem(at: entry.url)
                return freed + entry.bytes
            } catch {
                return freed
            }
        }
    }

    // MARK: - Recognising our own leftovers

    private struct Leftover {
        let taskID: UUID?
    }

    /// Whether `name` is something this app left behind. Nil for anything
    /// else — the temp folder belongs to the whole system and is full of files
    /// that are none of our business.
    private static func classify(_ name: String) -> Leftover? {
        for kind in TaskScratchDirectory.allCases where name.hasPrefix(kind.prefix) {
            return Leftover(taskID: kind.taskID(fromDirectoryName: name))
        }
        if isSegmentFile(name) {
            return Leftover(taskID: segmentOwner(of: name))
        }
        return nil
    }

    /// `<task id>-segment-<n>.tmp`, the byte-range engine's per-segment files.
    private static func isSegmentFile(_ name: String) -> Bool {
        name.hasSuffix(".tmp") && name.contains(segmentMarker)
    }

    private static func segmentOwner(of name: String) -> UUID? {
        guard let range = name.range(of: segmentMarker) else { return nil }
        return UUID(uuidString: String(name[..<range.lowerBound]))
    }

    /// Removes every `<task id>-segment-<n>.tmp` file belonging to `taskID`.
    ///
    /// Found by name, not from a task's in-memory segments: segments are not
    /// persisted, so a task restored after relaunch has none, and deleting
    /// from that list left every file but `segment-0`.
    static func removeSegmentFiles(of taskID: UUID, in container: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: container.path) else { return }
        for name in names where isSegmentFile(name) && segmentOwner(of: name) == taskID {
            try? fm.removeItem(at: container.appendingPathComponent(name))
        }
    }

    /// Bytes `url` occupies, walking into it when it is a directory.
    private static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }

        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys)
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in walker {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isDirectory != true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// When to point the user at the Settings control that clears orphans.
///
/// Nothing sweeps automatically, so the only thing standing between a crashed
/// run and permanently used disk is someone noticing. This decides when that
/// is worth saying.
public enum TemporaryStorageNotice {

    /// About two stranded 4K downloads — a 2160p work directory holds both
    /// tracks until the mux finishes. The user can move it in Settings.
    public static let defaultThresholdGB: Double = 1

    /// Doubling steps rather than a fine-grained slider: the difference
    /// between 3 GB and 3.5 GB is not a decision anyone needs to make.
    public static let thresholdChoicesGB: [Double] = [1, 2, 4, 8]

    /// Snaps a stored value onto the offered choices, so a setting written by
    /// an earlier build (or edited by hand) still selects something.
    public static func nearestChoiceGB(to gb: Double) -> Double {
        thresholdChoicesGB.min { abs($0 - gb) < abs($1 - gb) } ?? defaultThresholdGB
    }

    public static func bytes(fromGB gb: Double) -> Int64 {
        Int64(gb * 1_073_741_824)
    }

    /// Decided at launch: shown on every launch while the leftovers are over
    /// the threshold. A dismissal lasts for the session only, so the next
    /// launch asks again while the files are still there.
    public static func shouldShow(orphanedBytes: Int64, thresholdBytes: Int64) -> Bool {
        orphanedBytes >= thresholdBytes
    }

    /// After launch the notice can only go away — once cleared below the
    /// threshold, or once the threshold is raised above them. A measurement
    /// taken later in the session never raises it.
    public static func stillShows(dueAtLaunch: Bool, orphanedBytes: Int64, thresholdBytes: Int64) -> Bool {
        dueAtLaunch && shouldShow(orphanedBytes: orphanedBytes, thresholdBytes: thresholdBytes)
    }
}
