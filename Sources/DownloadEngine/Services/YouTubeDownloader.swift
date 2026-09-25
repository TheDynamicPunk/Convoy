import Foundation
import os

/// Downloads a chosen YouTube format by driving yt-dlp, rather than resolving a
/// URL and fetching it with this app's own byte-range engine.
///
/// Why yt-dlp does the downloading (verified against live YouTube, Aug 2026):
///
/// - The `web`/`web_safari` clients now return **no media formats at all** for
///   many videos — only storyboard images. SABR is fully enforced there.
/// - The clients that still hand back direct URLs (commonly `android_vr`)
///   produce URLs authorized for roughly the first 20% of the stream when no
///   matching PO-Token can be generated. A byte-range download gets a few
///   hundred KB and then 403s for good, no matter how the request is shaped.
///   (See DownloadError.youtubeQualityCurrentlyBlocked and yt-dlp#17348.)
/// - The formats that *do* still work are frequently **fragmented** (HLS/DASH,
///   tens to hundreds of separate fragment URLs). A single-URL ranged downloader
///   cannot fetch those at all.
///
/// yt-dlp already solves every one of those — client fallback, PO-Token
/// providers and fragment assembly — and is maintained against
/// YouTube's changes continuously. Reimplementing that here would mean tracking
/// it forever. So for YouTube the app's role is to drive yt-dlp and surface
/// progress in the UI, not to move the bytes itself.
public actor YouTubeDownloader {
    public static let shared = YouTubeDownloader()

    private let logger = Logger(subsystem: "Convoy", category: "YouTubeDownloader")

    /// A single progress sample parsed out of yt-dlp's stdout.
    public struct Progress: Sendable {
        public let downloadedBytes: Int64
        public let totalBytes: Int64
        public let bytesPerSecond: Int64
    }

    private var binDir: URL { HelperLocations.binDirectory }
    private var ytdlpPath: String { HelperLocations.ytdlp }
    private var potPath: String { binDir.appendingPathComponent("bgutil-pot").path }

    /// Running processes keyed by task id, so pause/cancel can terminate them.
    private var running: [UUID: Process] = [:]

    /// Downloads `formatSelector` from `pageURL` to `destination`, reporting
    /// progress as it goes. Returns when yt-dlp exits successfully.
    ///
    /// - Parameters:
    ///   - taskID: used to track the process so `cancel(taskID:)` can stop it.
    ///   - formatSelector: a yt-dlp `-f` expression. For a video-only itag this
    ///     should be `"<itag>+bestaudio/<itag>"` so yt-dlp fetches an audio
    ///     track and muxes it in — that's what makes the finished file playable
    ///     with sound, and it replaces this app's own MediaMuxer step for the
    ///     YouTube path.
    ///   - cookiesFromBrowser: opt-in browser name for `--cookies-from-browser`.
    public func download(
        taskID: UUID,
        pageURL: URL,
        formatSelector: String,
        destination: URL,
        cookiesFromBrowser: String?,
        expectedTotalBytes: Int64 = 0,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: ytdlpPath) else {
            throw YouTubeResolverError.helpersNotInstalled
        }

        // A comma selector means "fetch these formats as separate files" —
        // two downloads, then a merge this app performs itself. See
        // `downloadSeparately` for why that is better than handing the merge
        // to yt-dlp.
        if formatSelector.contains(",") {
            return try await downloadSeparately(
                taskID: taskID, pageURL: pageURL, formatSelector: formatSelector,
                destination: destination, cookiesFromBrowser: cookiesFromBrowser,
                expectedTotalBytes: expectedTotalBytes, onProgress: onProgress
            )
        }

        var args = commonArguments(formatSelector: formatSelector, cookiesFromBrowser: cookiesFromBrowser)
        // No --merge-output-format: this path downloads exactly one format
        // and never merges. Anything needing a merge went to
        // downloadSeparately above, which merges here rather than in yt-dlp.
        //
        // yt-dlp writes to a scratch name beside the destination rather than
        // to the destination itself, so that taking the final name is this
        // app's own atomic move (see DownloadDestination) instead of yt-dlp
        // landing on top of whatever is already there. The scratch path is
        // stable for this task, which is what keeps `--continue` resuming from
        // its `.part` across a pause.
        let scratch = DestinationScratchFile.youTube.url(for: taskID, beside: destination)
        args += ["-o", scratch.path]
        args.append(pageURL.absoluteString)

        // The PO-Token provider has to be up before yt-dlp asks for a token.
        await YouTubeResolver.shared.ensurePotProviderRunningIfNeeded()

        logger.notice("yt-dlp download start task=\(taskID, privacy: .public) format=\(formatSelector, privacy: .public) dest=\(destination.lastPathComponent)")

        try await runYtDlp(taskID: taskID, args: args) { line in
            if let p = Self.parseProgress(line) { onProgress(p) }
        }

        do {
            return try DownloadDestination.move(scratch, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// Runs yt-dlp to completion, feeding each stdout line to `onLine`.
    ///
    /// Shared by the single-file and two-file paths so the process plumbing —
    /// both pipes drained concurrently (leaving either unread deadlocks the
    /// child once its buffer fills), bounded stderr capture, and a signal exit
    /// read as cancellation rather than failure — exists once.
    private func runYtDlp(
        taskID: UUID,
        args: [String],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in collector.appendStdout(chunk) { onLine(line) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.appendStderr(chunk)
        }

        running[taskID] = process

        defer {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            running[taskID] = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume(returning: ()) }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        let status = process.terminationStatus
        guard status != 0 else { return }

        let stderr = collector.stderrText()
        // A terminate() from cancel()/pause() surfaces here as a signal
        // exit; that's a user action, not a failure to report.
        if wasTerminatedBySignal(process) {
            logger.notice("yt-dlp download stopped by user for task \(taskID, privacy: .public)")
            throw DownloadError.cancelled
        }
        logger.error("yt-dlp exited \(status, privacy: .public): \(stderr)")
        throw Self.mapFailure(exitCode: status, stderr: stderr)
    }

    // MARK: - Two-file download + local merge

    /// Fetches a video-only and an audio-only format as two separate files,
    /// then merges them with `MediaMuxer`.
    ///
    /// The alternative — `-f "137+140"`, which is what this used to do — makes
    /// yt-dlp merge, and yt-dlp merges with ffmpeg. That single fact was what
    /// kept ffmpeg a required 27 MB download for every user, since essentially
    /// every YouTube pick above 360p is video-only. Merging here instead means
    /// the common path needs nothing installed at all: `MediaMuxer` does it
    /// through AVFoundation.
    ///
    /// Two details make that work rather than merely compile:
    ///
    /// - **The output template must carry `%(format_id)s`.** Given a fixed
    ///   `-o` path for a comma selector, yt-dlp writes one file and the second
    ///   format silently lands on top of the first — verified, and it fails
    ///   quietly, leaving a video-only file that looks complete.
    /// - **The audio format is named, not `bestaudio`.** See `MergeAudio`:
    ///   `bestaudio` picks Opus-in-WebM, which AVFoundation cannot read, which
    ///   would put ffmpeg straight back on the required list.
    private func downloadSeparately(
        taskID: UUID,
        pageURL: URL,
        formatSelector: String,
        destination: URL,
        cookiesFromBrowser: String?,
        expectedTotalBytes: Int64,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        // Keyed by task so a pause leaves the partial files exactly where a
        // resume will look for them, and `--continue` picks up both.
        let workDir = TaskScratchDirectory.youTubeMerge.url(for: taskID)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var args = commonArguments(formatSelector: formatSelector, cookiesFromBrowser: cookiesFromBrowser)
        args += ["-o", workDir.appendingPathComponent("%(format_id)s.%(ext)s").path]
        args.append(pageURL.absoluteString)

        // The PO-Token provider has to be up before yt-dlp asks for a token.
        await YouTubeResolver.shared.ensurePotProviderRunningIfNeeded()

        logger.notice("yt-dlp two-file download start task=\(taskID, privacy: .public) format=\(formatSelector, privacy: .public) dest=\(destination.lastPathComponent)")

        // yt-dlp reports bytes per *file*, restarting at zero for the second.
        // This folds them into one running count, and reports the combined
        // total from the first line when the caller knows it — which is what
        // keeps the row's total from growing partway through and dragging the
        // percentage backwards.
        let tally = TwoFileProgress(expectedTotal: expectedTotalBytes)
        try await runYtDlp(taskID: taskID, args: args) { line in
            guard let p = Self.parseProgress(line) else { return }
            onProgress(tally.fold(p))
        }

        let (videoURL, audioURL) = try locateDownloadedPair(in: workDir, formatSelector: formatSelector)

        logger.notice("Merging task=\(taskID, privacy: .public) \(videoURL.lastPathComponent, privacy: .public) + \(audioURL.lastPathComponent, privacy: .public)")
        // MediaMuxer claims the destination itself and reports what it got,
        // which may carry a " (n)" if something arrived at that path while
        // this download was running.
        let written = try await MediaMuxer.shared.mux(
            taskID: taskID,
            videoURL: videoURL,
            audioURL: audioURL,
            outputURL: destination
        )

        // Only on success. A failed or cancelled run leaves the directory
        // behind for `--continue` to resume from, which is the point: it is
        // the download's progress, and it lives exactly as long as the row
        // does. `DownloadTask.cleanupTempFiles()` discards it when the row
        // goes away, and Settings → Storage clears the ones a crash stranded.
        // Nothing expires it on a timer.
        try? FileManager.default.removeItem(at: workDir)
        return written
    }

    /// Picks the video and audio file out of the work directory, by name.
    ///
    /// The output template is `%(format_id)s.%(ext)s`, so each file's stem is
    /// its format id. The video half of the selector is always a plain id; the
    /// audio half may be a language selector, whose file carries whichever id
    /// yt-dlp matched — `YouTubeResolver.fileStem(_:satisfies:)` decides.
    /// Newest wins if a renumbered run left an older match beside it.
    ///
    /// An earlier version guessed instead — audio-ish extension, else the
    /// smaller of the two files — on the assumption that audio is always
    /// smaller. It isn't: pick 144p on a long video and the video track is
    /// the smaller file, at which point the guess swapped them and handed the
    /// muxer an m4a as its "video". That surfaced as
    /// `Stream map '' matches no streams`, which reads like a muxer problem
    /// and isn't.
    private func locateDownloadedPair(
        in workDir: URL,
        formatSelector: String
    ) throws -> (video: URL, audio: URL) {
        let ids = formatSelector.split(separator: ",").map(String.init)
        guard ids.count == 2 else {
            throw YouTubeResolverError.processFailed("expected a two-format selector, got \(formatSelector)")
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: workDir, includingPropertiesForKeys: nil
        )) ?? []
        // A leftover .part means the run exited 0 without finishing a file.
        // Merging a truncated track would produce a plausible-looking broken
        // file, so refuse instead.
        let complete = files.filter { $0.pathExtension.lowercased() != "part" }

        func file(for selector: String, missing: String) throws -> URL {
            let matches = complete.filter {
                YouTubeResolver.fileStem($0.deletingPathExtension().lastPathComponent, satisfies: selector)
            }
            let newest = matches.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (da ?? .distantPast) < (db ?? .distantPast)
            }
            guard let newest else { throw YouTubeResolverError.processFailed(missing) }
            return newest
        }
        return (
            video: try file(for: ids[0], missing: "yt-dlp produced no finished file for format \(ids[0])"),
            // yt-dlp skips a language selector that matches nothing and
            // still exits 0, so this is where a withdrawn dub surfaces.
            audio: try file(for: ids[1], missing: "The chosen audio language is no longer offered for this video.")
        )
    }

    /// The flags every yt-dlp invocation here shares.
    ///
    /// Pulled out when the two-file path arrived rather than copied into it:
    /// the PO-Token args, plugin dir and JS runtime all have to match what
    /// `YouTubeResolver` used to list the formats, and a second copy that
    /// drifts from this one is how a format resolves and then fails to
    /// download.
    private func commonArguments(formatSelector: String, cookiesFromBrowser: String?) -> [String] {
        var args: [String] = [
            "--newline",
            "--no-warnings",
            "--no-playlist",
            // Machine-readable progress instead of parsing yt-dlp's
            // human-formatted bar (which is localised, padded, and carries \r
            // updates). Fields are emitted raw so they need no unit parsing.
            "--progress-template", "download:MDLPROGRESS %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s",
            "-f", formatSelector,
            // Resume a partial .part file rather than restarting, so pause and
            // resume behave the way they do for ordinary downloads.
            "--continue",
        ]
        args += HelperLocations.pluginArguments()
        // Same runtime the resolver used. This used to look only for our own
        // bundled copy, so someone relying on a system Node got a runtime
        // while listing formats and none while downloading them.
        args += HelperLocations.jsRuntimeArguments()
        // Same client listFormats used, or the picker can offer a format
        // this call cannot see.
        args += HelperLocations.youtubePlayerClientArguments()
        if FileManager.default.fileExists(atPath: potPath) {
            args += ["--extractor-args", "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416"]
        }
        if let cookiesFromBrowser, !cookiesFromBrowser.isEmpty {
            args += ["--cookies-from-browser", cookiesFromBrowser]
        }
        return args
    }

    /// Stops the yt-dlp process for `taskID`, if one is running. The `.part`
    /// file it leaves behind is what `--continue` picks up on resume.
    public func cancel(taskID: UUID) {
        guard let process = running[taskID], process.isRunning else { return }
        process.terminate()
    }

    public func isRunning(taskID: UUID) -> Bool {
        running[taskID]?.isRunning ?? false
    }

    private func wasTerminatedBySignal(_ process: Process) -> Bool {
        process.terminationReason == .uncaughtSignal
    }

    /// Parses a `--progress-template` line. Fields may be "NA" when yt-dlp
    /// doesn't know a value yet (notably total size early in a fragmented
    /// download), so each is parsed independently and missing ones become 0.
    static func parseProgress(_ line: String) -> Progress? {
        guard line.hasPrefix("MDLPROGRESS ") else { return nil }
        let parts = line.dropFirst("MDLPROGRESS ".count).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        func num(_ s: Substring) -> Int64 {
            if let i = Int64(s) { return i }
            // yt-dlp emits floats for speed and sometimes for byte counts.
            if let d = Double(s), d.isFinite, d >= 0 { return Int64(d) }
            return 0
        }
        let downloaded = num(parts[0])
        // Prefer the exact total; fall back to the estimate that fragmented
        // downloads report instead.
        let total = num(parts[1]) > 0 ? num(parts[1]) : num(parts[2])
        return Progress(downloadedBytes: downloaded, totalBytes: total, bytesPerSecond: num(parts[3]))
    }

    /// Turns a yt-dlp failure into the closest DownloadError, so the UI can say
    /// something specific instead of surfacing a raw exit code.
    static func mapFailure(exitCode: Int32, stderr: String) -> Error {
        let lower = stderr.lowercased()
        // Checked before the 403 rule below: a bot check often arrives *as* a
        // 403, and "YouTube wants proof you're human" is a far more useful
        // thing to tell someone than "this quality is blocked".
        if YouTubeResolver.looksLikeBotCheck(stderr) {
            return YouTubeResolverError.botCheckBlocked
        }
        if lower.contains("403") || lower.contains("forbidden") {
            return DownloadError.youtubeQualityCurrentlyBlocked
        }
        if lower.contains("requested format is not available") {
            return YouTubeResolverError.noPlayableFormat
        }
        let detail = stderr.split(separator: "\n").last.map(String.init) ?? "exit code \(exitCode)"
        return YouTubeResolverError.processFailed(detail)
    }
}

