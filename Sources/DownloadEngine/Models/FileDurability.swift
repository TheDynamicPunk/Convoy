import Foundation
import OSLog

/// Gets a finished file's data onto the disk before it takes its real name
/// and the files it was built from are deleted. Without this, a power loss in
/// the seconds after a download completes can leave a broken file and
/// nothing to rebuild it from.
enum FileDurability {
    private static let logger = Logger(subsystem: "Convoy", category: "FileDurability")

    /// `F_BARRIERFSYNC` orders this file's writes before later ones without
    /// `F_FULLFSYNC`'s flush of the whole drive cache; `fsync` is the fallback
    /// for volumes without it. Best effort: a volume that supports neither is
    /// no worse off than before.
    static func flush(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else {
            logger.error("Couldn't open \(url.lastPathComponent, privacy: .public) to flush it")
            return
        }
        defer { close(fd) }
        if fcntl(fd, F_BARRIERFSYNC) != 0, fsync(fd) != 0 {
            logger.error("Couldn't flush \(url.lastPathComponent, privacy: .public): errno \(errno, privacy: .public)")
        }
    }
}
