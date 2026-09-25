import Foundation
import OSLog

/// What `DownloadSegment.handleResponse` lets the delegate do with a body.
enum SegmentResponseDisposition {
    /// Append the body to the segment's file.
    case accept
    /// A single-segment resume answered with the whole file from byte 0:
    /// empty the file first, or the body duplicates what's already there.
    case acceptFromZero
    /// Wrong offset, wrong status, or a reply to a cancelled connection.
    case reject
}

/// Bytes on disk for one segment. Shared with the delegate, which writes a
/// chunk and counts it in one step, so the count never disagrees with the file.
final class SegmentByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = 0

    var value: Int64 { lock.withLock { _value } }
    func set(_ newValue: Int64) { lock.withLock { _value = newValue } }
    func add(_ delta: Int64) { lock.withLock { _value += delta } }
}

actor DownloadSegment {
    let task: DownloadTask
    let index: Int
    let startByte: Int64
    let endByte: Int64
    let session: URLSession
    let customHeaders: [String: String]
    /// True whenever this segment is one of several covering the file
    /// (segmentCount > 1). A 200 response to a Range request only means
    /// something dangerous — the server ignoring Range and sending the
    /// whole file — when there's more than one segment to misalign. With
    /// exactly one segment covering the whole file, a 200 is recoverable:
    /// see `.acceptFromZero`.
    let isMultiSegment: Bool
    /// Sent as `If-Range` and checked against every response.
    let validators: ResourceValidators
    /// Seconds before retry `n`, given any Retry-After. See `RetryPolicy`.
    let retryDelay: @Sendable (_ attempt: Int, _ serverAsked: TimeInterval?) -> TimeInterval

    private let logger = Logger(subsystem: "Convoy", category: "DownloadSegment")
    /// Written by the delegate. The sole source of truth for progress.
    private let _bytesOnDisk = SegmentByteCounter()
    private let _tempFileURL: URL
    /// The current run: bumped by every download() and by cancel(). A run
    /// that finds it changed has been cancelled or superseded, and exits.
    private var _runID = 0
    private var _rangeNotHonored = false
    /// A response showed the server's file is no longer the one on disk.
    private var _resourceChanged = false
    /// A ranged reply came compressed; see `ContentCoding`.
    private var _compressedReply = false
    /// Retry-After from a rejected reply.
    private var _retryAfter: TimeInterval?
    /// Non-nil when handleResponse rejected a non-2xx response — stored so
    /// handleCompletion can throw DownloadError.httpError(code) instead of
    /// the raw NSURLErrorCancelled that URLSession delivers after the cancel.
    private var _httpErrorCode: Int?
    /// Where the in-flight request starts; Content-Range is checked against it.
    private var _requestedStart: Int64 = 0
    /// The request waiting on the network, and whoever waits for it.
    private var _inFlight: (task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>)?

    var downloadedBytes: Int64 { _bytesOnDisk.value }
    /// The same count, read without waiting on the actor (the segment bar).
    nonisolated var bytesOnDisk: Int64 { _bytesOnDisk.value }
    nonisolated var segmentSize: Int64 { endByte - startByte + 1 }
    var isComplete: Bool { downloadedBytes >= segmentSize }
    nonisolated var tempFileURL: URL { _tempFileURL }

    init(task: DownloadTask, index: Int, startByte: Int64, endByte: Int64, session: URLSession, customHeaders: [String: String] = [:], isMultiSegment: Bool = true, validators: ResourceValidators = ResourceValidators(etag: nil, lastModified: nil),
         retryDelay: @escaping @Sendable (Int, TimeInterval?) -> TimeInterval = { RetryPolicy.delay(beforeRetry: $0, serverAsked: $1) }) {
        self.task = task
        self.index = index
        self.startByte = startByte
        self.endByte = endByte
        self.session = session
        self.customHeaders = customHeaders
        self.isMultiSegment = isMultiSegment
        self.validators = validators
        self.retryDelay = retryDelay

        let tempDir = FileManager.default.temporaryDirectory
        self._tempFileURL = tempDir.appendingPathComponent("\(task.id.uuidString)-segment-\(index).tmp")
    }

    /// YouTube's CDN (googlevideo.com) enforces a per-connection byte-rate
    /// cap: after an initial burst, each long-lived HTTP request is throttled
    /// to roughly 50-80 KB/s regardless of how the `n` parameter or
    /// `ratebypass` are set. yt-dlp works around this with
    /// `--http-chunk-size 10485760` — making many short-lived 10 MB requests
    /// instead of one large one, so each gets a fresh rate budget.
    ///
    /// We apply the same technique here: when the download URL is a
    /// googlevideo.com host, each segment downloads its range in sequential
    /// ~10 MB sub-chunk HTTP requests rather than one monolithic request.
    /// Non-YouTube downloads are completely unaffected.
    private static let youtubeChunkSize: Int64 = 10 * 1024 * 1024 // 10 MB

    /// Consecutive empty responses before the segment gives up.
    private static let maxEmptyResponses = 3

    /// Re-reads the byte count from the part file, which is what the join
    /// reads. A missing file counts as zero.
    func syncWithDisk() {
        let size = (try? FileManager.default.attributesOfItem(atPath: _tempFileURL.path))?[.size] as? Int64
        _bytesOnDisk.set(size ?? 0)
    }

    func download() async throws {
        _runID += 1
        let run = _runID
        // Only reachable if an earlier run was never cancelled; it's over now.
        abandonInFlight()

        // Sync our byte count from whatever's actually persisted on disk —
        // this is the real baseline, not any in-memory value from a prior
        // interrupted run.
        if FileManager.default.fileExists(atPath: _tempFileURL.path) {
            let attrs = try FileManager.default.attributesOfItem(atPath: _tempFileURL.path)
            _bytesOnDisk.set(attrs[.size] as? Int64 ?? 0)
        } else {
            FileManager.default.createFile(atPath: _tempFileURL.path, contents: nil)
            _bytesOnDisk.set(0)
        }

        // Already fully downloaded in an earlier run — nothing to do. This
        // guards the case where a caller re-adds every segment on resume
        // instead of filtering to incomplete ones; it's a safety net, not
        // the primary fix (that lives in DownloadTask.resume()).
        guard !isComplete else { return }

        let downloadURL = await task.effectiveURL

        // Detect YouTube CDN — these are the URLs that get throttled per-
        // connection and need the sub-chunk workaround.
        let isYouTubeCDN = downloadURL.host?.lowercased().hasSuffix("googlevideo.com") == true

        try await downloadRange(url: downloadURL, chunkSize: isYouTubeCDN ? Self.youtubeChunkSize : nil, run: run)
    }

    /// Requests what's missing until the segment is complete. A server may
    /// end a response early, so one request isn't enough; the YouTube
    /// sub-chunks use the same loop. Throws `.cancelled` once `run` is over.
    ///
    /// A request that fails for a passing reason is made again after a wait
    /// (see `RetryPolicy`), from wherever the bytes on disk reach. Only
    /// failures in a row count against the limit: a connection that keeps
    /// dropping but moves the part forward each time still finishes it.
    private func downloadRange(url: URL, chunkSize: Int64?, run: Int) async throws {
        var emptyResponses = 0
        var failures = 0

        while !isComplete {
            guard run == _runID else { throw DownloadError.cancelled }

            let before = downloadedBytes
            let rangeStart = startByte + before
            let rangeEnd = chunkSize.map { min(rangeStart + $0 - 1, endByte) } ?? endByte

            do {
                try await performRequest(url: url, rangeStart: rangeStart, rangeEnd: rangeEnd, run: run)
            } catch {
                guard run == _runID, RetryPolicy.isTransient(error) else { throw error }
                failures = downloadedBytes != before ? 1 : failures + 1
                guard failures < RetryPolicy.maxConsecutiveFailures else {
                    logger.error("Segment \(self.index) failed \(failures) times in a row — giving up: \(error.localizedDescription, privacy: .public)")
                    throw error
                }
                let seconds = retryDelay(failures, _retryAfter)
                logger.notice("Segment \(self.index) request failed (\(error.localizedDescription, privacy: .public)) — retry \(failures) in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
                try await RetryPolicy.wait(seconds) { run == _runID }
                continue
            }

            // Compared with !=, not >: `.acceptFromZero` can lower the count
            // and still be progress.
            if downloadedBytes != before {
                emptyResponses = 0
                failures = 0
            } else {
                emptyResponses += 1
                guard emptyResponses < Self.maxEmptyResponses else {
                    logger.error("Segment \(self.index) got \(emptyResponses) empty responses for bytes \(rangeStart)-\(rangeEnd) — giving up")
                    throw DownloadError.noData
                }
            }
        }

        await task.segmentDidComplete(self)
    }

    /// One request for `rangeStart...rangeEnd`, resolved by handleCompletion,
    /// or with `.cancelled` by abandonInFlight.
    private func performRequest(url: URL, rangeStart: Int64, rangeEnd: Int64, run: Int) async throws {
        var request = URLRequest(url: url)

        for (header, value) in customHeaders {
            // Never let customHeaders overwrite the segment-specific Range header
            if header.caseInsensitiveCompare("Range") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }
        request.setValue("bytes=\(rangeStart)-\(rangeEnd)", forHTTPHeaderField: "Range")
        if let ifRange = validators.ifRange {
            request.setValue(ifRange, forHTTPHeaderField: "If-Range")
        }
        ContentCoding.requestUncompressed(&request)

        _requestedStart = rangeStart
        _rangeNotHonored = false
        _resourceChanged = false
        _compressedReply = false
        _httpErrorCode = nil
        _retryAfter = nil

        logger.debug("Segment \(self.index) requesting bytes \(rangeStart)-\(rangeEnd) from \(url.absoluteString)")

        guard let delegate = session.delegate as? SharedSegmentSessionDelegate else {
            // Without this delegate no callback routes here; the request would hang.
            throw DownloadError.invalidResponse
        }

        if Task.isCancelled { throw DownloadError.cancelled }

        // Task cancellation (a sibling part failed) ends this run only, never
        // a newer one. The continuation closure runs synchronously on the
        // actor, so `_inFlight` is set before any callback for it is handled.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let urlTask = try delegate.startTask(
                        request, in: session, segment: self,
                        fileURL: _tempFileURL, counter: _bytesOnDisk,
                        offset: rangeStart - startByte
                    )
                    _inFlight = (urlTask, continuation)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.stop(run: run) }
        }
    }

    /// Ends the current run, if any.
    func cancel() async {
        _runID += 1
        abandonInFlight()
    }

    /// Ends `run` if it is still the current one.
    private func stop(run: Int) {
        guard run == _runID else { return }
        _runID += 1
        abandonInFlight()
    }

    /// Cancels the request in flight and resolves its caller now, rather
    /// than when URLSession reports the cancel; that late report is ignored.
    private func abandonInFlight() {
        guard let inFlight = _inFlight else { return }
        _inFlight = nil
        // Detach the file first, so chunks already queued land nowhere.
        if let delegate = session.delegate as? SharedSegmentSessionDelegate {
            delegate.stopWriting(for: inFlight.task)
        }
        inFlight.task.cancel()
        inFlight.continuation.resume(throwing: DownloadError.cancelled)
    }

    /// Progress only: the delegate has already written and counted the bytes.
    func noteProgress(bytes: Int64) async {
        await task.segmentDidProgress(self, bytes: bytes)
    }

    /// Validates the HTTP response before accepting any body data.
    ///
    /// - **Compressed although asked not to** → `compressedReply`; decoded
    ///   bytes don't sit at the range's offsets.
    /// 0. **The file changed** (validators differ, or a 200 to `If-Range`)
    ///    → `resourceChanged`; old and new bytes can't be joined.
    /// 1. **200 instead of 206** — several segments: `rangeNotHonored`. One
    ///    segment resuming: `.acceptFromZero`.
    /// 2. **206 with wrong Content-Range** — the CDN acknowledged the range
    ///    but streams from another offset. Invisible to a status-code-only
    ///    check.
    /// 3. **A reply to a cancelled connection** — rejected.
    func handleResponse(for urlTask: URLSessionTask, _ response: URLResponse) -> SegmentResponseDisposition {
        guard urlTask === _inFlight?.task else { return .reject }
        guard let http = response as? HTTPURLResponse else { return .accept }

        // Before the validators: a compressed version usually has its own
        // ETag too, and this is the more exact reason.
        if (200...299).contains(http.statusCode), ContentCoding.isEncoded(http) {
            logger.error("Segment \(self.index): the server compressed its reply although asked not to, so it can't be placed in the file")
            _compressedReply = true
            return .reject
        }

        if (200...299).contains(http.statusCode), validators.differ(from: http) {
            logger.error("Segment \(self.index): the file changed on the server since this download started")
            _resourceChanged = true
            return .reject
        }

        // Failure mode 1: full-file 200 on a ranged request.
        if http.statusCode == 200 && _requestedStart > startByte {
            guard !isMultiSegment, startByte == 0 else {
                logger.error("Segment \(self.index) got 200 instead of 206 — server isn't honoring Range header")
                _rangeNotHonored = true
                return .reject
            }
            logger.notice("Segment \(self.index) asked to resume from \(self._requestedStart) and got the whole file — restarting it from byte 0")
            return .acceptFromZero
        }
        if isMultiSegment && http.statusCode == 200 {
            // Nothing duplicated here, but the other segments' slices would be wrong.
            logger.error("Segment \(self.index) got 200 instead of 206 — server isn't honoring Range header")
            _rangeNotHonored = true
            return .reject
        }

        // Failure mode 2: 206 but Content-Range starts at the wrong byte.
        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let actualStart = Self.parseRangeStart(from: contentRange),
           actualStart != _requestedStart {
            if !isMultiSegment && startByte == 0 && actualStart == 0 {
                logger.notice("Segment \(self.index) asked to resume from \(self._requestedStart) and got a 206 from byte 0 — restarting it from byte 0")
                return .acceptFromZero
            }
            logger.error("Segment \(self.index) got 206 but Content-Range starts at \(actualStart), expected \(self._requestedStart) — CDN returned wrong byte range")
            _rangeNotHonored = true
            return .reject
        }
        // No Content-Range header on a 206 is unusual but not necessarily
        // wrong — give benefit of the doubt and let the data flow.

        // For any other non-2xx, record the status code so handleCompletion
        // can throw a typed DownloadError.httpError rather than the opaque
        // NSURLErrorCancelled that URLSession delivers after we cancel.
        let ok = (200...299).contains(http.statusCode)
        if !ok {
            _httpErrorCode = http.statusCode
            _retryAfter = RetryPolicy.retryAfter(http)
        }
        return ok ? .accept : .reject
    }

    /// Parses the start byte from a `Content-Range: bytes start-end/total` header.
    /// Returns nil if the header is malformed or uses a non-bytes unit.
    private static func parseRangeStart(from contentRange: String) -> Int64? {
        // Expected format: "bytes 0-35999999/288000000" or "bytes 0-35999999/*"
        let lower = contentRange.lowercased()
        guard lower.hasPrefix("bytes ") else { return nil }
        let rest = contentRange.dropFirst("bytes ".count)
        guard let dashIdx = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex ..< dashIdx])
    }

    /// One request has ended; everything it delivered is already on disk and
    /// counted.
    func handleCompletion(for urlTask: URLSessionTask, error: Error?) async {
        // A cancelled request finishing late; abandonInFlight resolved it.
        guard let inFlight = _inFlight, inFlight.task === urlTask else { return }
        _inFlight = nil
        let continuation = inFlight.continuation

        if _compressedReply {
            // See DownloadTask.restartAsWholeFile.
            continuation.resume(throwing: DownloadError.compressedReply)
        } else if _resourceChanged {
            // Not rangeNotHonored: one connection would still mix versions.
            // See DownloadTask.restartAfterResourceChange.
            continuation.resume(throwing: DownloadError.resourceChanged)
        } else if _rangeNotHonored {
            // Distinct from a plain cancel/failure so DownloadTask can
            // specifically retry as a single connection rather than either
            // corrupting data or just failing with a generic error.
            continuation.resume(throwing: DownloadError.rangeNotHonored)
        } else if let code = _httpErrorCode {
            // handleResponse rejected a non-2xx response and stored the code.
            // Throw it as a typed error so callers can distinguish 403/410
            // (link expired) from generic network failures.
            continuation.resume(throwing: DownloadError.httpError(code))
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

/// A single session-level delegate shared by every segment of a task,
/// routing callbacks to the correct segment actor by matching the
/// URLSessionTask identity — the necessary counterpart to sharing one
/// URLSession across segments (see DownloadTask._sharedSegmentSession).
///
/// Chunks are written synchronously on the delegate's serial queue, so they
/// land in arrival order and all before `didCompleteWithError`. A `Task` per
/// chunk gives no ordering guarantee. Same pattern as
/// `StreamSegmentSessionDelegate`.
final class SharedSegmentSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// One in-flight request: its open file and its segment's counter.
    private final class Entry {
        let segment: DownloadSegment
        let counter: SegmentByteCounter
        /// Nil once finished or detached by a cancel.
        var handle: FileHandle?
        var writeError: Error?

        init(segment: DownloadSegment, counter: SegmentByteCounter, handle: FileHandle) {
            self.segment = segment
            self.counter = counter
            self.handle = handle
        }

        /// Bytes written; zero once detached.
        func write(_ data: Data) -> Int64 {
            guard writeError == nil, let handle, !data.isEmpty else { return 0 }
            do {
                try handle.write(contentsOf: data)
                counter.add(Int64(data.count))
                return Int64(data.count)
            } catch {
                writeError = error
                return 0
            }
        }

        /// Empties the file for `.acceptFromZero`.
        func restartFromZero() {
            guard writeError == nil, let handle else { return }
            do {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                counter.set(0)
            } catch {
                writeError = error
            }
        }

        func close() {
            try? handle?.close()
            handle = nil
        }
    }

    private let lock = NSLock()
    private var entries: [URLSessionTask: Entry] = [:]

    /// Opens the file at `offset`, registers the request and starts it, so no
    /// callback can arrive for an unregistered request.
    func startTask(_ request: URLRequest, in session: URLSession, segment: DownloadSegment,
                   fileURL: URL, counter: SegmentByteCounter, offset: Int64) throws -> URLSessionDataTask {
        let handle = try Self.openForWriting(fileURL, at: offset)
        return lock.withLock {
            let task = session.dataTask(with: request)
            entries[task] = Entry(segment: segment, counter: counter, handle: handle)
            task.resume()
            return task
        }
    }

    /// Opens `url` for writing at `offset`, the counted size, dropping
    /// anything past it. Appending at end of file would put uncounted bytes
    /// (a late probe write to part 0) ahead of this request's data.
    static func openForWriting(_ url: URL, at offset: Int64) throws -> FileHandle {
        let handle = try FileHandle(forWritingTo: url)
        let position = UInt64(max(offset, 0))
        try handle.truncate(atOffset: position)
        try handle.seek(toOffset: position)
        return handle
    }

    /// Detaches a cancelled request from its file; its late completion is
    /// still delivered, and ignored.
    func stopWriting(for task: URLSessionTask) {
        lock.withLock { entries[task]?.close() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let segment = lock.withLock({ entries[dataTask]?.segment }) else {
            completionHandler(.cancel)
            return
        }
        Task {
            switch await segment.handleResponse(for: dataTask, response) {
            case .accept:
                completionHandler(.allow)
            case .acceptFromZero:
                // Before any of the body is allowed through.
                let failed = self.lock.withLock { () -> Bool in
                    guard let entry = self.entries[dataTask] else { return true }
                    entry.restartFromZero()
                    return entry.writeError != nil
                }
                completionHandler(failed ? .cancel : .allow)
            case .reject:
                completionHandler(.cancel)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let written = lock.withLock { () -> (segment: DownloadSegment, bytes: Int64, failed: Bool)? in
            guard let entry = entries[dataTask] else { return nil }
            let bytes = entry.write(data)
            return (entry.segment, bytes, entry.writeError != nil)
        }
        guard let written else { return }
        if written.failed {
            dataTask.cancel()
            return
        }
        guard written.bytes > 0 else { return }
        Task { await written.segment.noteProgress(bytes: written.bytes) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Every registered request ends exactly once, here.
        guard let entry = lock.withLock({ entries.removeValue(forKey: task) }) else { return }
        entry.close()
        // After a write failure `error` is only the cancel it caused.
        let error = entry.writeError ?? error
        let segment = entry.segment
        Task { await segment.handleCompletion(for: task, error: error) }
    }
}
