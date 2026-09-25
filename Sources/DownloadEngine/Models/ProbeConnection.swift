import Foundation
import OSLog

/// A lightweight streaming GET connection that replaces the old HEAD-probe-first
/// architecture. Instead of blocking on a HEAD request (which took 25+ seconds
/// for some redirect chains), this fires a standard GET that begins downloading
/// immediately. Metadata is extracted on-the-fly from the response headers.
///
/// The data is written to segment 0's temp file path, so when we later create
/// proper `DownloadSegment`s, segment 0 automatically discovers the probe's
/// bytes on disk and resumes from there — zero wasted bytes.
///
/// Two-phase lifecycle:
/// 1. `start()` → returns `Metadata` as soon as response headers arrive
///    (connection keeps streaming data in the background)
/// 2. Either `awaitCompletion()` (let it finish the whole file) or
///    `cancel()` (stop streaming, we're going to split into segments)
final class ProbeConnection: NSObject, URLSessionDataDelegate {
    
    struct Metadata {
        let contentLength: Int64
        let supportsRange: Bool
        let resolvedURL: URL?
        let contentDisposition: String?
        let etag: String?
        let lastModified: String?
        let statusCode: Int
        /// Compressed although the request asked not to be (see
        /// `ContentCoding`): the size is unknown, and ranges unusable.
        let isCompressed: Bool
        /// A web page rather than a file (see `WebPageReply`).
        let isWebPage: Bool
        let refresh: String?
    }

    let url: URL
    let headers: [String: String]
    let tempFileURL: URL
    /// False for a request of the whole file, with no Range header. Only for
    /// a server whose ranges can't be used: googlevideo.com refuses it.
    let requestsRange: Bool
    
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private(set) var bytesWritten: Int64 = 0
    private var isCancelled = false
    private var headersDelivered = false
    /// Where this request's body starts in the temp file.
    private var bodyOffset: UInt64 = 0
    /// Waiting in `firstBytes` for this many bytes of the body.
    private var bodyWaiter: (count: Int64, continuation: CheckedContinuation<Void, Never>)?
    
    private let logger = Logger(subsystem: "Convoy", category: "ProbeConnection")
    
    // Phase 1: headers continuation (resumed when response headers arrive)
    private var headersContinuation: CheckedContinuation<Metadata, Error>?
    
    // Phase 2: completion continuation + buffered result (for race safety)
    private let lock = NSLock()
    private var completionContinuation: CheckedContinuation<Void, Error>?
    private var completionResult: Result<Void, Error>?
    
    /// Called on each data chunk with the number of new bytes written.
    /// Use this to update download progress in the UI.
    var onProgress: ((Int64) -> Void)?
    
    init(url: URL, headers: [String: String], tempFileURL: URL, requestsRange: Bool = true) {
        self.url = url
        self.headers = headers
        self.tempFileURL = tempFileURL
        self.requestsRange = requestsRange
        super.init()
    }
    
    /// End byte for the probe's initial Range request. It must be bounded —
    /// googlevideo.com 403s a request with no Range header and 403s open-ended
    /// ("bytes=0-") ranges on its SABR streams, serving only strictly-bounded
    /// partial ranges. Verified directly against live URLs.
    ///
    /// Deliberately small, and NOT the 10 MB that mirrors yt-dlp's
    /// `http_chunk_size`. When yt-dlp resolves formats via a client whose
    /// PO-Token can't be supplied (commonly android_vr — see
    /// DownloadError.youtubeQualityCurrentlyBlocked), the URL it returns is
    /// authorized for only roughly the first 20% of the stream; anything
    /// reaching past that 403s. A 10 MB probe therefore 403s outright on any
    /// stream under ~50 MB, which made YouTube downloads fail on the very first
    /// request with zero bytes transferred.
    ///
    /// 64 KB is all the probe actually needs — it reads the real total from
    /// Content-Range and segments do the downloading — and stays inside that
    /// allowance for any stream above ~320 KB. Note this only makes the probe
    /// succeed; a partially-authorized URL still fails later, in the segments.
    /// RFC-compliant non-YouTube servers clamp the range for smaller files and
    /// report the real total via Content-Range, which is where the metadata is
    /// read from anyway.
    static let probeRangeEnd: Int64 = 64 * 1024 - 1