/// Buffers yt-dlp's two output streams. A plain class behind a lock because the
/// readability handlers fire on arbitrary queues, outside the actor.
/// Folds yt-dlp's per-file progress into one continuous transfer.
///
/// yt-dlp reports `downloaded_bytes` per file and restarts at zero for the
/// second, so reporting it raw makes the row jump back to the start when the
/// audio begins. This keeps a running base: a byte count lower than the last
/// one means a new file started, so whatever the previous file finished at is
/// banked first.
///
/// `expectedTotal` is the combined size, known in advance because the audio
/// format was chosen by id rather than left to `bestaudio` (see `MergeAudio`).
/// Reporting it from the very first line is the point: the alternative is
/// summing totals as files appear, which makes the denominator grow partway
/// through and drags the percentage backwards — the same complaint that kept
/// mux progress out of the byte counters in `StreamDownloader`. When it is
/// not known (0, e.g. a task restored from disk before this existed), it
/// falls back to the running sum and the old behaviour.
///
/// A plain locked class rather than actor state: yt-dlp's readability
/// handlers fire on arbitrary queues, outside any actor's isolation.
private final class TwoFileProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedTotal: Int64
    private var banked: Int64 = 0
    private var lastDownloaded: Int64 = 0
    private var lastTotal: Int64 = 0

    init(expectedTotal: Int64) {
        self.expectedTotal = expectedTotal
    }

    func fold(_ p: YouTubeDownloader.Progress) -> YouTubeDownloader.Progress {
        lock.lock(); defer { lock.unlock() }

        if p.downloadedBytes < lastDownloaded {
            banked += lastTotal
        }
        lastDownloaded = p.downloadedBytes
        if p.totalBytes > 0 { lastTotal = p.totalBytes }

        let downloaded = banked + p.downloadedBytes
        let total = expectedTotal > 0 ? max(expectedTotal, downloaded) : banked + p.totalBytes
        return YouTubeDownloader.Progress(
            downloadedBytes: downloaded,
            totalBytes: total,
            bytesPerSecond: p.bytesPerSecond
        )
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutRemainder = ""
    private var stderrBuffer = ""

    /// Appends stdout bytes and returns whatever complete lines that produced.
    func appendStdout(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock(); defer { lock.unlock() }
        stdoutRemainder += text
        // yt-dlp with --newline still uses \r within some progress output, so
        // split on both and keep only the trailing partial line.
        var lines = stdoutRemainder.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
        if let last = stdoutRemainder.last, last != "\n" && last != "\r", !lines.isEmpty {
            stdoutRemainder = lines.removeLast()
        } else {
            stdoutRemainder = ""
        }
        return lines
    }

    func appendStderr(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        // Bounded so a pathological run can't grow this without limit.
        stderrBuffer += text
        if stderrBuffer.count > 8192 {
            stderrBuffer = String(stderrBuffer.suffix(8192))
        }
    }

    func stderrText() -> String {
        lock.lock(); defer { lock.unlock() }
        return stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
