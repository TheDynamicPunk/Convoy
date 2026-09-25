import Foundation
import SwiftUI
import OSLog

public enum DownloadError: LocalizedError {
    case invalidResponse
    case httpError(Int)
    case noData
    case mergeFailed
    case cancelled
    case invalidURL
    case rangeNotHonored
    /// A part response named a different version of the file than the one
    /// on disk. See DownloadTask.restartAfterResourceChange.
    case resourceChanged
    /// A ranged reply came compressed although the request asked for the
    /// file uncompressed (see `ContentCoding`), so it can't be placed at its
    /// offset. A plain download then fetches the file in one request.
    case compressedReply
    /// The link answered with a web page rather than the file, and the page
    /// doesn't forward to one (see `WebPageReply`).
    case webPage
    /// A YouTube stream 403'd immediately on every attempt, with zero bytes
    /// ever downloaded — even after re-resolving via yt-dlp from scratch.
    /// The URL's own signature/expiry is fine; the underlying player client
    /// yt-dlp fell back to (commonly android_vr once web_safari's formats
    /// are SABR-blocked) currently requires its own PO-Token that no
    /// available provider can generate. This is a known, current,
    /// platform-side restriction — see yt-dlp/yt-dlp#17348 — affecting
    /// every yt-dlp-based tool identically as of this writing, not
    /// something specific to this app or fixable by retrying further.
    case youtubeQualityCurrentlyBlocked
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .httpError(let code): return "HTTP error: \(code)"
        case .noData: return "No data received"
        case .mergeFailed: return "Failed to merge segments"
        case .cancelled: return "Download cancelled"
        case .invalidURL: return "Invalid URL"
        case .rangeNotHonored: return "Server didn't honor a ranged request"
        case .resourceChanged: return "This file changed on the server while it was downloading"
        case .compressedReply: return "The server sent this file compressed, in a way that can't be downloaded in parts"
        case .webPage: return "This link opens a web page, not a file"
        case .youtubeQualityCurrentlyBlocked:
            // The why is in the doc comment on the case. A download row shows
            // this in two lines, so it says only what the person can act on.
            return "YouTube is refusing this quality right now. It affects every download tool, not just Convoy — try a different quality."
        }
    }
}

struct ResumableTaskInfo: Codable {
    let url: String
    let destinationPath: String
    let totalBytes: Int64
    let downloadedBytes: Int64
    let segments: [ResumableSegmentInfo]
}

struct ResumableSegmentInfo: Codable {
    let index: Int
    let startByte: Int64
    let endByte: Int64
    let downloadedBytes: Int64
}

@MainActor
public final class DownloadTask: ObservableObject, Identifiable {
    public let id: UUID
    public let url: URL
    public private(set) var destinationURL: URL
    public let priority: DownloadPriority
    public let createdAt: Date
    
    @Published public private(set) var status: DownloadStatus = .waiting {
        didSet {
            updateActivityMessage()
            refreshSegmentMap(force: true)
        }
    }
    /// A short, user-friendly description of what the engine is doing during
    /// intermediate states (validation, link refresh). Nil during normal
    /// downloading, paused, completed, and failed states so the UI only
    /// shows it when there's actually something useful to say.
    @Published public private(set) var activityMessage: String?
    @Published public private(set) var totalBytes: Int64 = 0
    @Published public private(set) var downloadedBytes: Int64 = 0
    @Published public private(set) var speed: Int64 = 0
    @Published public private(set) var error: Error?
    @Published public private(set) var segmentCount: Int = 8

    /// What `progress` and `estimatedTimeRemaining` measure against.
    ///
    /// Most downloads know their size up front. A native HLS/DASH stream does
    /// not, but its manifest gives a segment count, so it counts those.
    /// Either denominator is fixed once set — never revised while on screen.
    public enum ProgressBasis: Sendable, Equatable {
        case bytes
        case segments(completed: Int, total: Int)
    }

    @Published public private(set) var progressBasis: ProgressBasis = .bytes

    /// True while a stream's two tracks are merged (by MediaMuxer, using
    /// AVFoundation — ffmpeg has not been involved for some time).
    ///
    /// Segments are all in but the file is not playable, so the bar holds just
    /// short of full — parking at 100% for seconds reads as a freeze.
    @Published public private(set) var isMerging: Bool = false {
        didSet { updateActivityMessage() }
    }

    /// The parts of this download and how full each is, for the row's
    /// segment bar. Nil with fewer than two parts, and for YouTube, which
    /// yt-dlp reports only as a byte count.
    @Published public private(set) var segmentMap: SegmentMap?

    /// True when the finished size cannot be known until the download ends.
    public var hasUnknownTotalSize: Bool { streamURL != nil }

    /// Segments done and expected, for rows that want to show the count.
    public var segmentProgress: (completed: Int, total: Int)? {
        guard case .segments(let completed, let total) = progressBasis, total > 0 else { return nil }
        return (completed, total)
    }
    
    public var filename: String {
        // blob:/data: URLs have no real path — lastPathComponent on those
        // returns garbage (e.g. a blob UUID fragment). Name them clearly
        // instead of silently showing that garbage as the filename.
        if url.scheme == "blob" || url.scheme == "data" {
            return "unsupported-source"
        }
        // destinationURL is updated post-resolution for resolver-backed
        // sources (see resolveIfNeeded) so this reflects the real yt-dlp
        // title once available, and the original URL's last path component
        // before that/for everything else — single source of truth, no
        // separate field that could drift out of sync with what's on disk.
        return destinationURL.lastPathComponent.isEmpty ? "download" : destinationURL.lastPathComponent
    }
    
    public var progress: Double {
        switch progressBasis {
        case .segments(let completed, let total):
            guard total > 0 else { return 0 }
            let fraction = min(1.0, Double(completed) / Double(total))
            return isMerging ? min(fraction, 0.99) : fraction
        case .bytes:
            guard totalBytes > 0 else { return 0 }
            let fraction = min(1.0, Double(downloadedBytes) / Double(totalBytes))
            // Not 100% until the joined file is in place.
            return isMerging ? min(fraction, 0.99) : fraction
        }
    }
    
    public var estimatedTimeRemaining: TimeInterval {
        switch progressBasis {
        case .segments(let completed, let total):
            // Steadier than instantaneous byte speed, and needs no total.
            // Timed from this run, not the task's start: a resume replays
            // finished segments in a burst, which against an overnight pause
            // would read hours out.
            guard completed > 0, total > completed,
                  let started = _streamRunStart else { return 0 }
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed > 0 else { return 0 }
            return (elapsed / Double(completed)) * Double(total - completed)
        case .bytes:
            return speed > 0 ? TimeInterval((totalBytes - downloadedBytes) / speed) : 0
        }
    }
    
    public var averageSpeed: Int64 {
        guard let startTime = _startTime else { return 0 }
        let elapsed = Date().timeIntervalSince(startTime)
        return elapsed > 0 ? downloadedBytes / Int64(elapsed) : 0
    }
    
    public var endTime: Date? { _endTime }
    
    public var category: String {
        // Was url.pathExtension — fine for a plain HTTP download where url
        // and destinationURL share an extension, but wrong for YouTube: url
        // is the watch page ("/watch", no extension at all), so every check
        // below fell through to "Other" and the row showed a generic doc
        // icon regardless of whether the download was actually a video.
        // destinationURL is the real output file in every case (direct
        // downloads, Content-Disposition-renamed files, and yt-dlp's actual
        // produced media file alike) so it's the correct source of truth
        // here, not just a YouTube-specific patch.
        let ext = destinationURL.pathExtension.lowercased()
        let videoExts = ["mp4", "mov", "avi", "mkv", "webm", "flv", "m4v", "mpg", "mpeg"]
        let audioExts = ["mp3", "wav", "flac", "aac", "m4a", "ogg", "opus", "wma"]
        let docExts = ["pdf", "doc", "docx", "txt", "rtf", "pages", "odt", "xls", "xlsx", "ppt", "pptx"]
        let archiveExts = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "pkg", "iso"]
        
