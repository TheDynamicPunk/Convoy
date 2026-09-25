import Foundation
import OSLog

// MARK: - StreamSegment

/// Downloads a single HLS/DASH stream segment and writes it to a temporary
/// file on disk. Usually a complete, bounded URL fetched in full; when
/// `byteRange` is set, only that slice is requested via an explicit `Range`
/// header — see `HLSByteRange`'s doc comment for why some real-world HLS
/// delivery addresses segments this way.
///
/// Design mirrors `DownloadSegment` for consistency: same actor isolation and
/// (when `byteRange` is set) the same Content-Range verification rigor
/// `DownloadSegment` already has — "server ignores Range and returns 200" and
/// "206 but the wrong offset" are both real, previously-confirmed failure
/// modes there, not hypotheticals invented for this file. The differences:
/// - No multi-segment / Content-Range validation when there's no byteRange
///   (a plain whole-file segment has nothing to validate against).
/// - No sub-chunk workaround (HLS/DASH segments are small by design, 2-10 s).
/// - Body is buffered in memory by `StreamSegmentSessionDelegate` in arrival
///   order and written once on completion. Past `spillThreshold` (a DASH
///   `SegmentBase` "segment" is the whole file) it is flushed to disk instead.
/// - Cancellation is per session, not per segment: a pause closes the
///   delegate and invalidates the session (see `StreamSegmentSessionDelegate`).
/// - AES-128 decryption is applied after the segment is fully downloaded, not
///   inline, because CBC decryption requires whole-block boundaries that aren't
///   guaranteed to align with arbitrary URLSession data chunks.
actor StreamSegment {
    let index: Int
    let url: URL
    let tempFileURL: URL
    let headers: [String: String]
    /// Non-nil for a byte-range-addressed segment (see `HLSByteRange`'s doc
    /// comment) — several segments sharing one physical file, common for
    /// CMAF/fMP4 HLS delivery. When set, `download()` sends an explicit
    /// `Range` header instead of fetching the whole resource.
    let byteRange: HLSByteRange?

    /// A zero-byte sidecar written only after the segment has downloaded and,
    /// where applicable, been decrypted successfully. A non-empty `.tmp` file
    /// alone may be a partial transfer left by a pause or a crash.
    private let completionMarkerURL: URL

    private let logger = Logger(subsystem: "Convoy", category: "StreamSegment")
    private var _httpErrorCode: Int?
    /// Retry-After from a rejected reply.
    private var _retryAfter: TimeInterval?
    /// A byte-range reply came compressed; see `ContentCoding`.
    private var _compressedReply = false
    private var _continuation: CheckedContinuation<Void, Error>?
    /// Seconds before retry `n`, given any Retry-After. See `RetryPolicy`.
    private let retryDelay: @Sendable (_ attempt: Int, _ serverAsked: TimeInterval?) -> TimeInterval

    /// True only after this segment has fully downloaded and StreamDownloader
    /// has finished any required AES decryption.
    var isComplete: Bool {
        guard FileManager.default.fileExists(atPath: completionMarkerURL.path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: tempFileURL.path),
              let size = attrs[.size] as? Int64 else { return false }
        return size > 0
    }

    init(index: Int, url: URL, tempDir: URL, headers: [String: String], byteRange: HLSByteRange? = nil,
         retryDelay: @escaping @Sendable (Int, TimeInterval?) -> TimeInterval = { RetryPolicy.delay(beforeRetry: $0, serverAsked: $1) }) {
        self.index = index
        self.url = url
        self.headers = headers
        self.byteRange = byteRange
        self.retryDelay = retryDelay
        self.tempFileURL = tempDir.appendingPathComponent(String(format: "segment-%04d.tmp", index))
        self.completionMarkerURL = tempDir.appendingPathComponent(
            String(format: "segment-%04d.complete", index)
        )
    }

    // MARK: - Download

    /// Downloads this segment to `tempFileURL`, replacing any prior partial
    /// file — each segment is small enough that a clean restart is simpler and
    /// safer than resuming one that may have been partially AES-decrypted.
    /// The session's delegate must be a `StreamSegmentSessionDelegate`.
    /// Throws `DownloadError.cancelled` once that delegate has been closed.
    ///
    /// A failure of the moment (see `RetryPolicy`) is retried after a wait,
    /// from the start of the segment; one segment failing would otherwise end
    /// a stream of hundreds.
    func download(session: URLSession) async throws {
        var failures = 0
        while true {
            do {
                return try await attempt(session: session)
            } catch {
                failures += 1
                guard RetryPolicy.isTransient(error),
                      failures < RetryPolicy.maxConsecutiveFailures,
                      let delegate = session.delegate as? StreamSegmentSessionDelegate else { throw error }
                let seconds = retryDelay(failures, _retryAfter)
                logger.notice("Segment \(self.index, privacy: .public) failed (\(error.localizedDescription, privacy: .public)) — retry \(failures, privacy: .public) in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
                try await RetryPolicy.wait(seconds) { !delegate.isClosed }
            }
        }
    }

    private func attempt(session: URLSession) async throws {
        try? FileManager.default.removeItem(at: tempFileURL)
        try? FileManager.default.removeItem(at: completionMarkerURL)
        _httpErrorCode = nil
        _retryAfter = nil
        _compressedReply = false

        // nil once an invalidated session has released it.
        guard let delegate = session.delegate as? StreamSegmentSessionDelegate else {
            throw DownloadError.cancelled
        }

        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let byteRange {
            request.setValue("bytes=\(byteRange.start)-\(byteRange.end)", forHTTPHeaderField: "Range")
        }
        ContentCoding.requestUncompressed(&request)

        return try await withCheckedThrowingContinuation { continuation in
            _continuation = continuation
            guard delegate.startTask(request, in: session, segment: self, fileURL: tempFileURL) else {
                _continuation = nil
                continuation.resume(throwing: DownloadError.cancelled)
                return
            }
        }
    }

    /// Commits this segment for reuse only after download/decryption succeeds.
    /// The data is flushed first: without it, a power loss can persist the
    /// marker but not the bytes, and resume would reuse a corrupt segment.
    func markComplete() throws {
        let fd = open(tempFileURL.path, O_RDONLY)
        guard fd >= 0 else { throw URLError(.fileDoesNotExist) }
        defer { close(fd) }
        // Barrier: this file's writes reach the disk before the marker does.
        // Cheaper than F_FULLFSYNC, which also flushes the whole drive cache.
        guard fcntl(fd, F_BARRIERFSYNC) == 0 || fsync(fd) == 0 else {
            throw URLError(.cannotWriteToFile)
        }
        guard FileManager.default.createFile(atPath: completionMarkerURL.path, contents: Data()) else {
            throw URLError(.cannotCreateFile)
        }
    }

    // MARK: - URLSession callbacks (called from StreamSegmentSessionDelegate)

    func handleResponse(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        let ok = (200...299).contains(http.statusCode)
        if !ok {
            _httpErrorCode = http.statusCode
            _retryAfter = RetryPolicy.retryAfter(http)
            logger.error("Segment \(self.index, privacy: .public) HTTP \(http.statusCode, privacy: .public) for \(self.url.absoluteString)")
            return false
        }
        guard let byteRange else { return true }
        // A whole segment decodes fine; a slice of a compressed file doesn't.
        if ContentCoding.isEncoded(http) {
            _compressedReply = true
            logger.error("Segment \(self.index, privacy: .public) byte range came back compressed although asked not to be, for \(self.url.absoluteString)")
            return false
        }
        // A Range request that comes back 200 means the server ignored our
        // Range header entirely and is about to hand us the WHOLE resource —
        // for a byte-range-addressed segment (several segments sharing one
        // physical file) that's not a fallback we can silently accept: we'd
        // splice the entire file in where only a small slice belongs,
        // corrupting the assembled output. Verifying Content-Range's reported
        // start byte too, not just the status code, mirrors the exact
        // protection DownloadSegment already has for the byte-range engine —
        // "206 but the wrong offset" is a real, previously-confirmed failure
        // mode there, not a hypothetical being guarded against here for
        // symmetry alone.
        guard http.statusCode == 206 else {
            _httpErrorCode = http.statusCode
            logger.error("""
                Segment \(self.index) requested bytes=\(byteRange.start)-\(byteRange.end) \
                but server returned \(http.statusCode) (Range ignored) for \
                \(self.url.absoluteString)
                """)
            return false
        }
        if let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let reportedStart = Self.parseContentRangeStart(contentRange),
           reportedStart != byteRange.start {
            _httpErrorCode = http.statusCode
            logger.error("""
                Segment \(self.index) requested start byte \(byteRange.start) but \
                Content-Range reports \(reportedStart) for \
                \(self.url.absoluteString)
                """)
            return false
        }
        return true
    }

    /// `body` is the full response body, collected in order by the delegate;
    /// nil when the delegate already spilled it to `tempFileURL`.
    func handleCompletion(body: Data?, error: Error?) async {
        if _compressedReply {
            _continuation?.resume(throwing: DownloadError.compressedReply)
        } else if let code = _httpErrorCode {
            _continuation?.resume(throwing: DownloadError.httpError(code))
        } else if let error {
            _continuation?.resume(throwing: error)
        } else {
            do {
                try body?.write(to: tempFileURL)
                _continuation?.resume()
            } catch {
                logger.error("Segment \(self.index) write error: \(error.localizedDescription)")
                _continuation?.resume(throwing: error)
            }
        }
        _continuation = nil
    }


    // MARK: - Helpers

    /// Parses the start byte out of a `Content-Range: bytes <start>-<end>/<total>`
    /// header value. Returns `nil` for a malformed or absent value — callers
    /// treat that as "nothing to contradict the status code with", not as an
    /// error in itself, since `Content-Range` is technically optional on a
    /// spec-compliant 206 (though every real server sends it).
    private static func parseContentRangeStart(_ headerValue: String) -> Int64? {
        guard headerValue.hasPrefix("bytes ") else { return nil }
        let afterUnit = headerValue.dropFirst("bytes ".count)
        guard let dashIdx = afterUnit.firstIndex(of: "-") else { return nil }
        return Int64(afterUnit[..<dashIdx])
    }
}

// MARK: - StreamSegmentSessionDelegate

/// Shared URLSession delegate for all stream segments belonging to one
/// `StreamDownloader` operation. Routes callbacks to the correct `StreamSegment`
/// actor by matching URLSessionTask identity — same pattern as
/// `SharedSegmentSessionDelegate` for the byte-range engine.
///
/// Tasks are created only through `startTask`, under the same lock `close()`
/// takes: creating a task on an invalidated session raises an Objective-C
/// exception (a crash), and a pause can invalidate the session between a
/// segment being scheduled and it starting its request.
///
/// Body chunks are appended synchronously on the delegate callback (a serial
/// queue), so they stay in arrival order and are complete before
/// `didCompleteWithError` hands them to the segment. A `Task` per chunk gives
/// no ordering guarantee.
final class StreamSegmentSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Buffered bytes above which a body is flushed to its file.
    static let spillThreshold = 8 << 20

    /// A class so appends mutate the buffer in place (no copy-on-write).
    private final class Entry {
        let segment: StreamSegment
        let fileURL: URL
        var body = Data()
        /// Bytes arrived so far, spilled or not.
        var received: Int64 = 0
        /// Open once the body has spilled to disk.
        var handle: FileHandle?
        var writeError: Error?

        init(segment: StreamSegment, fileURL: URL) {
            self.segment = segment
            self.fileURL = fileURL
        }

        func flush() {
            guard writeError == nil, !body.isEmpty else { return }
            do {
                if handle == nil {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                    handle = try FileHandle(forWritingTo: fileURL)
                }
                try handle?.write(contentsOf: body)
                body.removeAll(keepingCapacity: true)
            } catch {
                writeError = error
            }
        }
    }

    private let lock = NSLock()
    private var entries: [URLSessionTask: Entry] = [:]
    private var closed = false

    /// Creates, registers and resumes a task for `segment`. Returns false once
    /// `close()` has run.
    func startTask(_ request: URLRequest, in session: URLSession,
                   segment: StreamSegment, fileURL: URL) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            let task = session.dataTask(with: request)
            entries[task] = Entry(segment: segment, fileURL: fileURL)
            task.resume()
            return true
        }
    }

    /// Refuses new tasks. Call before invalidating the session.
    func close() {
        lock.withLock { closed = true }
    }

    /// True once `close()` has run: the stream was paused or cancelled.
    var isClosed: Bool { lock.withLock { closed } }

    /// Bytes arrived for the requests still running. A finished or failed
    /// request's bytes leave this count.
    var inFlightBytes: Int64 {
        lock.withLock { entries.values.reduce(0) { $0 + $1.received } }
    }

    private func segment(for task: URLSessionTask) -> StreamSegment? {
        lock.withLock { entries[task]?.segment }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let seg = segment(for: dataTask) else { completionHandler(.cancel); return }
        let expected = response.expectedContentLength
        if expected > 0 {
            let capacity = Int(min(expected, Int64(Self.spillThreshold)))
            lock.withLock { entries[dataTask]?.body.reserveCapacity(capacity) }
        }
        Task {
            if await seg.handleResponse(response) {
                completionHandler(.allow)
            } else {
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let failed = lock.withLock { () -> Bool in
            guard let entry = entries[dataTask] else { return false }
            entry.body.append(data)
            entry.received += Int64(data.count)
            if entry.body.count >= Self.spillThreshold { entry.flush() }
            return entry.writeError != nil
        }
        if failed { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = lock.withLock({ entries.removeValue(forKey: task) }) else { return }
        var body: Data? = entry.body
        if entry.handle != nil {
            if error == nil { entry.flush() }
            try? entry.handle?.close()
            body = nil
        }
        let error = entry.writeError ?? error
        let segment = entry.segment
        Task { await segment.handleCompletion(body: body, error: error) }
    }
}
