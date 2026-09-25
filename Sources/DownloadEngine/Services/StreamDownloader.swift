import Foundation
import OSLog
import CommonCrypto

// MARK: - StreamDownloader

/// Orchestrates a native HLS or DASH stream download end-to-end:
///
/// 1. Fetches the manifest (variant `.m3u8` or `.mpd`)
/// 2. Parses it into a segment list (using `HLSParser` or `DASHSegmentResolver`)
/// 3. Downloads segments in a sliding window of `segmentConcurrency` parallel
///    connections — same setting as the byte-range engine's `segmentCount`.
/// 4. For HLS AES-128 encrypted streams: fetches the key and decrypts each
///    segment after download using CommonCrypto (AES-128-CBC).
/// 5. Assembles each track by concatenating its segments in order.
///    - fMP4/CMAF (init segment present): init.mp4 + media segments → `.mp4`
///    - MPEG-TS: media segments in order → `.ts`
///
/// Fetching, decryption, and assembly are entirely native — no external
/// yt-dlp involved in getting the bytes. The one exception: when a stream
/// splits video and audio into separate tracks (common HLS/DASH delivery,
/// confirmed on real sites, not a hypothetical), each track assembles on its
/// own as above and `MediaMuxer` then combines the two finished files into
/// one through AVFoundation, locally and without re-encoding. See
/// `MediaMuxer`'s own doc comment for why reimplementing a container muxer
/// from scratch wasn't the better trade.
public actor StreamDownloader {
    public static let shared = StreamDownloader()

    private let logger = Logger(subsystem: "Convoy", category: "StreamDownloader")

    /// Running operations keyed by task ID so `cancel()` can stop them.
    private var cancellations: [UUID: () -> Void] = [:]

    // MARK: - Public progress type

    public struct Progress: Sendable {
        /// Which half of the job is running. The merge moves no bytes and
        /// completes no segments, so a row driven off either counter would sit
        /// still through it.
        public enum Phase: Sendable { case downloading, merging }

        public let phase: Phase
        public let completedSegments: Int
        public let totalSegments: Int
        /// Finished pieces plus what has arrived for those in flight. Never
        /// lower than the last report; speed is worked out from it by the task.
        public let downloadedBytes: Int64
        /// Each track's pieces, for the row's segment bar.
        public let pieces: [[SegmentMap.PieceState]]
    }

    // MARK: - Entry point

    /// Downloads an HLS or DASH stream to `destination`.
    ///
    /// - Returns: The actual URL the file was written to. It may differ from
    ///   `destination` in extension (`.ts` for MPEG-TS, `.mp4` otherwise) and in
    ///   name, if changing the extension collided with a file already there.
    /// - streamType: `"hls"` or `"dash"`
    /// - headers: cookies, Referer, User-Agent etc. from the browser extension
    /// - segmentConcurrency: parallel segment connections (from user's segmentCount setting)
    /// - representationId / bandwidth: DASH representation selection hints
    /// - preferredAudioLanguage: BCP-47 preference used when DASH exposes
    ///   multiple audio AdaptationSets
    @discardableResult
    public func download(
        taskID: UUID,
        manifestURL: URL,
        streamType: String,
        destination: URL,
        headers: [String: String],
        segmentConcurrency: Int,
        representationId: String? = nil,
        bandwidth: Int? = nil,
        preferredAudioLanguage: String? = nil,
        hlsAudioTracks: [HLSAudioCandidate]? = nil,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {

        // ── 1. Fetch manifest ──────────────────────────────────────────────────────
        logger.notice("Stream download start task=\(taskID, privacy: .public) type=\(streamType, privacy: .public) manifest=\(manifestURL.absoluteString)")
        var manifestText = try await fetchText(url: manifestURL, headers: headers)
        var playlistURL = manifestURL
        var audioTracks = hlsAudioTracks

        // The extension normally resolves an HLS master to one variant, but
        // hands over the master itself when it couldn't read it. Pick the
        // variant here: the one nearest the requested bandwidth, else the best.
        if streamType == "hls",
           let variants = HLSParser.parseMaster(text: manifestText, baseURL: manifestURL),
           let chosen = bandwidth.map({ target in variants.min { abs($0.bandwidth - target) < abs($1.bandwidth - target) }! })
                ?? variants.max(by: { $0.bandwidth < $1.bandwidth }) {
            logger.notice("HLS master: picked variant bandwidth=\(chosen.bandwidth, privacy: .public) of \(variants.count, privacy: .public)")
            playlistURL = chosen.url
            manifestText = try await fetchText(url: chosen.url, headers: headers)
            if audioTracks?.isEmpty ?? true, !chosen.audio.isEmpty { audioTracks = chosen.audio }
        }

        // ── 2. Parse into one or two track plans ───────────────────────────────────
        let plan = try await parseManifest(
            streamType: streamType, text: manifestText,
            baseURL: playlistURL, representationId: representationId, bandwidth: bandwidth,
            preferredAudioLanguage: preferredAudioLanguage, hlsAudioTracks: audioTracks,
            headers: headers
        )
        let tracks = [plan.primary] + (plan.audio.map { [$0] } ?? [])
        let totalSegments = tracks.reduce(0) { $0 + $1.segments.count }
        logger.notice("""
            Parsed \(totalSegments, privacy: .public) segments across \(tracks.count, privacy: .public) track(s), \
            isFMP4=\(plan.primary.isFMP4, privacy: .public), encrypted=\(plan.primary.encryption != nil, privacy: .public)
            """)

        // ── 3. No merge gate ───────────────────────────────────────────────────────
        // There used to be one here: a split-track stream is two individually
        // useless files until merged, so the download suspended on an
        // "install a media helper?" prompt before moving a byte, rather than finding
        // out at the end that it could not finish.
        //
        // `MediaMuxer` now merges through AVFoundation, which needs nothing
        // installed and handles both containers this downloader produces —
        // fMP4 (`.mp4`) and MPEG-TS (`.ts`), both verified. There is nothing
        // left to install, so there is nothing left to ask.
        //
        // The one container AVFoundation cannot read is WebM/Matroska. If a
        // site is found serving that through this path, the fix is to drop
        // those representations in `DASHSegmentResolver` so it fails here,
        // early and clearly, rather than after a full transfer.

        // ── 4. Create temp directory ───────────────────────────────────────────────
        let tempDir = TaskScratchDirectory.streamSegments.url(for: taskID)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Removed on success only — not unconditionally.
        //
        // Assembly and muxing are the *last* steps of a download that may have
        // taken an hour. Deleting every segment the moment one of them fails throws
        // away the entire transfer and every clue about why it failed, and
        // guarantees a retry starts from segment zero. What bounds the disk cost
        // is ownership, not age: `DownloadTask.cleanupTempFiles()` takes this
        // directory when its row is deleted, and Settings → Storage clears the
        // ones a crash stranded (see TemporaryStorage).
        var succeeded = false
        defer {
            if succeeded {
                try? FileManager.default.removeItem(at: tempDir)
            } else {
                logger.notice("Keeping \(tempDir.lastPathComponent, privacy: .public) for resume")
            }
        }

        // Build a shared URLSession with connection pooling matching the concurrency.
        let segmentDelegate = StreamSegmentSessionDelegate()
        let session = buildSession(concurrency: max(segmentConcurrency, 1), delegate: segmentDelegate)

        // ── 5. Set up cancellation ─────────────────────────────────────────────────
        var cancelled = false
        cancellations[taskID] = {
            cancelled = true
            // Close first: a segment starting its request after invalidation
            // would crash (see StreamSegmentSessionDelegate).
            segmentDelegate.close()
            session.invalidateAndCancel()
            // Covers the muxing phase, where there is no session left to cancel.
            // A no-op when no merge is running for this task.
            Task { await MediaMuxer.shared.cancel(taskID: taskID) }
        }
        defer { cancellations.removeValue(forKey: taskID) }

        // ── 6. Progress accounting across all tracks ───────────────────────────────
        // Bytes are a running count, never a fraction of a total: a stream's
        // size is unknowable until the last segment lands, and an estimate
        // refined per segment is a denominator that visibly grows. Completion
        // is counted in segments, which the manifest fixes up front.
        var completedSegments = 0
        /// Bytes of finished pieces.
        var downloadedBytes: Int64 = 0
        /// What was last reported. Held, not lowered, when a retried piece
        /// starts over or a finished one leaves the delegate before it is
        /// counted as done.
        var reportedBytes: Int64 = 0
        var pieces: [[SegmentMap.PieceState]] = tracks.map {
            Array(repeating: .pending, count: $0.segments.count)
        }

        func report(phase: Progress.Phase = .downloading) {
            reportedBytes = max(reportedBytes, downloadedBytes + segmentDelegate.inFlightBytes)
            onProgress(Progress(
                phase: phase,
                completedSegments: completedSegments,
                totalSegments: totalSegments,
                downloadedBytes: reportedBytes,
                pieces: pieces
            ))
        }

        // Pieces an earlier run finished, for every track before any
        // downloads: a resumed row then shows where it stands in one step,
        // audio track included. A `.complete` sidecar is written only after
        // the bytes are durable and any AES decryption succeeded. Plain `.tmp`
        // files deliberately do not qualify: they may be partial files left
        // by cancellation/crash.
        var pendingByTrack: [[Int]] = []
        for (trackIndex, track) in tracks.enumerated() {
            let trackDir = tempDir.appendingPathComponent(track.label, isDirectory: true)
            var pending: [Int] = []
            for (idx, segInfo) in track.segments.enumerated() {
                let segment = StreamSegment(
                    index: idx, url: segInfo.url, tempDir: trackDir, headers: headers, byteRange: segInfo.byteRange
                )
                if await segment.isComplete {
                    pieces[trackIndex][idx] = .done
                    completedSegments += 1
                    downloadedBytes += (try? FileManager.default.attributesOfItem(
                        atPath: segment.tempFileURL.path
                    )[.size] as? Int64) ?? 0
                } else {
                    pending.append(idx)
                }
            }
            pendingByTrack.append(pending)
        }
        report()

        // ── 7. Download and assemble each track ────────────────────────────────────
        var assembled: [URL] = []
        for (trackIndex, track) in tracks.enumerated() {
            let trackDir = tempDir.appendingPathComponent(track.label, isDirectory: true)
            try FileManager.default.createDirectory(at: trackDir, withIntermediateDirectories: true)

            // A single track joins into a hidden file beside its destination
            // and is renamed into place once whole, so a failed join never
            // leaves a truncated file at the real name. Two tracks join in
            // the temp folder and meet in the muxer.
            let isFinalDestination = tracks.count == 1
            let requested = isFinalDestination
                ? destination.deletingPathExtension()
                    .appendingPathExtension(track.isFMP4 ? "mp4" : "ts")
                : trackDir.appendingPathComponent("\(track.label).mp4")
            let assembleTarget = isFinalDestination
                ? DestinationScratchFile.streamAssembly.url(for: taskID, beside: requested)
                : requested

            let written = try await downloadTrack(
                track,
                into: trackDir,
                assembleTo: assembleTarget,
                pending: pendingByTrack[trackIndex],
                session: session,
                headers: headers,
                concurrency: max(1, segmentConcurrency),
                isCancelled: { cancelled },
                onSegmentStart: { index in
                    pieces[trackIndex][index] = .active
                },
                onSegmentComplete: { index, bytes in
                    pieces[trackIndex][index] = .done
                    completedSegments += 1
                    downloadedBytes += bytes
                    report()
                },
                onTick: { report() }
            )
            // Claimed now, not when picked: move saves beside anything that
            // appeared at that path meanwhile.
            if isFinalDestination {
                // The segments are deleted once this download succeeds.
                FileDurability.flush(written)
                assembled.append(try DownloadDestination.move(written, to: requested))
            } else {
                assembled.append(written)
            }
        }

        if cancelled { throw DownloadError.cancelled }

        // ── 8. Merge, or take the single track as-is ────────────────────────────────
        let finalDestination: URL
        if assembled.count == 2 {
            // Deliberately not claimed with DownloadDestination.createFile:
            // the muxer's own move claims a free name, so a placeholder here
            // makes it save beside our empty file — two files from one
            // download. The name it returns is the only true one.
            let requestedOutput = destination.deletingPathExtension().appendingPathExtension("mp4")
            report(phase: .merging)
            logger.notice("Merging video + audio task=\(taskID, privacy: .public) → \(requestedOutput.lastPathComponent)")

            // Mux progress is logged, not folded into the byte counters: it's a
            // fraction of *time*, and deriving bytes from it would make the row's
            // numbers jump around at the very end. The `.merging` phase reported
            // above is what the row shows for these seconds instead. Logged per
            // decile rather than per callback.
            let loggedDecile = MuxProgressLog()
            finalDestination = try await MediaMuxer.shared.mux(
                taskID: taskID,
                videoURL: assembled[0],
                audioURL: assembled[1],
                outputURL: requestedOutput,
                durationSec: plan.primary.durationSec
            ) { fraction in
                loggedDecile.note(fraction)
            }
        } else {
            finalDestination = assembled[0]
        }

        // ── 9. Final progress report from the real file size ───────────────────────
        let finalSize = (try? FileManager.default.attributesOfItem(
            atPath: finalDestination.path
        )[.size] as? Int64) ?? downloadedBytes
        onProgress(Progress(
            phase: .downloading,
            completedSegments: totalSegments,
            totalSegments: totalSegments,
            downloadedBytes: finalSize,
            pieces: tracks.map { Array(repeating: .done, count: $0.segments.count) }
        ))

        logger.notice("Stream download complete task=\(taskID, privacy: .public): \(finalDestination.lastPathComponent)")
        succeeded = true
        return finalDestination
    }

    // MARK: - Per-track download

    /// Downloads one track's `pending` segments in a sliding window, decrypts
    /// them if the playlist is AES-128, and concatenates all of them into
    /// `output`.
    ///
    /// Each track gets its own directory: both tracks number their segments from
    /// zero, so a shared one would have audio overwriting video.
    ///
    /// - Returns: the URL actually written, which differs from `output` if
    ///   something appeared at that path while the segments were downloading.
    private func downloadTrack(
        _ track: TrackPlan,
        into trackDir: URL,
        assembleTo output: URL,
        pending pendingIndices: [Int],
        session: URLSession,
        headers: [String: String],
        concurrency: Int,
        isCancelled: () -> Bool,
        onSegmentStart: (Int) -> Void,
        onSegmentComplete: (_ index: Int, _ bytes: Int64) -> Void,
        onTick: () -> Void
    ) async throws -> URL {
        let totalSegments = track.segments.count

        // ── AES-128 key (HLS only) ──
        var aesKey: Data? = nil
        if let enc = track.encryption {
            aesKey = try await fetchData(url: enc.keyURL, headers: headers)
            guard aesKey?.count == 16 else { throw StreamDownloadError.invalidEncryptionKey }
        }

        // ── Init segment (fMP4) ──
        let initTempURL = trackDir.appendingPathComponent("init.mp4")
        if let initURL = track.initSegmentURL {
            logger.debug("Downloading \(track.label, privacy: .public) init segment: \(initURL.absoluteString)")
            let seg = StreamSegment(index: -1, url: initURL, tempDir: trackDir, headers: headers, byteRange: track.initSegmentByteRange)
            try await downloadSingleSegment(seg, to: initTempURL, session: session, headers: headers)
            if isCancelled() { throw DownloadError.cancelled }
        }

        // ── Sliding-window parallel segment downloads ───────────────────────
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            var nextToSubmit = 0
            var inFlight = 0

            func submit(_ pendingIndex: Int) {
                let idx = pendingIndices[pendingIndex]
                let segInfo = track.segments[idx]
                onSegmentStart(idx)
                group.addTask {
                    let seg = StreamSegment(index: idx, url: segInfo.url,
                                            tempDir: trackDir, headers: headers, byteRange: segInfo.byteRange)
                    try await seg.download(session: session)
                    let size = (try? FileManager.default.attributesOfItem(
                        atPath: seg.tempFileURL.path)[.size] as? Int64) ?? 0
                    return (idx, size)
                }
                nextToSubmit += 1
                inFlight += 1
            }

            // Wakes the loop below with no piece (index -1), so bytes still
            // arriving are reported between completions: pieces sharing one
            // connection finish together, seconds apart.
            func addTicker() {
                group.addTask {
                    try? await Task.sleep(for: Self.tickInterval)
                    return (-1, 0)
                }
            }

            while nextToSubmit < pendingIndices.count && inFlight < concurrency { submit(nextToSubmit) }
            if inFlight > 0 { addTicker() }

            for try await (idx, bytes) in group {
                if isCancelled() { throw DownloadError.cancelled }
                guard idx >= 0 else {
                    onTick()
                    if inFlight > 0 { addTicker() }
                    continue
                }
                inFlight -= 1

                if let enc = track.encryption, let key = aesKey {
                    let segURL = trackDir.appendingPathComponent(String(format: "segment-%04d.tmp", idx))
                    let iv = enc.iv ?? ivFromSequenceNumber(track.mediaSequence + idx)
                    try decryptAES128(fileURL: segURL, key: key, iv: iv)
                }

                // Re-create the segment only to commit its durable marker.
                // It owns no in-memory download state at this point; its stable
                // path is the resume key across pause/relaunch boundaries.
                let completed = StreamSegment(
                    index: idx, url: track.segments[idx].url, tempDir: trackDir, headers: headers,
                    byteRange: track.segments[idx].byteRange
                )
                try await completed.markComplete()

                onSegmentComplete(idx, bytes)

                if nextToSubmit < pendingIndices.count { submit(nextToSubmit) }
                // Last piece in: wake the ticker now rather than wait it out.
                if inFlight == 0 { group.cancelAll() }
            }
        }

        if isCancelled() { throw DownloadError.cancelled }

        // ── Assemble ──
        // `output` is a scratch path; the caller renames it into place.
        try? FileManager.default.removeItem(at: output)
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let outHandle = try? FileHandle(forWritingTo: output) else {
            throw StreamDownloadError.cannotWriteOutput
        }
        logger.notice("Assembling \(totalSegments, privacy: .public) \(track.label, privacy: .public) segments → \(output.lastPathComponent)")

        /// Copies through a fixed buffer: a DASH SegmentBase "segment" is
        /// the whole file.
        func append(_ file: URL) throws {
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: Self.assembleBufferSize), !chunk.isEmpty {
                try outHandle.write(contentsOf: chunk)
            }
        }

        do {
            if track.initSegmentURL != nil {
                try append(initTempURL)
            }
            for i in 0..<totalSegments {
                if isCancelled() { throw DownloadError.cancelled }
                let segFile = trackDir.appendingPathComponent(String(format: "segment-%04d.tmp", i))
                guard FileManager.default.fileExists(atPath: segFile.path) else {
                    throw StreamDownloadError.missingSegment(i)
                }
                try append(segFile)
            }
            try outHandle.close()
        } catch {
            try? outHandle.close()
            // The segments stay for a retry; the partial join goes.
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// How often bytes still arriving are reported.
    private static let tickInterval: Duration = .milliseconds(500)

    /// Bytes of a segment held in memory while it is appended.
    private static let assembleBufferSize = 8 << 20

    /// Rate-limits mux progress to one log line per 10%.
    ///
    /// A reference type because MediaMuxer's callback is `@Sendable` and fires
    /// from the process's output reader, so it cannot mutate a captured local.
    private final class MuxProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lastDecile = -1

        func note(_ fraction: Double) {
            let decile = Int((fraction * 10).rounded(.down))
            lock.lock()
            let isNew = decile > lastDecile
            if isNew { lastDecile = decile }
            lock.unlock()
            guard isNew else { return }
            Logger(subsystem: "Convoy", category: "StreamDownloader")
                .debug("Merging: \(decile * 10, privacy: .public)%")
        }
    }

    // MARK: - Cancel

    public func cancel(taskID: UUID) {
        cancellations[taskID]?()
        cancellations.removeValue(forKey: taskID)
    }

    public func isRunning(taskID: UUID) -> Bool {
        cancellations[taskID] != nil
    }

    // MARK: - Manifest parsing (routes HLS vs DASH)

    /// Everything needed to download and assemble one track.
    private struct TrackPlan {
        let segments: [SegmentInfo]
        let initSegmentURL: URL?
        /// Non-nil when this track's init segment is a byte-range slice of a
        /// shared physical file, not a standalone resource. See
        /// `HLSByteRange`'s doc comment. Always nil for DASH.
        let initSegmentByteRange: HLSByteRange?
        let isFMP4: Bool
        let encryption: HLSParser.EncryptionInfo?
        let mediaSequence: Int
        /// Total media duration, where the manifest declares one. Used to give
        /// the muxer a duration to report progress against.
        let durationSec: Double?
        /// `"video"` or `"audio"` — names this track's temp subdirectory and
        /// appears in its log lines.
        let label: String
    }

    /// One or two tracks. `audio` non-nil means they must be merged.
    private struct ManifestPlan {
        let primary: TrackPlan
        let audio: TrackPlan?
    }

    private struct SegmentInfo {
        let url: URL
        let duration: Double
        /// Non-nil for byte-range-addressed HLS segments (see `HLSByteRange`'s
        /// doc comment). Always nil for DASH — a DASH `SegmentBase` single-file
        /// representation is routed entirely through the byte-range engine by
        /// the browser extension's `exactUrl` distinction and never reaches
        /// `StreamDownloader` at all; anything that does reach here has its own
        /// SegmentTemplate/SegmentList addressing, not HLS-style byte ranges.
        let byteRange: HLSByteRange?
    }

    private func parseManifest(
        streamType: String, text: String, baseURL: URL,
        representationId: String?, bandwidth: Int?, preferredAudioLanguage: String?,
        hlsAudioTracks: [HLSAudioCandidate]?, headers: [String: String]
    ) async throws -> ManifestPlan {

        switch streamType {
        case "hls":
            guard let playlist = HLSParser.parse(text: text, baseURL: baseURL) else {
                throw StreamDownloadError.manifestParseError("Could not parse HLS playlist")
            }
            if playlist.unsupportedEncryption {
                throw StreamDownloadError.drmProtected
            }
            if !playlist.isVOD {
                // Live streams aren't finite — we download whatever is currently
                // in the playlist but proceed anyway. Some "live" playlists
                // are actually catch-up streams that do terminate.
                logger.warning("HLS playlist has no EXT-X-ENDLIST — stream may be live, download may be incomplete")
            }

            // HLS carries audio inside the media playlist in the common case.
            // The split-track form (#EXT-X-MEDIA TYPE=AUDIO with its own URI)
            // lives in the *master* playlist, resolved by the browser extension
            // before we ever get here (see HLSAudioCandidate's doc comment for
            // why this side can't rediscover that association on its own) —
            // hlsAudioTracks is that resolution's result, passed straight
            // through. Absent/empty means this variant's own segments already
            // carry sound, same as before this parameter existed.
            let segments = playlist.segments.map { SegmentInfo(url: $0.url, duration: $0.duration, byteRange: $0.byteRange) }
            let videoTrack = TrackPlan(
                segments: segments,
                initSegmentURL: playlist.initSegmentURL,
                initSegmentByteRange: playlist.initSegmentByteRange,
                isFMP4: playlist.isFMP4,
                encryption: playlist.encryption,
                mediaSequence: playlist.mediaSequence,
                durationSec: playlist.totalDuration,
                label: "video"
            )

            guard let candidates = hlsAudioTracks, !candidates.isEmpty,
                  let chosen = Self.selectHLSAudioTrack(candidates, preferring: preferredAudioLanguage) else {
                return ManifestPlan(primary: videoTrack, audio: nil)
            }

            logger.notice("HLS split audio: fetching \(chosen.url.absoluteString) (lang=\(chosen.lang ?? "unset", privacy: .public))")
            let audioText: String
            do {
                audioText = try await fetchText(url: chosen.url, headers: headers)
            } catch {
                // A failed audio fetch shouldn't sink a video download that's
                // otherwise perfectly fine — continuing video-only, silent, is
                // the same outcome as before this feature existed, not a new
                // failure mode. Logged, not thrown.
                logger.warning("HLS audio playlist fetch failed, continuing video-only: \(error.localizedDescription)")
                return ManifestPlan(primary: videoTrack, audio: nil)
            }
            guard let audioPlaylist = HLSParser.parse(text: audioText, baseURL: chosen.url) else {
                logger.warning("HLS audio playlist failed to parse, continuing video-only.")
                return ManifestPlan(primary: videoTrack, audio: nil)
            }
            let audioSegments = audioPlaylist.segments.map { SegmentInfo(url: $0.url, duration: $0.duration, byteRange: $0.byteRange) }
            guard !audioSegments.isEmpty else {
                logger.warning("HLS audio playlist resolved to zero segments, continuing video-only.")
                return ManifestPlan(primary: videoTrack, audio: nil)
            }
            let audioTrack = TrackPlan(
                segments: audioSegments,
                initSegmentURL: audioPlaylist.initSegmentURL,
                initSegmentByteRange: audioPlaylist.initSegmentByteRange,
                isFMP4: audioPlaylist.isFMP4,
                encryption: audioPlaylist.encryption,
                mediaSequence: audioPlaylist.mediaSequence,
                durationSec: audioPlaylist.totalDuration,
                label: "audio"
            )
            return ManifestPlan(primary: videoTrack, audio: audioTrack)

        case "dash":
            guard let tracks = DASHSegmentResolver.resolveTracks(
                mpdText: text, baseURL: baseURL,
                representationId: representationId, bandwidth: bandwidth,
                preferredAudioLanguage: preferredAudioLanguage
            ) else {
                throw StreamDownloadError.manifestParseError("Could not resolve DASH segments")
            }

            func plan(_ stream: DASHSegmentResolver.ResolvedStream, label: String) -> TrackPlan {
                TrackPlan(
                    segments: stream.segments.map { SegmentInfo(url: $0, duration: 0, byteRange: nil) },
                    initSegmentURL: stream.initSegmentURL,
                    initSegmentByteRange: nil,
                    isFMP4: true, // DASH is always fMP4
                    encryption: nil, // DASH DRM (Widevine/PlayReady) is not handled here
                    mediaSequence: 0,
                    durationSec: stream.totalDuration,
                    label: label
                )
            }

            return ManifestPlan(
                primary: plan(tracks.video, label: "video"),
                audio: tracks.audio.map { plan($0, label: "audio") }
            )

        default:
            throw StreamDownloadError.manifestParseError("Unknown stream type: \(streamType)")
        }
    }

    // MARK: - HTTP helpers

    /// Picks one candidate from an HLS variant's AUDIO group. Same preference
    /// order as DASHSegmentResolver.selectAudio (language match, then the
    /// group's own DEFAULT flag, then simply the first declared) but kept as
    /// a separate implementation rather than one shared generic version — the
    /// two carry different fields (isDefault vs. DASH's Role=main) that map
    /// onto "the fallback a player would pick" in spirit but not in literal
    /// shape, and forcing them through one shared type would either lose
    /// that nuance or add an abstraction with exactly one real use each side.
    ///
    /// Language matching is loose, not a real BCP-47/ISO 639 bridge: a
    /// preference of "en" will not match a rendition declaring "eng" — same
    /// documented limitation as the DASH side.
    private static func selectHLSAudioTrack(_ candidates: [HLSAudioCandidate], preferring language: String?) -> HLSAudioCandidate? {
        guard !candidates.isEmpty else { return nil }
        var pool = candidates
        if let language, !language.isEmpty {
            let matches = pool.filter { AudioLanguage.matches($0.lang, preferred: language) }
            if !matches.isEmpty { pool = matches }
        }
        if pool.count > 1 {
            let defaults = pool.filter(\.isDefault)
            if !defaults.isEmpty { pool = defaults }
        }
        return pool.first
    }

    private func fetchText(url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url: url, headers: headers)
        guard let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw StreamDownloadError.manifestParseError("Manifest is not valid text")
        }
        return text
    }

    /// A playlist or key, fetched whole. A failure of the moment is retried
    /// (see `RetryPolicy`); as the first request of a stream, a host DNS
    /// can't find fails at once.
    private func fetchData(url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        var failures = 0
        while true {
            var retryAfter: TimeInterval?
            do {
                let (data, response) = try await URLSession.cookieless.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    retryAfter = RetryPolicy.retryAfter(http)
                    throw DownloadError.httpError(http.statusCode)
                }
                return data
            } catch {
                failures += 1
                guard RetryPolicy.isTransient(error, serverReached: false),
                      failures < RetryPolicy.maxConsecutiveFailures else { throw error }
                let seconds = RetryPolicy.delay(beforeRetry: failures, serverAsked: retryAfter)
                logger.notice("Fetching \(url.lastPathComponent) failed (\(error.localizedDescription, privacy: .public)) — retry \(failures, privacy: .public) in \(seconds, format: .fixed(precision: 1), privacy: .public)s")
                try await RetryPolicy.wait(seconds) { !Task.isCancelled }
            }
        }
    }

    /// Downloads a single segment to a specific URL (used for init segment which
    /// needs to land at a known path, not the generic segment-NNNN.tmp naming).
    private func downloadSingleSegment(_ seg: StreamSegment, to dest: URL, session: URLSession, headers: [String: String]) async throws {
        // Use the standard StreamSegment download mechanism, then move to dest.
        try await seg.download(session: session)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: seg.tempFileURL, to: dest)
    }

    // MARK: - URLSession builder

    private func buildSession(concurrency: Int, delegate: StreamSegmentSessionDelegate) -> URLSession {
        let config = URLSessionConfiguration.cookieless
        config.httpMaximumConnectionsPerHost = concurrency
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - AES-128 decryption

    /// Decrypts a segment file in-place using AES-128-CBC with PKCS7 padding.
    /// This is the standard encryption mode mandated by RFC 8216 (HLS spec).
    private func decryptAES128(fileURL: URL, key: Data, iv: Data) throws {
        let encrypted = try Data(contentsOf: fileURL)
        guard encrypted.count > 0 else { return }

        let decrypted = try encrypted.withUnsafeBytes { encPtr in
            try key.withUnsafeBytes { keyPtr in
                try iv.withUnsafeBytes { ivPtr in
                    var outLength = 0
                    // AES-128-CBC produces output at most as large as the input
                    // (PKCS7 padding only ever removes bytes, never adds beyond one block).
                    let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: encrypted.count)
                    defer { outBuffer.deallocate() }

                    let status = CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, kCCKeySizeAES128,
                        ivPtr.baseAddress,
                        encPtr.baseAddress, encrypted.count,
                        outBuffer, encrypted.count,
                        &outLength
                    )
                    guard status == kCCSuccess else {
                        throw StreamDownloadError.decryptionFailed(Int(status))
                    }
                    return Data(bytes: outBuffer, count: outLength)
                }
            }
        }

        try decrypted.write(to: fileURL, options: .atomic)
    }

    /// Derives a 16-byte AES IV from the segment sequence number (big-endian UInt128).
    /// This is the HLS spec's default when no explicit IV is given in `#EXT-X-KEY`.
    private func ivFromSequenceNumber(_ seqNum: Int) -> Data {
        var iv = Data(repeating: 0, count: 16)
        var n = UInt64(bitPattern: Int64(seqNum))
        // Write as big-endian in the last 8 bytes (seq numbers rarely exceed UInt64)
        for i in stride(from: 15, through: 8, by: -1) {
            iv[i] = UInt8(n & 0xFF)
            n >>= 8
        }
        return iv
    }
}

// MARK: - StreamDownloadError

public enum StreamDownloadError: LocalizedError {
    case manifestParseError(String)
    case drmProtected
    case invalidEncryptionKey
    case decryptionFailed(Int)
    case cannotWriteOutput
    case missingSegment(Int)

    public var errorDescription: String? {
        switch self {
        case .manifestParseError(let msg):
            return "Could not read stream playlist: \(msg)"
        // SAMPLE-AES, Widevine or FairPlay. Named in the log, not here.
        case .drmProtected:
            return "This video is copy-protected and can't be downloaded."
        case .invalidEncryptionKey:
            return "This stream's encryption key isn't valid, so it can't be unscrambled."
        case .decryptionFailed(let code):
            return "This stream couldn't be unscrambled (error \(code))."
        case .cannotWriteOutput:
            return "Could not write to the download destination."
        case .missingSegment(let i):
            return "Stream assembly failed: segment \(i) is missing."
        }
    }
}
