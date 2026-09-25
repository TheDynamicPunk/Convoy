import Foundation

/// What a helper install is doing now, for a progress bar.
public struct HelperInstallProgress: Sendable, Equatable {
    /// "Downloading yt-dlp", "Installing yt-dlp".
    public let title: String
    /// 1-based; 0 of 0 while checking for updates.
    public let step: Int
    public let stepCount: Int
    public let receivedBytes: Int64
    /// nil while unpacking and checking, or when the server sent no size.
    public let expectedBytes: Int64?

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// What an install or update actually did.
public struct HelperUpdateResult: Sendable, Equatable {
    /// Display names of the helpers downloaded; empty when all were current.
    public let updated: [String]
}

public enum HelperInstallEvent: Sendable {
    case progress(HelperInstallProgress)
    /// Non-fatal: the install carried on without this part.
    case warning(String)
}

/// Reports one step of an install: bytes while downloading, then an
/// indeterminate "Installing" phase.
struct HelperInstallStep: Sendable {
    let name: String
    let step: Int
    let stepCount: Int
    let emit: @Sendable (HelperInstallEvent) -> Void

    func downloading(_ received: Int64, of expected: Int64?) {
        emit(.progress(HelperInstallProgress(title: "Downloading \(name)", step: step, stepCount: stepCount,
                                             receivedBytes: received, expectedBytes: expected)))
    }

    func installing() {
        emit(.progress(HelperInstallProgress(title: "Installing \(name)", step: step, stepCount: stepCount,
                                             receivedBytes: 0, expectedBytes: nil)))
    }

    /// `downloading` as a `@Sendable` closure; a method reference such as
    /// `step.downloading` never is.
    var onBytes: @Sendable (Int64, Int64?) -> Void {
        { downloading($0, of: $1) }
    }
}

/// A one-shot download that reports bytes as they arrive.
///
/// `URLSession.download(from:)` reports nothing until it finishes, and its
/// per-task delegate isn't sent `didWriteData`, so this uses its own session
/// and delegate. The session is invalidated when the download ends.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// Byte updates are coalesced to about ten a second; the last one always
    /// goes out.
    private static let reportInterval: TimeInterval = 0.1

    private let onBytes: @Sendable (Int64, Int64?) -> Void
    // Touched only on the session's serial delegate queue, after `run` has
    // set `continuation` and before the task was resumed.
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedFile: URL?
    private var moveError: Error?
    private var lastReport = Date.distantPast

    private init(onBytes: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onBytes = onBytes
    }

    /// Returns a temporary file the caller owns, and the response.
    static func run(
        _ url: URL,
        configuration: URLSessionConfiguration = .cookieless,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = ProgressDownload(onBytes: onBytes)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        guard now.timeIntervalSince(lastReport) >= Self.reportInterval || totalBytesWritten == expected else { return }
        lastReport = now
        onBytes(totalBytesWritten, expected)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("convoy-helper-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: file)
            downloadedFile = file
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
            continuation?.resume(throwing: error)
        } else if let downloadedFile, let response = task.response {
            continuation?.resume(returning: (downloadedFile, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
        continuation = nil
    }
}