        if videoExts.contains(ext) { return "Video" }
        if audioExts.contains(ext) { return "Audio" }
        if docExts.contains(ext) { return "Documents" }
        if archiveExts.contains(ext) { return "Archives" }
        return "Other"
    }
    
    private var _segments: [DownloadSegment] = [] {
        didSet { refreshSegmentMap(force: true) }
    }
    /// Each stream track's pieces, as last reported by `StreamDownloader`.
    private var _streamPieces: [[SegmentMap.PieceState]] = []
    private var _segmentMapRefreshedAt = Date.distantPast
    private var _segmentMapRefreshScheduled = false
    /// Bytes arrive per network chunk; the bar redraws at most this often.
    private static let segmentMapInterval: TimeInterval = 0.15
    private var _startTime: Date?
    private var _endTime: Date?
    private var _speedTimer: Timer?
    private var _lastBytes: Int64 = 0
    private var _lastTime = Date()
    private var _hasRetriedAsSingleSegment = false
    /// Prevents infinite re-resolve loops: set to true the first time we
    /// Counts how many times we have auto-re-resolved a YouTube stream URL
    /// after a 403 mid-download. Capped at a max to prevent infinite loops
    /// when a URL is fundamentally broken. Reset on each pause() so each
    /// new resume cycle gets a fresh budget.
    private var _autoResolveCount = 0
    private static let _maxAutoResolves = 3
    /// Set (and latched) the first time a 403/410 hits with zero bytes ever
    /// downloaded for this task — the strong signal that this isn't a
    /// transient per-connection CDN throttle (worth the full 3-retry
    /// backoff budget) but the structural "this client currently requires a
    /// PO-Token nothing can generate" situation (see
    /// DownloadError.youtubeQualityCurrentlyBlocked). Once latched, the
    /// retry budget drops to 1 attempt instead of 3 — confirmed via direct
    /// curl testing against a fresh yt-dlp resolve that when this pattern
    /// holds, every retry just reproduces the exact same instant 403
    /// regardless of how many more times or how long we wait, so spending
    /// up to ~90 seconds and 3 separate yt-dlp invocations proving that
    /// again serves nobody. Reset in pause() alongside _autoResolveCount so
    /// each new resume cycle gets a fresh judgment (e.g. after the user
    /// picks a different, possibly-working quality).
    private var _zeroByteFailureChain = false
    private(set) var customHeaders: [String: String] = [:]
    
    /// One shared URLSession for every segment belonging to this task,
    /// instead of each segment building its own from scratch. Previously,
    /// each of up to 8 parallel segments spun up an entirely separate
    /// URLSession — meaning 8 independent DNS lookups, TCP handshakes, TLS
    /// negotiations, and (critically, for a slow redirect chain, such as a
    /// "latest release" download redirector) 8 independent redirect-chain
    /// walks, all competing for the same host at once. A shared session lets the
    /// underlying network stack actually reuse/pool connections the way
    /// HTTP is meant to work, instead of paying full connection setup cost
    /// per segment. This was very likely the real cause of the "15-18s
    /// before anything starts" resume delay — a connection-setup-contention
    /// problem, not a timeout problem (the earlier HEAD-timeout fix in
    /// validateResourceUnchangedIfNeeded addressed a real but different
    /// issue in the same resume path).
    private lazy var _sharedSegmentSession: URLSession = {
        let config = URLSessionConfiguration.cookieless
        config.httpMaximumConnectionsPerHost = max(segmentCount, 4)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // SharedSegmentSessionDelegate (in DownloadSegment.swift) routes
        // callbacks to the correct segment actor by URLSessionTask identity
        // — required because a single URLSession can only have one delegate,
        // so per-segment delegates aren't an option once segments share a
        // session.
        return URLSession(configuration: config, delegate: SharedSegmentSessionDelegate(), delegateQueue: nil)
    }()
    
    /// The active probe connection during the initial streaming GET phase.
    /// Stored so that pause()/cancel() can stop it if the user acts before
    /// the split decision is made.
    private var _activeProbe: ProbeConnection?

    /// Stops a join in flight on pause()/cancel(). Nil when no join runs.
    private var _mergeCancellation: MergeCancellation?

    /// HTTP validators from the initial response — used to detect if the
    /// remote file changed between pause and resume, and sent as `If-Range`
    /// on every part request.
    private(set) var etag: String?
    private(set) var lastModified: String?

    var validators: ResourceValidators { ResourceValidators(etag: etag, lastModified: lastModified) }

    /// Set by restartAfterResourceChange: this download runs without
    /// validators from then on. Cleared by a fresh restart.
    private var _validatorsDropped = false

    /// Set by restartAsWholeFile: the server compressed a ranged reply, so
    /// this download fetches the file in one request from then on. Cleared
    /// by a fresh restart.
    private var _rangesUnusable = false

    /// Seconds before retry `n`, given any Retry-After. See `RetryPolicy`;
    /// tests shorten it.
    var retryDelay: @Sendable (_ attempt: Int, _ serverAsked: TimeInterval?) -> TimeInterval = {
        RetryPolicy.delay(beforeRetry: $0, serverAsked: $1)
    }
    
    // Populated once by resolveIfNeeded() for sites (currently YouTube) that
    // need an external resolver — the real, currently-valid, direct media
    // URL differs from `url` (the page/watch URL the user actually gave us).
    // Everything downstream (fetchFileInfo, segments) uses these when set,
    // via `effectiveURL`/`effectiveHeaders`, and falls back to `url`/
    // `customHeaders` otherwise so non-YouTube sites are completely
    // unaffected.
    private var _effectiveURL: URL?
    private var _effectiveHeaders: [String: String] = [:]
    
    var effectiveURL: URL { _effectiveURL ?? forwardedURL ?? url }

    /// Where the link's web page forwarded to (see `WebPageReply`). Requests
    /// start here rather than at `url`, the page; persisted, or a relaunch
    /// would resume from the page.
    public private(set) var forwardedURL: URL?
    var effectiveHeaders: [String: String] { _effectiveHeaders.isEmpty ? customHeaders : _effectiveHeaders }
    
    /// If we validated recently enough, skip the network check entirely on
    /// resume rather than doing a HEAD every single time — a resume soon
    /// after a pause (the overwhelmingly common case) has essentially zero
    /// chance the remote file changed in the interim, so paying a network
    /// round-trip for that check every time was pure waste. 24h is long
    /// enough to skip nearly every real-world resume (pause today, resume
    /// tomorrow morning) while still catching the case that actually
    /// matters — resuming a download you paused a long time ago, where the
    /// remote file genuinely might have changed since.
    private static let validationBuffer: TimeInterval = 24 * 60 * 60
    /// Timestamp of the last successful HEAD validation. The 24h buffer window
    /// is measured from this, not from when you paused — so it doesn't matter
    /// whether you closed the app or not; what matters is when we last confirmed
    /// the remote file is still the same. Persisted across app restarts.
    private(set) var lastValidatedAt: Date?
    
    /// The page URL that originally triggered this download (e.g. the YouTube
    /// watch page, or the page with the download button). Stored so the
    /// Re-link flow can open it in the browser to let the user get a fresh URL.
    public private(set) var referrerURL: URL?
    
    /// Provenance of `destinationURL`'s final path component. This is what
    /// lets a server filename replace a page-title suggestion but never a
    /// filename the person explicitly chose.
    public private(set) var filenameSource: FilenameSource
    public var userProvidedDestinationName: Bool { filenameSource == .userProvided }

    /// The name this task's identity is compared against for duplicate
    /// detection — captured once at creation and never mutated by later
    /// suffixing ("(1)", "(2)", ...), unlike destinationURL. This is what
    /// lets DownloadManager.existingTask keep recognizing a repeat of the
    /// same source even after this task's own file has been auto-suffixed
    /// or explicitly saved as a separate copy — comparing against the
    /// current, possibly-already-mutated filename was the root cause of a
    /// whole family of bugs (detection silently breaking after the first
    /// repeat, extension-timing races for stream downloads, a task's own
    /// mid-flight recheck re-discovering a conflict it had already been
    /// told to ignore). For almost every download (a real filename already
    /// in the URL, or a stream's title — both known instantly) this is
    /// simply correct from the moment the task is created and never needs
    /// touching again. It's only updated in the one remaining case where
    /// nothing was knowable up front: a redirector-style URL whose real name
    /// only arrives later via Content-Disposition — see
    /// updateDestinationFilenameIfNeeded.
    public private(set) var originalName: String

    public init(
        id: UUID = UUID(),
        url: URL,
        destinationURL: URL,
        originalName: String,
        priority: DownloadPriority = .normal,
        segmentCount: Int = 8,
        initialStatus: DownloadStatus = .waiting,
        totalBytes: Int64 = 0,
        downloadedBytes: Int64 = 0,
        customHeaders: [String: String] = [:],
        etag: String? = nil,
        lastModified: String? = nil,
        lastValidatedAt: Date? = nil,
        referrerURL: URL? = nil,
        forwardedURL: URL? = nil,
        userProvidedDestinationName: Bool = false,
        filenameSource: FilenameSource? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.destinationURL = destinationURL
        self.originalName = originalName
        self.priority = priority
        self.createdAt = createdAt
        self.segmentCount = segmentCount
        self.status = initialStatus
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.customHeaders = customHeaders
        self.etag = etag
        self.lastModified = lastModified
        self.lastValidatedAt = lastValidatedAt
        self.referrerURL = referrerURL
        self.forwardedURL = forwardedURL
        self.filenameSource = filenameSource ?? (userProvidedDestinationName ? .userProvided : .originalURL)
    }
    
    func start() async throws {
        guard status == .waiting || status == .paused else { return }

        status = .starting

        // YouTube downloads are driven by yt-dlp rather than this engine's
        // probe/segment path — see YouTubeDownloader for the measurements that
        // forced that (SABR leaves the web client with no media formats, the
        // clients that do return direct URLs are authorized for only ~20% of
        // the stream, and the formats that actually work are fragmented HLS
        // that a byte-range downloader can't fetch at all).
        if ytFormatSelector != nil {
            do {
                guard !markDestinationMissingIfNeeded() else { return }
                try await runYouTubeDownload()
            } catch {
                stopSpeedTimer()
                // pause()/cancel() already own the terminal state when they're
                // what stopped the process.
                if case DownloadError.cancelled = error {
                    return
                }
                guard status != .paused, status != .cancelled else { return }
                status = .failed(error)
                self.error = error
            }
            return
        }

        // Native HLS/DASH stream download — segment-aware, no yt-dlp.
        if streamURL != nil {
            do {
                guard !markDestinationMissingIfNeeded() else { return }
                try await runStreamDownload()
            } catch {
                stopSpeedTimer()
                if case DownloadError.cancelled = error { return }
                guard status != .paused, status != .cancelled else { return }
                status = .failed(error)
                self.error = error
            }
            return
        }


        do {
            // Check locally before resolving URLs or opening a connection.
            // A missing destination is actionable immediately and should
            // never spend time on network work first.
            guard !markDestinationMissingIfNeeded() else { return }

            guard url.scheme == "http" || url.scheme == "https" || url.scheme == "ftp" else {
                throw DownloadError.invalidURL
            }
            try await resolveIfNeeded()
            // Guard: pause() may have fired while resolveIfNeeded() was
            // awaited. If so, status is now .paused — bail out immediately
            // rather than falling through and re-starting the download.
            guard status == .starting else { return }
            // It could have been deleted while URL resolution was in flight.
            guard !markDestinationMissingIfNeeded() else { return }
            
            if _segments.isEmpty && totalBytes == 0 {
                // Fresh start — use streaming probe (instant start, no HEAD)
                try await startWithStreamingProbe()
            } else {
                // Resume from pause or app restart — segments exist or can
                // be recreated from persisted metadata (totalBytes > 0).
                // Each segment's download() starts a fresh run, so nothing
                // from an earlier pause needs resetting here.

                // Skip the HEAD validation check if the task was validated
                // within the last 24h (validationBuffer) — the file almost
                // certainly hasn't changed in that window, and the check
                // adds real latency on slow-HEAD CDNs. Only run it once that
                // window has passed, where a genuine server-side update
                // becomes plausible.
                if shouldValidateOnResume() {
                    status = .validating
                    await validateResourceUnchangedIfNeeded()
                    guard status == .validating else { return }
                }
                
                if totalBytes == 0 {
                    // Validation discovered the file changed and reset us —
                    // run the fresh-start streaming-probe path instead.
                    try await startWithStreamingProbe()
                } else {
                    if _segments.isEmpty {
                        try await createSegments()
                    }
                    _startTime = Date()
                    status = .downloading
                    startSpeedTimer()
                    try await runPendingSegments()
                }
            }
        } catch DownloadError.cancelled {
            // Paused, cancelled, or superseded by a newer run: whoever stopped
            // it owns the status. Returning, not throwing, keeps the caller
            // from releasing a slot a newer run may hold.
            return
        } catch DownloadError.rangeNotHonored {
            do {
                try await retryAsSingleSegment()
            } catch DownloadError.cancelled {
                return
            } catch {
                // Would otherwise escape start() with the row at "Downloading".
                status = .failed(error)
                throw error
            }
        } catch DownloadError.resourceChanged {
            // Own do/catch: a throw from this clause would escape start()
            // with no terminal state, as with the link refresh below.
            do {
                try await restartAfterResourceChange()
            } catch {
                await handleRetryFailure(error)
            }
        } catch DownloadError.compressedReply {
            do {
                try await restartAsWholeFile()
            } catch {
                await handleRetryFailure(error)
            }
        } catch DownloadError.httpError(let code) where code == 403 || code == 410 {
            // A segment received a 403 (link expired) or 410 (gone).
            // For YouTube tasks: silently re-resolve via yt-dlp and retry
            // the failed segments (guard prevents loops).
            // Works for both direct youtube.com URLs and googlevideo.com streams with a YouTube referrer.
            if downloadedBytes == 0 { _zeroByteFailureChain = true }
            let effectiveMax = _zeroByteFailureChain ? 1 : Self._maxAutoResolves
            if let pageURL = resolvablePageURL, await YouTubeResolver.shared.isSupported(url: pageURL), _autoResolveCount < effectiveMax {
                _autoResolveCount += 1
                status = .refreshingLink
                // Back off before re-resolving: 403s from googlevideo.com are
                // very often transient per-connection/CDN throttling rather
                // than genuine link expiry, and hammering yt-dlp + the CDN
                // again within milliseconds reliably reproduces the 403. A
                // short wait lets the edge node's per-request budget reset.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard status == .refreshingLink else { return }
                do {
                    try await resolveIfNeeded(forceRefresh: true)
                    // Guard: resolveIfNeeded(forceRefresh:) shells out to yt-dlp
                    // and can take many seconds, same as the other awaits already
                    // guarded above (and the sleep above this). pause() may have
                    // fired while it was in flight — without this check, we'd
                    // unconditionally overwrite status back to .downloading and
                    // restart segments even though the user explicitly paused
                    // during the link refresh.
                    guard status == .refreshingLink else { return }
                    // The retry below MUST go through its own catch path — a
                    // `try` inside this catch block would propagate straight out
                    // of start(), leaving the task frozen at .refreshingLink/
                    // .starting forever (this was the "Getting fresh link… then
                    // stuck at Starting" failure: the re-resolved probe 403'd,
                    // that error escaped, and nothing ever set a terminal state).
                    // If the fresh stream also 403s we land back in this same
                    // handler with a fresh budget; any other error marks .failed.
                    try await retryAfterLinkRefresh()
                } catch {
                    await handleRetryFailure(error)
                }
            } else if _zeroByteFailureChain, resolvablePageURL != nil {
                // Never got a single byte across every attempt, even after a
                // from-scratch yt-dlp re-resolve — the specific, currently-
                // known-broken pattern (see DownloadError doc). Surface that
                // clearly instead of a bare "HTTP error: 403", and instead of
                // continuing to burn the full retry budget on something
                // that's proven itself structural, not transient.
                let specificError = DownloadError.youtubeQualityCurrentlyBlocked
                status = .failed(specificError)
                throw specificError
            } else {
                // Non-YouTube: the download link has expired. Flip to
                // .urlExpired so the UI can show a Re-link option (Step 5).
                // Temp files are preserved on disk so the download can
                // resume from where it left off once the link is refreshed.
                status = .urlExpired(referrerURL: referrerURL)
            }
        } catch {
            status = .failed(error)
            throw error
        }
    }
    
    /// Resumes downloading after a successful forceRefresh re-resolution
    /// (YouTube 403 recovery). Factored out of start()'s 403 catch clause so
    /// the retry can sit inside its own do/catch — see the comment there for
    /// why letting this throw escape start() froze tasks forever.
    private func retryAfterLinkRefresh() async throws {
        if totalBytes == 0 {
            // Fresh download — the probe 403'd before we got any
            // metadata (totalBytes, segment layout, etc.). Now that
            // we have a fresh effectiveURL from re-resolution, just
            // restart the whole probe flow rather than trying to
            // createSegments with zero totalBytes (which would throw
            // .noData).
            status = .starting
            try await startWithStreamingProbe()
        } else {
            // Resuming a partially-downloaded file — recreate segments
            // so each picks up its on-disk partial bytes.
            _segments = []
            try await createSegments()
            status = .downloading
            startSpeedTimer()
            try await runPendingSegments()
        }
    }

    /// Terminal handler for errors thrown by the post-refresh retry. Maps the
    /// error back onto a user-visible state instead of leaking the exception
    /// out of start() (which previously left the task stuck at
    /// .refreshingLink/.starting with no way forward).
    private func handleRetryFailure(_ error: Error) async {
        stopSpeedTimer()
        switch error {
        case DownloadError.cancelled:
            // The user paused/cancelled while the retry was in flight —
            // pause()/cancel() already owns the terminal state.
            break
        case DownloadError.httpError(let code) where (code == 403 || code == 410) && resolvablePageURL == nil:
            // Not YouTube, so there's nothing to re-resolve: the link expired.
            // Same as start(): keep the partial data and offer Re-link.
            guard status != .paused, status != .cancelled, status != .completed else { return }
            status = .urlExpired(referrerURL: referrerURL)
        case DownloadError.httpError(let code) where (code == 403 || code == 410) && _autoResolveCount < (_zeroByteFailureChain ? 1 : Self._maxAutoResolves):
            // The fresh link ALSO 403'd immediately — re-enter the same
            // recovery path with the remaining budget (each attempt backs
            // off longer before re-resolving).
            if downloadedBytes == 0 { _zeroByteFailureChain = true }
            status = .refreshingLink
            _autoResolveCount += 1
            let backoff = UInt64(3 * (1 << _autoResolveCount)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: backoff)
            guard status == .refreshingLink else { return }
            do {
                try await resolveIfNeeded(forceRefresh: true)
                guard status == .refreshingLink else { return }
                try await retryAfterLinkRefresh()
            } catch {
                await handleRetryFailure(error)
            }
        default:
            // The user paused (or the task otherwise moved on) while the
            // refresh/retry was in flight — that error surfaces as a
            // cancellation, and pause()/cancel() already owns the terminal
            // state, so don't clobber it here.
            guard status != .paused, status != .cancelled, status != .completed else { return }
            // Out of budget or a different kind of failure — surface it. If
            // this was specifically the zero-bytes-ever 403 pattern, swap in
            // the clearer, specific error rather than a bare "HTTP error: 403"
            // (see DownloadError.youtubeQualityCurrentlyBlocked).
            if _zeroByteFailureChain, downloadedBytes == 0, case DownloadError.httpError(let code) = error, code == 403 || code == 410 {
                let specificError = DownloadError.youtubeQualityCurrentlyBlocked
                status = .failed(specificError)
                self.error = specificError
            } else {
                status = .failed(error)
                self.error = error
            }
        }
    }

    // MARK: - yt-dlp-driven download (YouTube)
    //
    // Set together for a YouTube download; nil for every other task, which
    // keeps using the probe/segment engine untouched. `ytFormatSelector` is a
    // yt-dlp `-f` expression and `ytPageURL` the watch page (yt-dlp re-resolves
    // fresh stream URLs itself each run, so nothing here can expire).
    public private(set) var ytFormatSelector: String?
    public private(set) var ytPageURL: URL?

    /// Links this task to a yt-dlp-driven download. Called at creation by
    /// DownloadManager.addYouTubeDownload, and on relaunch when restoring.
    func configureYouTubeDownload(formatSelector: String, pageURL: URL) {
        ytFormatSelector = formatSelector
        ytPageURL = pageURL
    }

    // MARK: - Native stream download (HLS/DASH)
    //
    // Set together for a native stream download (HLS or DASH); nil for every
    // other task type. The stream URL is the manifest/variant-playlist URL that
    // the browser sniffed — StreamDownloader fetches, parses, and assembles
    // segments from it without yt-dlp.
    public private(set) var streamURL: URL?
    public private(set) var streamType: String?          // "hls" or "dash"
    public private(set) var streamRepresentationId: String?
    public private(set) var streamBandwidth: Int?
    /// Preferred DASH audio language captured when this task was created.
    /// Persisting the value on the task (rather than rereading Settings on
    /// resume) keeps a paused download's selected audio track stable.
    public private(set) var streamPreferredAudioLanguage: String?
    /// Candidate audio renditions for an HLS variant's AUDIO group (see
    /// HLSAudioCandidate's doc comment) — nil/empty for a combined stream
    /// and for DASH, which resolves its own audio independently.
    public private(set) var streamHLSAudioTracks: [HLSAudioCandidate]?

    /// Links this task to the native stream download path. Called at creation by
    /// DownloadManager.addStreamDownload, and on relaunch when restoring.
    func configureStreamDownload(
        streamURL: URL,
        streamType: String,
        customHeaders: [String: String],
        representationId: String?,
        bandwidth: Int?,
        preferredAudioLanguage: String? = nil,
        hlsAudioTracks: [HLSAudioCandidate]? = nil,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil
    ) {
        self.streamURL = streamURL
        self.streamType = streamType
        self.customHeaders = customHeaders
        self.streamRepresentationId = representationId
        self.streamBandwidth = bandwidth
        self.streamPreferredAudioLanguage = preferredAudioLanguage
        self.streamHLSAudioTracks = hlsAudioTracks
        // Without the last known counts a restored paused row draws an empty
        // bar — there is no byte total to fall back on. Refreshed on resume.
        if let completedSegments, let totalSegments, totalSegments > 0 {
            self.progressBasis = .segments(completed: completedSegments, total: totalSegments)
        }
    }

    /// Runs the native stream download (HLS/DASH) via StreamDownloader,
    /// mirroring progress onto this task so the UI row shows real bytes/speed.
    private func runStreamDownload() async throws {
        guard let streamURL, let streamType else { return }

        _startTime = _startTime ?? Date()
        _streamRunStart = Date()
        isMerging = false
        status = .downloading
        startSpeedTimer()

        let id = self.id
        let headers = self.customHeaders
        let concurrency = self.segmentCount

        // StreamDownloader returns the actual output URL — it may differ from
        // destinationURL in extension (.ts vs .mp4) depending on the stream format.
        // We MUST update destinationURL after the call or the UI will show "Moved"
        // because it checks the original path which no longer has a file there.
        let finalURL = try await StreamDownloader.shared.download(
            taskID: id,
            manifestURL: streamURL,
            streamType: streamType,
            destination: destinationURL,
            headers: headers,
            segmentConcurrency: concurrency,
            representationId: streamRepresentationId,
            bandwidth: streamBandwidth,
            preferredAudioLanguage: streamPreferredAudioLanguage,
            hlsAudioTracks: streamHLSAudioTracks
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadedBytes = progress.downloadedBytes
                // No total on purpose: totalBytes stays 0 until the finished
                // file supplies it, so no displayed size ever grows.
                if progress.totalSegments > 0 {
                    self.progressBasis = .segments(
                        completed: progress.completedSegments,
                        total: progress.totalSegments
                    )
                }
                self.isMerging = progress.phase == .merging
                self._streamPieces = progress.pieces
                self.refreshSegmentMap(force: progress.phase == .merging)
                // speed is updated by the task's own speed timer
            }
        }

        // Update the task's destination to match where the file was actually written.
        // This is what the UI uses for "show in Finder" and file-exists checks.
        destinationURL = finalURL

        // Fix up byte counts from actual file size.
        stopSpeedTimer()
        let actualSize = (try? FileManager.default.attributesOfItem(
            atPath: finalURL.path
        )[.size] as? Int64) ?? nil
        if let sz = actualSize, sz > 0 {
            totalBytes = sz
            downloadedBytes = sz
        }
        // Real size now, so the finished row measures like every other one.
        isMerging = false
        progressBasis = .bytes
        status = .completed
        _endTime = Date()
    }

    /// Runs yt-dlp to completion, mirroring its progress onto this task so the
    /// row shows real bytes/speed like any other download.
    private func runYouTubeDownload() async throws {
        guard let ytFormatSelector, let ytPageURL else { return }

        _startTime = _startTime ?? Date()
        status = .downloading

        let useCookies = AppSettings.shared.youtubeUseBrowserCookies
        let cookieBrowser = useCookies ? AppSettings.shared.youtubeCookieBrowser : nil

        let id = self.id
        // The name that comes back may carry a " (n)": the download reserved
        // its filename when it was added, and yt-dlp or the muxer saves beside
        // anything that arrived at that path since, rather than over it.
        let written = try await YouTubeDownloader.shared.download(
            taskID: id,
            pageURL: ytPageURL,
            formatSelector: ytFormatSelector,
            destination: destinationURL,
            cookiesFromBrowser: cookieBrowser,
            // Seeded at creation from the resolver's reported sizes, and
            // persisted, so a resumed two-file download keeps reporting the
            // same total rather than rediscovering it.
            expectedTotalBytes: totalBytes
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only accept forward progress: yt-dlp reports per-stream byte
                // counts, so a video→audio transition (or a fragmented restart)
                // otherwise makes the bar jump backwards.
                if progress.downloadedBytes >= self.downloadedBytes {
                    self.downloadedBytes = progress.downloadedBytes
                }
                if progress.totalBytes > 0 {
                    self.totalBytes = max(self.totalBytes, progress.totalBytes)
                }
                self.speed = progress.bytesPerSecond
            }
        }

        // yt-dlp exited 0 and, for a video+audio pick, MediaMuxer has merged
        // the two tracks. Adopt whatever name the file actually landed under
        // before reading its size, or a late " (n)" would be measured against
        // a path nothing was written to. originalName stays put: it is this
        // download's identity, not its address.
        if written != destinationURL { destinationURL = written }

        if totalBytes == 0 || downloadedBytes > totalBytes {
            let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) ?? nil
            if let size, size > 0 {
                totalBytes = size
                downloadedBytes = size
            }
        } else {
            downloadedBytes = totalBytes
        }
        speed = 0
        status = .completed
        _endTime = Date()
        stopSpeedTimer()
    }

    /// Returns true when the HEAD staleness check should run before resuming.
    ///
    /// Uses lastValidatedAt (when we last ran the HEAD check) rather than
    /// pausedAt (when you paused) — the buffer window should measure from
    /// the last actual verification, regardless of how many times you've
    /// paused/resumed or whether you restarted the app in between.
    ///
    /// Falls back to running the check when lastValidatedAt is nil (first
    /// resume ever for this task — conservative safe default).
    private func shouldValidateOnResume() -> Bool {
        guard let lastValidatedAt else { return true }
        return Date().timeIntervalSince(lastValidatedAt) > Self.validationBuffer
    }
    
    /// Before resuming from partial data (existing segment temp files on
    /// disk), do a cheap validation check against the remote resource's
    /// ETag/Last-Modified (captured during the original probe) to confirm
    /// it's still the same file.
    ///
    /// Deliberately lightweight — a single HEAD, and only when we actually
    /// have prior validators to compare against — so this is a correctness
    /// check, not a reintroduction of the old HEAD-probe-first delay the
    /// streaming-probe redesign specifically eliminated. It only runs once
    /// per resume, not before every byte can start flowing, and if the
    /// server doesn't cooperate (rejects HEAD, sends neither header) it
    /// fails open — proceeds optimistically rather than blocking the resume.
    private func validateResourceUnchangedIfNeeded() async {
        guard etag != nil || lastModified != nil else { return }
        guard totalBytes > 0 else { return }
        
        var request = URLRequest(url: effectiveURL)
        request.httpMethod = "HEAD"
        // This must be a short, hard timeout — some CDNs/redirect chains
        // (a "latest release" style redirector in particular) are slow or
        // effectively unresponsive specifically to HEAD, even
        // though a GET to the same resource returns fine. That's exactly
        // why the whole streaming-probe architecture avoids HEAD for the
        // initial download in the first place. Without an explicit timeout
        // here, this "cheap sanity check" could silently block a resume for
        // 60+ seconds (the OS default) on exactly the sites where a plain
        // GET is already known to be fast. "Fails open" below only helps if
        // the server responds quickly with a rejection — it does nothing
        // for a server that just hangs, which is the actual failure mode
        // here.
        request.timeoutInterval = 5
        for (header, value) in effectiveHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        // The validators describe the uncompressed file the probe asked for.
        ContentCoding.requestUncompressed(&request)

        guard let (_, response) = try? await URLSession.cookieless.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return
        }
        
        let currentETag = http.value(forHTTPHeaderField: "ETag")
        let currentLastModified = http.value(forHTTPHeaderField: "Last-Modified")
        
        guard validators.differ(from: http) else {
            // File unchanged — record that we just verified it so the next
            // resume within 24h can skip this check entirely.
            lastValidatedAt = Date()
            return
        }
        
        logger.error("Remote file changed since last check (ETag/Last-Modified mismatch) — discarding partial data and starting fresh")
        
        // Every segment file, not just `_segments`: after a relaunch that list
        // is empty, and a stale segment file left here is appended to by the
        // fresh download that reuses its name.
        TemporaryStorage.removeSegmentFiles(of: id)
        
        _segments = []
        totalBytes = 0
        downloadedBytes = 0
        etag = currentETag
        lastModified = currentLastModified
        lastValidatedAt = Date()  // fresh start counts as verified
    }
    
    /// The core of the new architecture: starts a streaming GET that doubles
    /// as both the metadata probe AND segment 0's data source. Bytes flow to
    /// disk from the first response, eliminating the 25+ second HEAD delay.
    /// Below this size a download uses a single ranged connection instead of
    /// splitting into `segmentCount` parallel ones. Purely a parallelism
    /// choice, not a correctness one — both paths issue ranged requests. See
    /// the decision site in startWithStreamingProbe().
    private static let minimumSizeForSegmenting: Int64 = 10 * 1024 * 1024

    private func startWithStreamingProbe() async throws {
        // Compute segment 0's temp file path (must match what DownloadSegment
        // would use, so segment 0 seamlessly picks up our bytes on disk).
        let tempDir = FileManager.default.temporaryDirectory
        let segment0TempPath = tempDir.appendingPathComponent("\(id.uuidString)-segment-0.tmp")

        // A fresh start: without a known size there was no range to resume,
        // so anything on disk under this download's name is left over, and
        // the probe would append to it.
        TemporaryStorage.removeSegmentFiles(of: id)
        downloadedBytes = 0
        // Also reached from .validating, when a resume found the file changed;
        // everything below waits on .starting.
        status = .starting

        // Start the probe — bytes begin streaming immediately
        let (probe, metadata) = try await openProbe(writingTo: segment0TempPath, requestsRange: !_rangesUnusable)
        
        // Extract metadata
        totalBytes = metadata.contentLength
        if !_validatorsDropped {
            etag = metadata.etag
            lastModified = metadata.lastModified
        }

        // Pin resolved URL (prevents different segments hitting different
        // versions behind a redirector like .../latest/darwin-arm64).
        // Also re-apply the googlevideo.com throttle bypass: YouTube's CDN
        // may redirect to a different edge node and the redirect target URL
        // might not carry ratebypass=yes. Keep it in place so every segment
        // request uses the unthrottled URL.
        if let resolvedURL = metadata.resolvedURL, resolvedURL != effectiveURL {
            logger.notice("Pinning task=\(self.id, privacy: .public) to resolved URL: \(resolvedURL.absoluteString)")
            let pinnedURL = YouTubeResolver.bypassGooglevideoThrottle(resolvedURL)
            _effectiveURL = pinnedURL
            // Re-apply CDN headers for the redirect target — the edge node
            // the CDN redirected us to is still googlevideo.com, but Origin
            // and Referer must be in every request, not just the first one.
            _effectiveHeaders = YouTubeResolver.ensureYouTubeCDNHeaders(_effectiveHeaders, for: pinnedURL)
        }
        
        // Update filename from Content-Disposition or resolved URL
        await updateDestinationFilenameIfNeeded(
            contentDisposition: metadata.contentDisposition,
            resolvedURL: metadata.resolvedURL
        )
        // If a duplicate-conflict sheet suspended this function, one of two
        // things happened on resume: a "don't proceed" answer (skip / keep
        // existing, or a row-level pause/cancel while the sheet was up) has
        // already torn the task down or parked it — status is no longer an
        // active one, so bail before starting segments; or a "keep going"
        // answer (.addSeparate/.restart) resumed the wait with
        // markConflictResolved, which parks us at .downloading rather than
        // .starting — so accept both, or the resumed download would bail out
        // here and hang forever with a dead probe. Same guard style as every
        // other await in start() above.
        guard status == .starting || status == .downloading else { return }

        // A suspended-then-resumed conflict cancels the probe (see
        // markAwaitingConflictResolution), and _activeProbe is only nilled by
        // that path — use it to know whether the probe below is still live.
        let probeWasCancelledForConflict = _activeProbe == nil
        
        // Segment vs Single-stream decision:
        // When range requests are supported and size is known, cancel probe and transition to
        // proper DownloadSegment(s) which handle segmented downloading, live speed, pause/resume,
        // and progress tracking.
        //
        // No size floor here, deliberately. The probe's GET is bounded to
        // ProbeConnection.probeRangeEnd (64 KB), so when the server honours
        // ranges the probe can never finish a file by itself — the "let the
        // probe finish" branch below is only correct when the server *ignored*
        // the Range and streamed the whole body. Gating segmentation on a
        // minimum size would route small range-supporting files into that
        // branch and truncate them at 64 KB.
        let canUseSegments = metadata.supportsRange && totalBytes > 0 && !_rangesUnusable

        // Small files gain nothing from 8 parallel connections — connection
        // setup costs more than it saves, and it multiplies request count
        // against CDNs that rate-limit per request. Still the ranged path, so
        // correctness is unchanged; only the parallelism drops.
        if canUseSegments && totalBytes < Self.minimumSizeForSegmenting {
            segmentCount = 1
        }
        
        if canUseSegments {
            // Cancel probe — segment 0 will pick up probe's bytes on disk
            probe.cancel()
            _activeProbe = nil
            
            logger.notice("Probe wrote \(probe.bytesWritten, privacy: .public) bytes before starting \(self.segmentCount, privacy: .public) segments for task=\(self.id, privacy: .public)")
            
            // Create segments and start downloading
            try await createSegments()
            
            _startTime = Date()
            status = .downloading
            startSpeedTimer()
            
            try await runPendingSegments()
        } else {
            // No usable ranges: the file comes in one request. The probe is
            // that request only when its reply is the whole file — a 200
            // the conflict sheet didn't interrupt. A 206 stops at the probe's
            // range (a compressed reply, or one with no total size).
            segmentCount = 1
            _startTime = Date()
            status = .downloading
            startSpeedTimer()

            let probeHasWholeFile = metadata.statusCode == 200 && !probeWasCancelledForConflict
            if !probeHasWholeFile {
                probe.cancel()
                _activeProbe = nil
            }
            try await downloadWholeFile(continuing: probeHasWholeFile ? probe : nil, to: segment0TempPath)
        }
    }

    /// A probe for this download, registered so pause()/cancel() can stop it.
    private func makeProbe(writingTo tempPath: URL, requestsRange: Bool) -> ProbeConnection {
        let probe = ProbeConnection(
            url: effectiveURL,
            headers: effectiveHeaders,
            tempFileURL: tempPath,
            requestsRange: requestsRange
        )
        probe.onProgress = { [weak self] chunkBytes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadedBytes += chunkBytes
            }
        }
        _activeProbe = probe
        return probe
    }

    /// Starts the probe and waits for its reply, starting it again after a
    /// failure of the moment (see `RetryPolicy`). As the first request of a
    /// download, a host DNS can't find fails at once. A web page where a file
    /// was expected is followed to the file it forwards to, or fails.
    private func openProbe(writingTo tempPath: URL, requestsRange: Bool) async throws -> (ProbeConnection, ProbeConnection.Metadata) {
        var failures = 0
        var forwards = 0
        while true {
            let probe = makeProbe(writingTo: tempPath, requestsRange: requestsRange)
            let metadata: ProbeConnection.Metadata
            do {
                metadata = try await probe.start()
            } catch {
                probe.cancel()
                if _activeProbe === probe { _activeProbe = nil }
                // pause() cancelled it, and owns the state.
                guard status == .starting else { throw DownloadError.cancelled }
                failures += 1
                guard RetryPolicy.isTransient(error, serverReached: false),
                      failures < RetryPolicy.maxConsecutiveFailures else {
                    // The part file the probe created, empty or nearly.
                    try? FileManager.default.removeItem(at: tempPath)
                    throw error
                }
                let seconds = retryDelay(failures, nil)
                logger.notice("Probe failed for task=\(self.id, privacy: .public) (\(error.localizedDescription, privacy: .public)) — retry \(failures) in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
                try await RetryPolicy.wait(seconds) { status == .starting }
                // Nothing arrives before the reply, but a reply cut off just
                // after it can leave bytes the next probe would append to.
                try? FileManager.default.removeItem(at: tempPath)
                continue
            }

            guard metadata.isWebPage, !WebPageReply.isPageName(destinationURL.lastPathComponent) else {
                return (probe, metadata)
            }
            let page = metadata.resolvedURL ?? effectiveURL
            let forward: URL?
            do {
                forward = try await fileURL(forwardedToBy: probe, metadata, page: page)
            } catch {
                probe.cancel()
                if _activeProbe === probe { _activeProbe = nil }
                try? FileManager.default.removeItem(at: tempPath)
                throw error
            }
            // Served as a page, but the bytes are the file's.
            guard let forward else { return (probe, metadata) }

            probe.cancel()
            if _activeProbe === probe { _activeProbe = nil }
            try? FileManager.default.removeItem(at: tempPath)
            downloadedBytes = 0
            forwards += 1
            guard forwards <= WebPageReply.maxForwards else {
                logger.error("Task=\(self.id, privacy: .public) gave up after \(forwards - 1) pages forwarding to pages")
                throw DownloadError.webPage
            }
            logger.notice("Task=\(self.id, privacy: .public) got a web page that forwards to its file — following it to \(forward.absoluteString)")
            follow(forward, from: page)
            failures = 0
        }
    }

    /// For a reply that is a web page where a file was expected: the URL the
    /// page forwards to (its Refresh header, else a meta refresh), or nil
    /// when the body isn't HTML after all and is the file with the wrong type.
    /// A page that forwards nowhere throws `.webPage`, rather than being
    /// saved under the file's name.
    private func fileURL(forwardedToBy probe: ProbeConnection, _ metadata: ProbeConnection.Metadata, page: URL) async throws -> URL? {
        if let refresh = metadata.refresh, let target = WebPageReply.refreshTarget(refresh, page: page) {
            return target
        }
        let start = await probe.firstBytes(WebPageReply.inspectedLength)
        guard status == .starting else { throw DownloadError.cancelled }
        if let refresh = WebPageReply.metaRefresh(in: start), let target = WebPageReply.refreshTarget(refresh, page: page) {
            return target
        }
        guard start.isEmpty || WebPageReply.looksLikeHTML(start) else { return nil }
        logger.error("Task=\(self.id, privacy: .public) got a web page that doesn't forward to a file: \(page.absoluteString)")
        throw DownloadError.webPage
    }

    /// Sends later requests to `target` as a browser following the page
    /// would: with the page as Referer, and without the page's credentials
    /// when the file is on another host.
    private func follow(_ target: URL, from page: URL) {
        let sameHost = target.host?.lowercased() == page.host?.lowercased()
        var headers = effectiveHeaders.filter { header, _ in
            let name = header.lowercased()
            return name != "referer" && (sameHost || (name != "cookie" && name != "authorization"))
        }
        headers["Referer"] = page.absoluteString
        _effectiveHeaders = headers
        _effectiveURL = target
        forwardedURL = target
    }

    /// Downloads the file in one request, for a server whose ranges can't be
    /// used, continuing `probe` when its reply is already the whole file.
    ///
    /// There's no range to resume from, so a request that fails for a passing
    /// reason starts over from byte 0, up to `RetryPolicy`'s limit.
    private func downloadWholeFile(continuing probe: ProbeConnection?, to tempPath: URL) async throws {
        var pending = probe
        var failures = 0
        while true {
            do {
                let live: ProbeConnection
                if let pending {
                    live = pending
                } else {
                    try? FileManager.default.removeItem(at: tempPath)
                    downloadedBytes = 0
                    live = makeProbe(writingTo: tempPath, requestsRange: false)
                    let metadata = try await live.start()
                    // Where the file actually came from, for any request after this.
                    if let resolved = metadata.resolvedURL, resolved != effectiveURL {
                        _effectiveURL = resolved
                    }
                    totalBytes = metadata.contentLength
                }
                pending = nil

                try await live.awaitCompletion()
                _activeProbe = nil
                // A cancelled request reports success with part of the body.
                guard status == .downloading else { return }

                // A body shorter than its declared length is a dropped
                // connection, however the transfer reported it.
                if totalBytes > 0, live.bytesWritten != totalBytes {
                    logger.error("Whole-file download for task=\(self.id, privacy: .public) ended at \(live.bytesWritten, privacy: .public) of \(self.totalBytes, privacy: .public) bytes")
                    throw URLError(.networkConnectionLost)
                }
                if totalBytes == 0 {
                    totalBytes = live.bytesWritten
                }
                downloadedBytes = live.bytesWritten

                try moveProbeToDestination(from: tempPath)

                status = .completed
                _endTime = Date()
                stopSpeedTimer()
                return
            } catch {
                _activeProbe?.cancel()
                _activeProbe = nil
                guard status == .downloading else { throw DownloadError.cancelled }
                failures += 1
                guard RetryPolicy.isTransient(error),
                      failures < RetryPolicy.maxConsecutiveFailures else { throw error }
                let seconds = retryDelay(failures, nil)
                logger.notice("Whole-file download failed for task=\(self.id, privacy: .public) (\(error.localizedDescription, privacy: .public)) — starting over, retry \(failures) in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
                try await RetryPolicy.wait(seconds) { status == .downloading }
            }
        }
    }
    
    /// Moves the probe's completed temp file to the final destination.
    private func moveProbeToDestination(from tempPath: URL) throws {
        // Ensure destination directory exists
        let destDir = destinationURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        try claimDestination { try DownloadDestination.move(tempPath, to: $0) }
    }
    
    /// A part response named a different version of the file than the bytes
    /// on disk, so they are discarded and the download starts from zero.
    ///
    /// That pass runs without validators or `If-Range`. Some servers report a
    /// new ETag per machine or a new Last-Modified per response for an
    /// unchanged file; checking again would fail a working download. A
    /// from-zero pass has no old bytes to mix with, and without validators
    /// this can't be reached twice.
    private func restartAfterResourceChange() async throws {
        logger.error("Remote file changed mid-download — discarding partial data and starting over without validators")

        // Stop the siblings before their files go.
        for segment in _segments {
            await segment.cancel()
        }
        TemporaryStorage.removeSegmentFiles(of: id)
        _segments = []
        totalBytes = 0
        downloadedBytes = 0
        etag = nil
        lastModified = nil
        _validatorsDropped = true
        lastValidatedAt = Date()  // a fresh start counts as verified
        stopSpeedTimer()

        status = .starting
        try await startWithStreamingProbe()
    }

    /// A part came back compressed although every request asks for the file
    /// uncompressed (see `ContentCoding`), so no part can be placed at its
    /// offset. The parts are discarded and the file is fetched in one
    /// request, which a browser would also have decoded whole.
    private func restartAsWholeFile() async throws {
        logger.error("Server compressed a ranged reply for task=\(self.id, privacy: .public) — discarding the parts and downloading the file in one request")

        for segment in _segments {
            await segment.cancel()
        }
        TemporaryStorage.removeSegmentFiles(of: id)
        _segments = []
        totalBytes = 0
        downloadedBytes = 0
        _rangesUnusable = true
        stopSpeedTimer()

        status = .starting
        try await startWithStreamingProbe()
    }

    /// Some servers/CDNs (often a redirect chain, e.g. a "latest release"
    /// redirector) don't reliably honor Range requests for every parallel
    /// connection — one segment can silently get the whole file (200) where
    /// the others get their real slice (206), which would corrupt the merged
    /// file if we trusted it. Rather than just failing outright once that's
    /// detected, retry once as a single connection: with only one segment
    /// covering the entire file, a 200-instead-of-206 response is harmless
    /// (there's nothing to misalign), so this is a real, correct fallback —
    /// not a silent data-integrity risk, just slower than parallel segments.
    private func retryAsSingleSegment() async throws {
        guard !_hasRetriedAsSingleSegment else {
            let error = DownloadError.rangeNotHonored
            status = .failed(error)
            throw error
        }
        _hasRetriedAsSingleSegment = true
        
        logger.error("Retrying as a single connection — server didn't honor Range for parallel segments")
        
        // Clean up the failed multi-segment attempt.
        TemporaryStorage.removeSegmentFiles(of: id)
        _segments = []
        segmentCount = 1
        stopSpeedTimer()
        
        // Skip the full start() → prepareSegmentsIfNeeded() → fetchFileInfo()
        // cycle — we already have totalBytes, effectiveURL, resolved filename,
        // etc. from the first attempt. Just recreate segments (now a single
        // one covering the whole file) and run them directly.
        try await createSegments()
        _startTime = Date()
        status = .downloading
        startSpeedTimer()
        try await runPendingSegments()
    }
    
    // prepareSegmentsIfNeeded() removed — the new streaming probe flow
    // in start()/startWithStreamingProbe() handles segment creation directly.
    // For resume, start() recreates segments from persisted metadata.
    
    /// Returns the watch page URL if this download is for YouTube
    /// (either the main URL or via the referrer passed by the extension).
    private var resolvablePageURL: URL? {
        if let ref = referrerURL, let host = ref.host?.lowercased(), (host.contains("youtube.com") || host == "youtu.be") {
            return ref
        }
        if let host = url.host?.lowercased(), (host.contains("youtube.com") || host == "youtu.be") {
            return url
        }
        return nil
    }

    /// Extracts the YouTube format ID (itag) if present in the URL, to preserve
    /// the user's selected format when re-resolving an expired stream.
    private var urlItag: String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }
        return items.first(where: { $0.name == "itag" })?.value
    }

    /// Shells out to yt-dlp for sites it needs to handle (currently YouTube)
    /// to get a real, currently-valid direct media URL.
    private func resolveIfNeeded(forceRefresh: Bool = false) async throws {
        let pageURL: URL?
        if forceRefresh {
            // On a 403 retry, we can use the referrer to get a fresh link for the stream.
            pageURL = resolvablePageURL
        } else {
            // On initial start, ONLY resolve if the main URL itself is a YouTube page.
            // Do NOT auto-resolve direct googlevideo.com URLs (e.g. from the Safari extension)
            // at the very beginning, because that overrides the user's specific format choice with "best".
            if let host = url.host?.lowercased(), (host.contains("youtube.com") || host == "youtu.be") {
                pageURL = url
            } else {
                pageURL = nil
            }
        }
        
        guard let validPageURL = pageURL, await YouTubeResolver.shared.isSupported(url: validPageURL) else { return }
        
        // On a normal start, skip if we already have a resolved URL from
        // a previous call this session. On forceRefresh (expired 403 retry)
        // always re-run yt-dlp to get a fresh signed stream URL.
        if !forceRefresh && _effectiveURL != nil { return }
        
        // Pass urlItag so if we are recovering a direct URL, we request the same format
        let resolved = try await YouTubeResolver.shared.resolve(url: validPageURL, format: urlItag)
        _effectiveURL = resolved.url
        // Resolver-provided headers take priority (they're what yt-dlp says
        // this exact stream needs), but keep any explicit customHeaders the
        // caller already set that the resolver didn't mention.
        _effectiveHeaders = resolved.headers.merging(customHeaders) { resolverValue, _ in resolverValue }
        
        // Only update the destination filename on a fresh start — if we're
        // force-refreshing mid-download the file already exists at the
        // original path, renaming it now would orphan the partial data.
        if !forceRefresh,
           let suggested = FilenameResolver.sanitize(resolved.suggestedFilename ?? ""),
           FilenameResolver.shouldReplace(current: filenameSource, with: .extractorMetadata) {
            let folder = destinationURL.deletingLastPathComponent()
            destinationURL = folder.appendingPathComponent(suggested)
            filenameSource = .extractorMetadata
        }
    }
    
    /// Keeps activityMessage in sync with status automatically.
    /// Only sets a message for the two intermediate states where the engine
    /// is doing something that takes noticeable time — everything else is
    /// either instant or already has its own UI (speed, ETA, error text).
    private func updateActivityMessage() {
        // Status stays .downloading through a merge. Gated on it rather than
        // on the flag alone, so a merge that throws cannot leave a failed row
        // still claiming to merge.
        if isMerging, status == .downloading {
            activityMessage = streamURL != nil ? "Merging audio and video…" : "Combining parts…"
            return
        }
        switch status {
        case .validating:
            activityMessage = "Checking for updates…"
        case .refreshingLink:
            activityMessage = "Getting fresh link…"
        case .awaitingDuplicateResolution:
            activityMessage = "Waiting on your decision — a duplicate was found"
        default:
            activityMessage = nil
        }
    }
    
    /// When the current stream run began — see estimatedTimeRemaining.
    private var _streamRunStart: Date?

    private let logger = Logger(subsystem: "Convoy", category: "DownloadTask")
    
    // fetchFileInfo() removed — replaced by ProbeConnection's streaming GET
    // in startWithStreamingProbe(). The old HEAD-probe-first approach took
    // 25+ seconds for some redirect chains; the streaming probe eliminates
    // that delay by downloading and probing in a single GET.
    
    private func updateDestinationFilenameIfNeeded(contentDisposition: String?, resolvedURL: URL?) async {
        var candidate: (name: String, source: FilenameSource)?

        if let contentDisposition,
           let parsed = FilenameResolver.filename(fromContentDisposition: contentDisposition) {
            candidate = (parsed, .contentDisposition)
        } else if let resolvedURL {
            // URL-path fallback — Chrome percent-decodes here. Previously we
            // passed raw resolvedURL.lastPathComponent through
            // sanitizeFilename, which replaced every `%` with `-`. So a URL
            // like .../Report%2020.pdf ended up saved as `Report-2020.pdf`
            // instead of `Report 2020.pdf`. Decode first, sanitize after.
            let rawLast = resolvedURL.lastPathComponent
            let pathCandidate = rawLast.removingPercentEncoding ?? rawLast
            // Only prefer this over what we already have if it actually
            // looks like a real filename (has an extension) — some redirect
            // targets still won't have one, in which case keep what we had.
            if !pathCandidate.isEmpty, pathCandidate.contains("."), !pathCandidate.hasPrefix("."),
               let safeName = FilenameResolver.sanitize(pathCandidate) {
                candidate = (safeName, .resolvedURL)
            }
        }
        guard let candidate,
              FilenameResolver.shouldReplace(current: filenameSource, with: candidate.source)
        else { return }

        // originalName only needs re-checking when it's actually changing —
        // the one remaining case where nothing was knowable at request time
        // (a redirector-style URL with no filename hint in its own path).
        // For everything else — the overwhelming majority: a real filename
        // already in the URL, or a stream's title, both known instantly —
        // this candidate simply confirms what originalName already is, and
        // there's nothing left to ask about: identity was already settled,
        // once, before this task even existed. See originalName's own doc
        // comment for the whole reason this field exists.
        if candidate.name.caseInsensitiveCompare(originalName) != .orderedSame {
            let outcome = await DownloadManager.shared.resolveLateIdentity(for: self, resolvedName: candidate.name)
            switch outcome {
            case .discard:
                // The person chose not to proceed — DownloadManager has
                // already torn this task down (cancelDownload). Nothing left
                // to update here.
                return
            case .resolved(let url):
                originalName = candidate.name
                destinationURL = url
                filenameSource = candidate.source
                return
            case .noConflict:
                originalName = candidate.name
                // Falls through below to apply the name — no different from
                // the "nothing changed" path once identity is settled.
            }
        }

        let folder = destinationURL.deletingLastPathComponent()
        let candidateURL = folder.appendingPathComponent(candidate.name)
        destinationURL = DownloadManager.shared.deduplicatedDestination(for: candidateURL, excluding: id)
        filenameSource = candidate.source
    }

    /// Called by DownloadManager the instant a genuine filename conflict is
    /// found for this in-flight task, before the conflict sheet even
    /// renders. Only reachable for the one remaining case identity can't be
    /// known at request time — a redirector-style URL with nothing usable
    /// in its own path (see originalName's doc comment) — since every other
    /// download has its identity fully resolved before the task even exists.
    /// This is what makes the sheet's "waiting for you" claim actually true:
    /// the probe (the only network work that can possibly be running this
    /// early — this fires before the segment/single-stream split decision)
    /// is cancelled right here, so no further bytes are fetched while the
    /// person decides. Whatever's already on disk in the temp file stays
    /// there untouched — same scratch data pause()/resume() already relies
    /// on, picked back up via createSegments() once resolved.
    func markAwaitingConflictResolution() {
        guard status == .starting || status == .downloading else { return }
        _activeProbe?.cancel()
        _activeProbe = nil
        status = .awaitingDuplicateResolution
    }

    /// Called by DownloadManager once the person has answered the conflict
    /// sheet, before updateDestinationFilenameIfNeeded (suspended inside
    /// resolveLateIdentity) resumes with the answer. Restores .downloading
    /// as a safe intermediate state before segments/probe restart.
    func markConflictResolved() {
        guard status == .awaitingDuplicateResolution else { return }
        status = .downloading
    }
    
    private static func parseFilename(fromContentDisposition header: String) -> String? {
        // RFC 6266 / RFC 5987: `filename*` carries the real (UTF-8,
        // percent-encoded) name and SHOULD take priority over the bare
        // `filename=` ASCII fallback when both are present. Chrome prefers
        // `filename*` too. The previous implementation iterated parts in
        // declared order and returned the first match — so a server listing
        // `filename="ascii.pdf"; filename*=UTF-8''real%20name.pdf` handed
        // back `ascii.pdf` (the worse form) instead of the UTF-8 one.
        //
        // Two-pass: collect both, prefer the starred form. Three failure
        // modes that used to slip through are also fixed inline (see the
        // helper funcs below): quoted ext-values (`filename*="UTF-8''.."`),
        // and RFC 7230 quoted-pair escapes inside `filename="..."` (`\"`,
        // `\\`).
        let parts = header.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        var bare: String?
        var starred: String?
        for part in parts {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let raw = String(part.dropFirst("filename*=".count))
                if let parsed = Self.parseStarredFilename(raw), !parsed.isEmpty {
                    starred = parsed
                }
            } else if lower.hasPrefix("filename=") {
                let raw = String(part.dropFirst("filename=".count))
                let parsed = Self.parseBareFilename(raw)
                if !parsed.isEmpty {
                    bare = parsed
                }
            }
        }
        return starred ?? bare
    }
    
    /// Parses an RFC 5987/6266 `ext-value` (the right-hand side of
    /// `filename*=`): `<charset>'<lang>'<value-chars>`, where value-chars
    /// are percent-encoded per the declared charset. A literal `'` is
    /// forbidden inside value-chars (must be `%27`), so the SECOND `'` in
    /// the string is always the lang/value separator.
    /// Also tolerates non-RFC quoted wrappers (`filename*="UTF-8''.."`) that
    /// some servers emit.
    private static func parseStarredFilename(_ raw: String) -> String? {
        var value = raw
        // RFC 5987 says ext-value is unquoted. Some servers still quote it,
        // so strip an outer `"…"` if both ends are quotes.
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        let firstApos = value.firstIndex(of: "'")
        if let firstApos,
           let secondApos = value[value.index(after: firstApos)...].firstIndex(of: "'") {
            let encoded = String(value[value.index(after: secondApos)...])
            return encoded.removingPercentEncoding ?? encoded
        }
        // No `<charset>'<lang>'` prefix: malformed ext-value. Be lenient —
        // percent-decode as-is so a bare `filename*=My%20Paper.pdf` still
        // resolves to `My Paper.pdf` instead of `My%20Paper.pdf`.
        return value.removingPercentEncoding ?? value
    }
    
    /// Parses the right-hand side of `filename=`: either an HTTP token (no
    // quotes) or an RFC 7230 quoted-string (surrounded by `"`, with `\"`
    // and `\\` escape sequences). Trailing text after the closing quote is
    // discarded, matching Chrome.
    private static func parseBareFilename(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("\"") {
            value = String(value.dropFirst())
            var unquoted = ""
            var iter = value.makeIterator()
            while let c = iter.next() {
                if c == "\\" {
                    // quoted-pair: keep the literal next char (covers `\"`
                    // and `\\`; other escapes pass through unchanged too).
                    if let n = iter.next() { unquoted.append(n) }
                } else if c == "\"" {
                    // First unescaped quote closes the quoted-string.
                    break
                } else {
                    unquoted.append(c)
                }
            }
            value = unquoted
        }
        return value
    }
    
    private func createSegments() async throws {
        guard totalBytes > 0 else { throw DownloadError.noData }
        
        let segmentSize = totalBytes / Int64(segmentCount)
        
        for i in 0..<segmentCount {
            let start = Int64(i) * segmentSize
            let end = i == segmentCount - 1 ? totalBytes - 1 : start + segmentSize - 1
            
            let segment = DownloadSegment(
                task: self,
                index: i,
                startByte: start,
                endByte: end,
                session: _sharedSegmentSession,
                customHeaders: effectiveHeaders,
                isMultiSegment: segmentCount > 1,
                validators: validators,
                retryDelay: retryDelay
            )
            // Bytes on disk before it joins: a resumed row splits into lanes
            // already filled, not empty ones that fill a moment later.
            await segment.syncWithDisk()
            _segments.append(segment)
        }
    }
    
    private func startSegments(_ segments: [DownloadSegment]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for segment in segments {
                group.addTask {
                    try await segment.download()
                }
            }
            
            do {
                for try await _ in group {}
            } catch {
                // Stop the other parts now; each would otherwise finish its
                // current request before the error is reported.
                group.cancelAll()
                throw error
            }
        }

        // Every part finished; a pause can still have landed since.
        guard status == .downloading else { return }
        
        // Recompute from the segments themselves rather than trusting the
        // running total — this is the source of truth and keeps repeated
        // pause/resume cycles from ever double-counting bytes.
        await recalculateDownloadedBytes()
        
        try await mergeSegments()
        // A pause during the join returns without the file in place.
        guard status == .downloading else { return }
        status = .completed
        _endTime = Date()
        stopSpeedTimer()
    }
    
    /// Joins the finished parts into the destination file (see
    /// `SegmentMerge`). The parts are deleted only after the move.
    private func mergeSegments() async throws {
        let parts = _segments
            .sorted { $0.index < $1.index }
            .map { SegmentMerge.Part(index: $0.index, url: $0.tempFileURL, size: $0.segmentSize) }
        let scratch = DestinationScratchFile.segmentMerge.url(for: id, beside: destinationURL)

        // An interrupted join's leftover would otherwise count as used space.
        try? FileManager.default.removeItem(at: scratch)
        try SegmentMerge.ensureSpace(forWriting: totalBytes, at: destinationURL)

        let cancellation = MergeCancellation()
        _mergeCancellation = cancellation
        isMerging = true
        defer {
            isMerging = false
            _mergeCancellation = nil
        }

        do {
            try await SegmentMerge.join(parts, into: scratch, expectedTotal: totalBytes,
                                        cancellation: cancellation)
        } catch DownloadError.cancelled {
            // pause()/cancel() owns the state; the parts are untouched.
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        // Paused after the last write: don't put the file in place.
        guard status == .downloading else {
            try? FileManager.default.removeItem(at: scratch)
            return
        }

        try claimDestination { try DownloadDestination.move(scratch, to: $0) }

        // Only now are the parts expendable.
        TemporaryStorage.removeSegmentFiles(of: id)
    }

    /// Runs `write` against this task's destination and adopts whatever name
    /// it actually got.
    ///
    /// A download reserves its name when it is added, but it finishes minutes
    /// or hours later, and a file the person saved into that folder in between
    /// has every right to still be there. `DownloadDestination` saves beside
    /// it instead of over it — which means the name can come back different,
    /// and the row has to follow, or "Reveal in Finder" points at a file that
    /// was never written.
    ///
    /// `originalName` deliberately does not move: it is this download's
    /// identity for duplicate detection and must keep naming what was
    /// *requested*, not where it happened to land. See its doc comment.
    private func claimDestination(_ write: (URL) throws -> URL) throws {
        let written = try write(destinationURL)
        if written != destinationURL { destinationURL = written }
    }
    
    /// Runs whichever segments haven't finished yet. Shared by both a fresh
    /// start and a resume (in-session or post-relaunch) so there's exactly
    /// one place that decides "is there really anything left to fetch".
    private func runPendingSegments() async throws {
        var pending: [DownloadSegment] = []
        for segment in _segments {
            // From the file, not the in-memory count: the join reads the
            // file, and the system can purge old temp files.
            await segment.syncWithDisk()
            if await segment.isComplete { continue }
            pending.append(segment)
        }
        await recalculateDownloadedBytes()

        guard !pending.isEmpty else {
            // Every segment already completed — either from earlier this
            // session (pause/resume) or because the app quit after finishing
            // all segments but before the merge ran. Just merge.
            try await mergeSegments()
            guard status == .downloading else { return }
            status = .completed
            _endTime = Date()
            stopSpeedTimer()
            return
        }
        
        try await startSegments(pending)
    }
    
    func pause() async {
        // A conflict sheet is currently suspended waiting on an answer for
        // this task specifically (see markAwaitingConflictResolution) — the
        // person acted directly on the row instead of answering it. Discard
        // that pending conflict (as a "skip" outcome) rather than leaving it
        // suspended forever: without this, DownloadManager's continuation
        // for it never resumes, and the sheet keeps asking about a task the
        // person just told us, a different way, they don't want to proceed.
        if status == .awaitingDuplicateResolution {
            DownloadManager.shared.discardPendingConflict(forResolvingTaskID: id)
            status = .paused
            return
        }

        guard status == .downloading || status == .starting
           || status == .validating || status == .refreshingLink
           || status == .waiting else { return }
        
        // For a .downloading/starting/etc task this actually stops network
        // work in flight. For .waiting (queued behind the concurrency limit,
        // nothing running yet) these are no-ops — no probe was ever started,
        // and any existing segments (e.g. a task that was .paused, hit
        // markWaitingForCapacity() on a blocked resume, and is still sitting
        // at .waiting) are already _isCancelled from the original pause.
        // Cancelling an already-idle segment is harmless either way.
        // Stops the yt-dlp child for a YouTube task. The `.part` file it leaves
        // behind is what `--continue` resumes from, so pausing loses nothing.
        // A no-op for every non-YouTube task.
        if ytFormatSelector != nil {
            await YouTubeDownloader.shared.cancel(taskID: id)
        }

        // Stops in-flight segment downloads for a native stream task.
        // StreamDownloader tracks partial temp files per segment — on resume,
        // completed segments are skipped and in-progress ones restart cleanly.
        if streamURL != nil {
            await StreamDownloader.shared.cancel(taskID: id)
        }


        _activeProbe?.cancel()
        _activeProbe = nil
        _mergeCancellation?.cancel()

        for segment in _segments {
            await segment.cancel()
        }

        // Each new resume session gets a fresh auto-resolve budget —
        // clear the counter (and the zero-byte-chain latch) so an expired
        // YouTube link, or a currently-blocked quality, gets re-judged fresh
        // rather than carrying a stale verdict from before the pause — e.g.
        // useful if the user picks a different quality and resumes.
        _autoResolveCount = 0
        _zeroByteFailureChain = false
        status = .paused
        stopSpeedTimer()
    }
    
    func resume() async throws {
        guard status == .paused else { return }

        // Delegate to start() — it handles both fresh starts (totalBytes == 0)
        // and resumes (totalBytes > 0, recreates segments from persisted data).
        try await start()
    }

    /// Marks a runnable task as blocked when its parent folder is gone.
    /// This is deliberately local-only: it can be called at task creation
    /// time, before any resolver or network activity is attempted.
    @discardableResult
    func markDestinationMissingIfNeeded() -> Bool {
        guard status == .waiting || status == .paused || status == .starting else {
            return false
        }

        let folder = destinationURL.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: folder.path) else {
            return false
        }

        status = .destinationMissing
        return true
    }
    
    /// Called by DownloadManager.resumeDownload when a resume can't start
    /// immediately because every concurrency slot is already in use.
    /// Flips .paused -> .waiting so this behaves exactly like a task that
    /// hit the limit naturally — it auto-starts once a slot frees, via
    /// DownloadManager.startNextQueued()/startAllWaitingWithinCapacity() —
    /// instead of the previous behavior, where a blocked resume just
    /// silently did nothing and stayed .paused with no visible feedback or
    /// path back to running.
    ///
    /// Safe to funnel a task with real prior progress through the same
    /// .waiting path as a brand-new task: start()'s resume branch now
    /// resets segment state itself regardless of entry point (see the
    /// comment there), so this doesn't bypass anything resume() used to do.
    func markWaitingForCapacity() {
        guard status == .paused else { return }
        status = .waiting
    }
    
    /// Called by DownloadManager.matchFreshURL when the browser captures a
    /// new URL that matches this expired task (same filename + same size).
    /// Swaps in the fresh URL, clears the expired status back to .paused,
    /// and lets the caller trigger a normal resumeDownload().
    func relinkURL(_ freshURL: URL, headers: [String: String] = [:]) {
        guard case .urlExpired = status else { return }
        _effectiveURL = freshURL
        // New headers take priority; keep any custom headers the task was
        // created with that the fresh request didn't mention — except Cookie,
        // which comes only from the fresh capture (see withoutCookie).
        _effectiveHeaders = headers.merging(Self.withoutCookie(customHeaders)) { fresh, _ in fresh }
        // Reset the auto-resolve counter so the next resume cycle gets a
        // clean slate (e.g. for YouTube, which may also have expired).
        _autoResolveCount = 0
        status = .paused
    }

    /// Applies headers from a fresh browser capture to a task that is only
    /// paused. Called by DownloadManager.resolveConflict when the user picks
    /// "resume existing" in the duplicate sheet: a task restored at launch
    /// comes back .paused, so the stored headers can be older than the
    /// browser's current session. relinkURL handles the .urlExpired case and
    /// swaps the URL too; here the identity match already established the URL
    /// is the same one, and only the credentials need refreshing.
    func applyFreshHeaders(_ headers: [String: String]) {
        guard !headers.isEmpty else { return }
        // runStreamDownload reads customHeaders directly rather than going
        // through effectiveHeaders, so a stream only picks up new cookies if
        // they land here.
        customHeaders = headers.merging(Self.withoutCookie(customHeaders)) { fresh, _ in fresh }
        // The byte-range path prefers _effectiveHeaders whenever something
        // has filled it (the YouTube resolver, or an earlier relinkURL), and
        // a non-empty one would shadow the merge above. Only reachable via
        // relinkURL in practice — addYouTubeDownload raises its conflicts
        // with no incoming headers at all, so the guard above returns first.
        if !_effectiveHeaders.isEmpty {
            _effectiveHeaders = headers.merging(Self.withoutCookie(_effectiveHeaders)) { fresh, _ in fresh }
        }
    }

    /// A fresh capture's cookies replace the old ones rather than merge: the
    /// capture may come from another window (normal vs incognito), and a
    /// cookie it didn't carry must not survive from the previous one.
    private static func withoutCookie(_ headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    }
    
    /// Called when the user picks a new folder for a task whose original
    /// destination folder went missing (see .destinationMissing, set in
    /// start()). Keeps the same filename, just relocates which folder it's
    /// saved into. The caller still needs to trigger a normal
    /// resumeDownload() afterward — this only clears the blocked state.
    public func relocateDestinationFolder(to folder: URL) {
        guard case .destinationMissing = status else { return }
        let filename = destinationURL.lastPathComponent
        destinationURL = folder.appendingPathComponent(filename)
        status = .paused
    }
    
    /// Called when the user explicitly chooses to have the original folder
    /// recreated exactly where it was, rather than picking a new one (e.g.
    /// it was deleted by accident and they just want it back). This is the
    /// one place recreating that folder is appropriate — because the user
    /// asked for it, not as a silent background default.
    public func recreateOriginalDestinationFolder() {
        guard case .destinationMissing = status else { return }
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            status = .paused
        } catch {
            status = .failed(error)
        }
    }

    /// Clears a .failed status back to .paused so DownloadManager.retryFailed
    /// can resume this exact task — same id, same on-disk segment temp files
    /// — instead of creating a replacement. Retrying used to always build a
    /// brand-new task, which meant a network drop mid-download restarted
    /// from byte 0 every time (the new task's id didn't match the old
    /// segment temp files) and orphaned the partial files on disk. No-op if
    /// not currently failed.
    func clearFailureForRetry() {
        guard case .failed = status else { return }
        error = nil
        status = .paused
    }

    /// Discards whatever partial data this task has on disk and resets it to
    /// a brand-new task's state, for when the user believes the partial
    /// bytes themselves are the problem (corrupted/broken download) rather
    /// than wanting to continue from them. Call before clearFailureForRetry.
    func discardProgressForFreshRestart() {
        cleanupTempFiles()
        _segments = []
        totalBytes = 0
        downloadedBytes = 0
        progressBasis = .bytes
        isMerging = false
        _hasRetriedAsSingleSegment = false
        _validatorsDropped = false
        _rangesUnusable = false
        _autoResolveCount = 0
        _zeroByteFailureChain = false
    }

    func cancel() async {
        // Same reasoning as pause() above — discard any conflict sheet still
        // suspended waiting on this task before tearing it down, so
        // DownloadManager's continuation for it doesn't leak.
        if status == .awaitingDuplicateResolution {
            DownloadManager.shared.discardPendingConflict(forResolvingTaskID: id)
        }

        // Same as pause(): stop the yt-dlp child for a YouTube task. Its
        // scratch files go with everything else in cleanupTempFiles() below.
        if ytFormatSelector != nil {
            await YouTubeDownloader.shared.cancel(taskID: id)
        }

        // Stop in-flight segment downloads for a native stream task.
        // The mdl-stream-<id> temp directory is cleaned up in cleanupTempFiles().
        if streamURL != nil {
            await StreamDownloader.shared.cancel(taskID: id)
        }

        // Cancel the probe if active
        _activeProbe?.cancel()
        _activeProbe = nil
        _mergeCancellation?.cancel()
        
        for segment in _segments {
            await segment.cancel()
        }
        
        status = .cancelled
        error = DownloadError.cancelled
        
        cleanupTempFiles()
    }

    /// Deletes every file this task may have left behind, in both places a
    /// download writes before it finishes: the temp folder (segment files and
    /// `TaskScratchDirectory`) and beside its destination
    /// (`DestinationScratchFile`). Everything is found by task id, never by a
    /// file's name, so nothing the person owns can match, and nothing depends
    /// on which kind of download this was — a kind that never wrote a file is
    /// a no-op. That is the whole rule: delete a download and nothing it made
    /// stays behind.
    ///
    /// Called by cancel(), by DownloadManager.removeTask() for a row deleted
    /// without cancelling (a failed or destination-missing download), and by
    /// discardProgressForFreshRestart().
    func cleanupTempFiles() {
        TemporaryStorage.removeSegmentFiles(of: id)
        for scratch in TaskScratchDirectory.allCases {
            scratch.remove(for: id)
        }
        DestinationScratchFile.removeAll(for: id, in: destinationURL.deletingLastPathComponent())
    }
    
    func segmentDidProgress(_ segment: DownloadSegment, bytes: Int64) async {
        await recalculateDownloadedBytes()
    }
    
    func segmentDidComplete(_ segment: DownloadSegment) async {
        refreshSegmentMap(force: true)
    }
    
    /// The authoritative source of `downloadedBytes` — always the live sum
    /// of each segment's actual on-disk/in-flight progress, never a
    /// standalone accumulator that could drift out of sync (e.g. across
    /// repeated pause/resume cycles).
    private func recalculateDownloadedBytes() async {
        var total: Int64 = 0
        for segment in _segments {
            total += await segment.downloadedBytes
        }
        downloadedBytes = totalBytes > 0 ? min(total, totalBytes) : total
        refreshSegmentMap()
    }

    /// Rebuilds `segmentMap`, at most every `segmentMapInterval` unless
    /// forced. A skipped rebuild runs when the interval ends, so the last
    /// change before a quiet spell still shows.
    private func refreshSegmentMap(force: Bool = false) {
        let wait = Self.segmentMapInterval - Date().timeIntervalSince(_segmentMapRefreshedAt)
        guard force || wait <= 0 else {
            guard !_segmentMapRefreshScheduled else { return }
            _segmentMapRefreshScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?._segmentMapRefreshScheduled = false
                self?.refreshSegmentMap(force: true)
            }
            return
        }
        _segmentMapRefreshedAt = Date()
        let map = currentSegmentMap()
        if map != segmentMap { segmentMap = map }
    }

    private func currentSegmentMap() -> SegmentMap? {
        if streamURL != nil { return .pieces(_streamPieces) }
        return .lanes(_segments.map { ($0.startByte...$0.endByte, $0.bytesOnDisk) }, totalBytes: totalBytes)
    }
    
    private func startSpeedTimer() {
        _lastBytes = downloadedBytes
        _lastTime = Date()
        _speedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateSpeed()
            }
        }
    }
    
    private func stopSpeedTimer() {
        _speedTimer?.invalidate()
        _speedTimer = nil
    }
    
    private func updateSpeed() {
        let now = Date()
        let elapsed = now.timeIntervalSince(_lastTime)
        guard elapsed > 0 else { return }
        
        let bytesDiff = downloadedBytes - _lastBytes
        speed = Int64(Double(bytesDiff) / elapsed)
        
        _lastBytes = downloadedBytes
        _lastTime = now
    }
    
    public func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }
    
    public func openFile() {
        NSWorkspace.shared.open(destinationURL)
    }
    
    public func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    
    public func copyFilePath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(destinationURL.path, forType: .string)
    }
}

