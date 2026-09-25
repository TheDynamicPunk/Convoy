import Foundation
import OSLog

/// Why a join refused to produce a file.
public enum SegmentMergeError: LocalizedError {
    case partMissing(index: Int)
    case partShort(index: Int, expected: Int64, actual: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case notEnoughSpace(needed: Int64)
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .partMissing(let index):
            return "Couldn't put this download together: part \(index + 1) is missing."
        case .partShort(let index, let expected, let actual):
            return "Couldn't put this download together: part \(index + 1) holds \(actual) of \(expected) bytes."
        case .sizeMismatch(let expected, let actual):
            return "Couldn't put this download together: it came to \(actual) bytes, not the expected \(expected)."
        case .notEnoughSpace(let needed):
            let short = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Not enough space to finish this download — it needs \(short) more."
        case .cannotWrite(let url):
            return "Could not write to \(url.deletingLastPathComponent().path)."
        }
    }
}

/// Joins a byte-range download's part files into one file, off the main
/// thread. Never deletes the parts: they are the only copy until
/// `DownloadTask` has moved the result into place.
enum SegmentMerge {
    /// One part file and the number of bytes it owns.
    struct Part: Sendable {
        let index: Int
        let url: URL
        /// Bytes this part contributes. Part 0's file can hold probe bytes
        /// past its range, so the join never copies to EOF.
        let size: Int64
    }

    private static let bufferSize = 8 * 1024 * 1024

    /// Its own queue: the copy blocks, and the cooperative pool is small.
    private static let queue = DispatchQueue(label: "Convoy.segment-merge", qos: .utility,
                                             attributes: .concurrent)

    private static let logger = Logger(subsystem: "Convoy", category: "SegmentMerge")

    /// Joins `parts` in index order into `scratch`. Fails on a missing or
    /// short part, a failed read, or a total other than `expectedTotal`, and
    /// leaves no scratch file behind when it does.
    static func join(_ parts: [Part], into scratch: URL, expectedTotal: Int64,
                     cancellation: MergeCancellation? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try joinNow(parts, into: scratch, expectedTotal: expectedTotal,
                                cancellation: cancellation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The join itself, blocking. Called on `queue`, and directly by tests.
    static func joinNow(_ parts: [Part], into scratch: URL, expectedTotal: Int64,
                        cancellation: MergeCancellation? = nil) throws {
        let fm = FileManager.default

        // Check every part before copying anything.
        for part in parts {
            guard let size = (try? fm.attributesOfItem(atPath: part.url.path))?[.size] as? Int64 else {
                throw SegmentMergeError.partMissing(index: part.index)
            }
            guard size >= part.size else {
                throw SegmentMergeError.partShort(index: part.index, expected: part.size, actual: size)
            }
        }

        try? fm.removeItem(at: scratch)
        guard fm.createFile(atPath: scratch.path, contents: nil),
              let out = try? FileHandle(forWritingTo: scratch) else {
            throw SegmentMergeError.cannotWrite(scratch)
        }

        var written: Int64 = 0
        do {
            for part in parts {
                let input = try FileHandle(forReadingFrom: part.url)
                defer { try? input.close() }

                var remaining = part.size
                while remaining > 0 {
                    if cancellation?.isCancelled == true { throw DownloadError.cancelled }
                    let want = Int(min(remaining, Int64(bufferSize)))
                    // Throws on a failed read; an early EOF is a short part.
                    guard let chunk = try input.read(upToCount: want), !chunk.isEmpty else {
                        throw SegmentMergeError.partShort(index: part.index, expected: part.size,
                                                          actual: part.size - remaining)
                    }
                    try out.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                    written += Int64(chunk.count)
                }
            }
            try out.close()

            guard expectedTotal <= 0 || written == expectedTotal else {
                throw SegmentMergeError.sizeMismatch(expected: expectedTotal, actual: written)
            }
            // Before the caller moves it into place and deletes the parts.
            FileDurability.flush(scratch)
        } catch {
            try? out.close()
            try? fm.removeItem(at: scratch)
            throw error
        }

        logger.notice("Joined \(parts.count, privacy: .public) parts into \(written, privacy: .public) bytes")
    }

    /// Refuses up front when the destination's volume can't hold another
    /// `bytes` — the parts stay until the joined file is in place. A volume
    /// that won't report its free space is allowed to try.
    static func ensureSpace(forWriting bytes: Int64, at destination: URL) throws {
        guard bytes > 0 else { return }
        let folder = destination.deletingLastPathComponent()
        guard let available = try? folder.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else { return }
        guard available < bytes else { return }
        throw SegmentMergeError.notEnoughSpace(needed: bytes - available)
    }
}

/// A one-way stop flag for a join in flight, raised by pause() and cancel().
final class MergeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool { lock.withLock { _isCancelled } }
    func cancel() { lock.withLock { _isCancelled = true } }
}
