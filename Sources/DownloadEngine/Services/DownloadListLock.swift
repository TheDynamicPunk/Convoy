import Foundation

/// Lets only one running copy of the app own the download list. The kernel
/// releases a `flock` when its process exits, so it never goes stale.
final class DownloadListLock {
    /// True only when another process holds it; any other failure counts as
    /// owned, so the app never locks the person out.
    let isHeldElsewhere: Bool
    private let descriptor: Int32

    init(beside listURL: URL) {
        let path = listURL.deletingPathExtension().appendingPathExtension("lock").path
        descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o600)
        isHeldElsewhere = descriptor >= 0
            && flock(descriptor, LOCK_EX | LOCK_NB) != 0
            && errno == EWOULDBLOCK
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
