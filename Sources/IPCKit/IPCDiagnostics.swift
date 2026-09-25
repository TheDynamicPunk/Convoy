import Foundation

/// A tiny, human-readable record of what happened to the last IPC handshake
/// between the app and the browser-launched native messaging host.
///
/// Exists because neither side has a usable channel to report a handshake
/// failure through. `NativeMessagingHost` is exec'd by the browser with its
/// stderr swallowed into the browser's own logs, and Chrome surfaces every
/// native-host problem — crashed, rejected, never installed — identically,
/// as "Native host has exited". The app side logs via `os.Logger`, which is
/// correct and completely invisible to anyone who is not already running
/// Console.app with a subsystem filter.
///
/// So the two facts a person actually needs when browser integration stops
/// working — *did a handshake ever succeed, and what went wrong with the
/// last one* — get written to ordinary files under Application Support,
/// where the Settings UI can read them back and a user can be asked to open
/// them.
///
/// Deliberately not a logging framework: two files, no levels, no rotation
/// beyond a size cap. Anything more is a different problem than this one.
public enum IPCDiagnostics {

    /// Both processes are unsandboxed, so they resolve this to the same
    /// real directory. (Under App Sandbox they would each get their own
    /// container and silently write to two different places — one of the
    /// several reasons this app does not sandbox; see build.sh.)
    private static var logDirectory: URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Convoy/Logs", isDirectory: true)
    }

    /// Append-only record of handshake rejections.
    public static var failureLogURL: URL? {
        logDirectory?.appendingPathComponent("ipc-handshake.log")
    }

    /// Single-line marker, overwritten each time, holding the timestamp of
    /// the most recent successful handshake. Kept separate from the failure
    /// log so that recording success costs one small write and never grows.
    public static var lastSuccessURL: URL? {
        logDirectory?.appendingPathComponent("ipc-last-success.txt")
    }

    /// Writes stay on one queue so the two processes' own concurrent
    /// callers can't interleave a half-written line. Cross-process
    /// interleaving is still possible in principle; each record is a single
    /// short append, which in practice is atomic enough for a diagnostic
    /// file nobody parses.
    private static let queue = DispatchQueue(label: "io.github.thedynamicpunk.convoy.ipc.diagnostics")

    /// Past this size the failure log is cleared rather than trimmed. A
    /// handshake that fails often enough to fill a quarter-megabyte is
    /// failing the same way every time; the recent entries are the useful
    /// ones and the old ones are duplicates.
    private static let maximumLogBytes = 256 * 1024

    public static func recordFailure(_ reason: String) {
        guard let directory = logDirectory, let url = failureLogURL else { return }

        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp) [\(ProcessInfo.processInfo.processName)] \(reason)\n"
            guard let data = line.data(using: .utf8) else { return }

            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if size > maximumLogBytes {
                try? FileManager.default.removeItem(at: url)
            }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    public static func recordSuccess() {
        guard let directory = logDirectory, let url = lastSuccessURL else { return }

        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? "\(timestamp)\n".data(using: .utf8)?.write(to: url)
        }
    }

    /// The most recent successful handshake, for the Settings UI to show.
    public static func lastSuccess() -> Date? {
        guard let url = lastSuccessURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The most recent rejection line, for the Settings UI to show.
    public static func lastFailure() -> String? {
        guard let url = failureLogURL,
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map(String.init)
    }
}