public enum DownloadPriority: Int, Sendable, Comparable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2
    
    public static func < (lhs: DownloadPriority, rhs: DownloadPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DownloadStatus: Sendable, Equatable {
    case waiting
    case starting
    /// Running a HEAD request to verify the remote file hasn't changed.
    case validating
    /// Re-running the external resolver (e.g. yt-dlp) to get a fresh stream URL.
    case refreshingLink
    case downloading
    case paused
    case completed
    case failed(Error?)
    case cancelled
    /// The download URL returned 403/410 mid-download (link expired).
    /// Temp files are preserved on disk. The Re-link flow lets the user
    /// open the referrer page to get a fresh URL and resume.
    case urlExpired(referrerURL: URL?)
    /// The folder this download was originally saving into no longer
    /// exists on disk (see the check in start()'s resume path) — most
    /// commonly because the download location was changed in Settings and
    /// the old folder was then moved or deleted. Segment temp files are
    /// untouched; the user just needs to pick a new folder or ask to
    /// recreate the original one (see DownloadTask.relocateDestinationFolder
    /// / recreateOriginalDestinationFolder).
    case destinationMissing
    /// A genuine filename collision was found for this in-flight download
    /// and it's now actually stopped — not just showing a dialog while
    /// quietly finishing underneath it. Only reachable for a redirector-style
    /// URL whose real name wasn't knowable until Content-Disposition arrived
    /// mid-flight (see DownloadTask.originalName's doc comment); every other
    /// download resolves this at request time, before a task even exists.
    /// Resolved the instant the person answers the conflict sheet — see
    /// DownloadManager's conflictWaiters and DownloadTask.markConflictResolved.
    case awaitingDuplicateResolution
    
    public var sortOrder: Int {
        switch self {
        case .awaitingDuplicateResolution: return 0
        case .downloading: return 0
        case .starting, .validating, .refreshingLink: return 1
        case .paused: return 2
        case .waiting: return 3
        case .urlExpired, .destinationMissing: return 4
        case .failed: return 5
        case .completed: return 6
        case .cancelled: return 7
        }
    }
    
    public static func == (lhs: DownloadStatus, rhs: DownloadStatus) -> Bool {
        switch (lhs, rhs) {
        case (.waiting, .waiting), (.starting, .starting),
             (.validating, .validating), (.refreshingLink, .refreshingLink),
             (.downloading, .downloading), (.paused, .paused),
             (.completed, .completed), (.cancelled, .cancelled),
             (.destinationMissing, .destinationMissing),
             (.awaitingDuplicateResolution, .awaitingDuplicateResolution):
            return true
        case (.failed(let lhsErr), .failed(let rhsErr)):
            return lhsErr?.localizedDescription == rhsErr?.localizedDescription
        case (.urlExpired(let lhsURL), .urlExpired(let rhsURL)):
            return lhsURL == rhsURL
        default:
            return false
        }
    }
}