    /// Phase 1: Start the streaming GET. Returns metadata as soon as response
    /// headers arrive. The connection continues downloading in the background.
    func start() async throws -> Metadata {
        // Prepare temp file for writing
        if !FileManager.default.fileExists(atPath: tempFileURL.path) {
            FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: tempFileURL)
        bodyOffset = fileHandle?.seekToEndOfFile() ?? 0
        
        // Configure a dedicated URLSession
        let config = URLSessionConfiguration.cookieless
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        
        var request = URLRequest(url: url)
        for (header, value) in headers {
            if header.caseInsensitiveCompare("Range") != .orderedSame {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }
        // Standard GET — but we inject a bounded Range request because some
        // CDNs (like YouTube DASH streams) instantly 403 requests without a
        // Range header, and googlevideo.com additionally 403s open-ended
        // ranges — see probeRangeEnd above for why "bytes=0-" no longer works.
        if requestsRange {
            request.setValue("bytes=0-\(Self.probeRangeEnd)", forHTTPHeaderField: "Range")
        }
        ContentCoding.requestUncompressed(&request)

        logger.notice("Probe starting GET \(self.url.absoluteString) ranged=\(self.requestsRange, privacy: .public)")
        
        return try await withCheckedThrowingContinuation { continuation in
            self.headersContinuation = continuation
            self.dataTask = session?.dataTask(with: request)
            self.dataTask?.resume()
        }
    }
    
    /// Phase 2a: Wait for the probe to finish downloading the entire file.
    /// Only call this for the no-split path (small file / no range support).
    func awaitCompletion() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result = completionResult {
                // Download already finished before we started waiting
                lock.unlock()
                cont.resume(with: result)
            } else {
                completionContinuation = cont
                lock.unlock()
            }
        }
    }
    
    /// The first `count` bytes of the body, or all of it when shorter, once
    /// they're on disk. For telling a page from a file (see `WebPageReply`).
    func firstBytes(_ count: Int) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isCancelled || completionResult != nil || bytesWritten >= count {
                lock.unlock()
                continuation.resume()
            } else {
                bodyWaiter = (Int64(count), continuation)
                lock.unlock()
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: tempFileURL) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: bodyOffset)
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    /// Phase 2b: Cancel the probe. Call this when splitting into segments.
    /// Bytes already written to the temp file are preserved — segment 0 will
    /// resume from them.
    func cancel() {
        lock.lock()
        isCancelled = true
        let waiter = bodyWaiter?.continuation
        bodyWaiter = nil
        lock.unlock()
        waiter?.resume()
        dataTask?.cancel()
        closeFileHandle()
        session?.invalidateAndCancel()
        session = nil
    }
    
    private func closeFileHandle() {
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            headersContinuation?.resume(throwing: DownloadError.invalidResponse)
            headersContinuation = nil
            completionHandler(.cancel)
            return
        }
        
        logger.notice("Probe response: status=\(http.statusCode, privacy: .public) url=\(http.url?.absoluteString ?? "?")")
        
        guard (200...299).contains(http.statusCode) else {
            headersContinuation?.resume(throwing: DownloadError.httpError(http.statusCode))
            headersContinuation = nil
            completionHandler(.cancel)
            return
        }
        
        let contentLength: Int64
        if let cl = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(cl) {
            contentLength = length
        } else {
            contentLength = 0
        }
        
        var finalContentLength = contentLength
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range") {
            let lower = cr.lowercased()
            if lower.hasPrefix("bytes "), let slashIdx = lower.lastIndex(of: "/") {
                let totalStr = String(cr[cr.index(after: slashIdx)...])
                if let total = Int64(totalStr), total > 0 {
                    finalContentLength = total
                }
            }
        }

        // Lengths and ranges of a compressed reply count compressed bytes,
        // not the file's; the file is only whatever arrives once decoded.
        let isCompressed = ContentCoding.isEncoded(http)
        if isCompressed {
            logger.notice("Probe reply is compressed (\(http.value(forHTTPHeaderField: "Content-Encoding") ?? "", privacy: .public)) although asked not to be — size unknown, no ranges")
        }

        let metadata = Metadata(
            contentLength: isCompressed ? 0 : finalContentLength,
            supportsRange: !isCompressed && (http.statusCode == 206 || http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"),
            resolvedURL: http.url,
            contentDisposition: http.value(forHTTPHeaderField: "Content-Disposition"),
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            statusCode: http.statusCode,
            isCompressed: isCompressed,
            isWebPage: WebPageReply.isPage(http),
            refresh: http.value(forHTTPHeaderField: "Refresh")
        )
        
        headersDelivered = true
        headersContinuation?.resume(returning: metadata)
        headersContinuation = nil
        
        completionHandler(.allow)
    }
    
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard !isCancelled, let handle = fileHandle else { return }
        do {
            try handle.write(contentsOf: data)
            lock.lock()
            bytesWritten += Int64(data.count)
            let waiter = bodyWaiter.flatMap { bytesWritten >= $0.count ? $0.continuation : nil }
            if waiter != nil { bodyWaiter = nil }
            lock.unlock()
            waiter?.resume()
            onProgress?(Int64(data.count))
        } catch {
            logger.error("Probe failed writing to disk: \(error.localizedDescription)")
            self.dataTask?.cancel()
        }
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        closeFileHandle()
        
        // If headers were never delivered, fail the headers continuation
        if !headersDelivered {
            headersContinuation?.resume(throwing: error ?? DownloadError.invalidResponse)
            headersContinuation = nil
            return
        }
        
        // Build the completion result
        let result: Result<Void, Error>
        if let error, !isCancelled {
            result = .failure(error)
        } else {
            result = .success(())
        }
        
        // Thread-safe: store result and resume continuation if waiting
        lock.lock()
        completionResult = result
        let cont = completionContinuation
        completionContinuation = nil
        let waiter = bodyWaiter?.continuation
        bodyWaiter = nil
        lock.unlock()
        
        cont?.resume(with: result)
        waiter?.resume()
        
        // Clean up session to break retain cycles
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}
