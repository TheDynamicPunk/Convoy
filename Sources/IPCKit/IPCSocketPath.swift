import Foundation

/// Where Convoy.app and the browser-launched NativeMessagingHost
/// rendezvous for local IPC — shared by both sides so the path can't drift
/// between client and server.
///
/// Uses the per-user Darwin temp directory (`NSTemporaryDirectory()`, e.g.
/// `/var/folders/xx/xxxxxxxx/T/` — NOT the shared, world-readable `/tmp`)
/// rather than `~/Library/Application Support/Convoy/`, for two
/// concrete reasons:
///
/// 1. It's already restricted to this user by the OS (confirmed: the `T/`
///    leaf directory is created mode 0700, owned by the user — nothing
///    running as another account can even list it, let alone open a path
///    inside it), same access-control property Application Support would
///    need to be chmod'd for explicitly.
/// 2. AF_UNIX's `sockaddr_un.sun_path` has a hard 104-byte limit (including
///    the null terminator). `~/Library/Application Support/Convoy/
///    ipc.sock` risks overflowing that for some combination of home
///    directory location — a failure that surfaces as bind()/connect()
///    simply erroring out, not a graceful degradation. The Darwin temp
///    directory's hashed-segment format is a fixed, short length
///    regardless of username, so this can't happen.
public enum IPCSocketPath {
    /// The one socket file this app instance and any native-messaging host
    /// process it spawned should connect to. Recomputed on every access
    /// (not cached) since NSTemporaryDirectory() is cheap and doing so
    /// avoids ever holding a stale value across an unexpected directory
    /// change.
    public static var current: String {
        // Deliberately not the bundle identifier: prefixing this with
        // io.github.thedynamicpunk.convoy puts the path at 89 of the
        // 104 bytes below. Nothing outside this file reads the name.
        let path = NSTemporaryDirectory() + "convoy.ipc.sock"
        // sockaddr_un.sun_path is 104 bytes including the null terminator.
        // This should never actually trip given the Darwin temp directory's
        // fixed-length hashed format, but failing loudly here beats a
        // mysteriously failing bind()/connect() deep in socket code.
        precondition(path.utf8.count < 104, "IPC socket path exceeds sockaddr_un.sun_path capacity: \(path)")
        return path
    }
}
