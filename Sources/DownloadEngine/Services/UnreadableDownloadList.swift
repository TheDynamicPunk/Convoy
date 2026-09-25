import Foundation

/// Keeps a download list this build can't read, instead of letting it be
/// overwritten.
///
/// A list written by a build with a different format doesn't decode here. The
/// app then starts empty, and the next save would replace the real list with
/// that empty one. Moving the file aside first means nothing is lost, and the
/// person keeps a file they can hand back to the build that wrote it.
enum UnreadableDownloadList {
    /// Moves `url` aside and returns where it went.
    @discardableResult
    static func setAside(_ url: URL, now: Date = Date()) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension

        var destination = folder.appendingPathComponent("\(stem)-unreadable-\(stamp(now)).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem)-unreadable-\(stamp(now))-\(attempt).\(ext)")
            attempt += 1
        }

        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    /// Sortable and filename-safe: 2026-09-20-030412.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
