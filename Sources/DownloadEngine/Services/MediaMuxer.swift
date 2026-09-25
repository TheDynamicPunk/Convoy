import AVFoundation
import Foundation
import OSLog

// MARK: - MediaMuxer

/// Merges a separately-downloaded video-only track and audio-only track into one
/// playable file.
///
/// Adaptive streams carry video and audio as independent Representations —
/// each downloadable on its own, neither playable on its own. DASH does this
/// universally; HLS does it whenever the variant references a separate
/// `#EXT-X-MEDIA:TYPE=AUDIO` rendition. Concatenating fMP4 segments (which
/// `StreamDownloader` already does) produces a valid file *per track*, and then
/// there is no way to get to a single file without a container-level rewrite.
///
/// AVFoundation does all of it. There is no ffmpeg here, and no fallback —
/// see "Why there is no ffmpeg" below.
///
/// This used to shell out to ffmpeg unconditionally, on the stated grounds
/// that "neither Foundation nor AVFoundation will rewrite a fragmented MP4
/// container without re-encoding". That is not true. `AVMutableComposition`
/// plus an `AVAssetExportSession` on `AVAssetExportPresetPassthrough` does
/// exactly that — measured against real YouTube output: 360p H.264, 360p AV1,
/// a 689 MB 4K AV1 merge in 1.77s, an ffmpeg-produced *fragmented* MP4, and
/// MPEG-TS video paired with MPEG-TS audio. Every one produced a valid file
/// with both tracks, the right duration and the bitstreams untouched.
///
/// ## Why there is no ffmpeg
///
/// There was, briefly, as a fallback for the one container AVFoundation
/// genuinely cannot read: WebM/Matroska, which it reports as "Cannot Open".
/// It is gone because that fallback could not pay for itself.
///
/// YouTube cannot reach it at all — `YouTubeResolver` offers only
/// plain-HTTP MP4 formats, so every merge on that path is MP4 + M4A. What
/// remained was WebM arriving through `StreamDownloader` from some other
/// site, against 27 MB of download, ~350 lines across four files, a
/// GPLv3 binary, and a manifest entry to keep pinned. A second merge path
/// that runs only when the first has already failed is also the hardest kind
/// to keep correct, because nothing exercises it.
///
/// So a container AVFoundation cannot read now fails, with an error that
/// says so plainly rather than offering a download that may not help. If
/// that turns out to matter for real sites, the answer is to filter those
/// representations out in `DASHSegmentResolver` the way YouTube's list is
/// filtered — fail early and clearly, rather than after a full transfer.
///
/// A merge is a stream copy — no re-encode, both bitstreams written through
/// untouched, so it is I/O-bound and lossless.
public actor MediaMuxer {
    public static let shared = MediaMuxer()

    private let logger = Logger(subsystem: "Convoy", category: "MediaMuxer")

    /// In-flight exports keyed by download task, so `cancel(taskID:)` can stop
    /// one mid-merge.
    private var exporting: [UUID: AVAssetExportSession] = [:]

    // MARK: - Availability

    /// Whether merging is possible. Always true: nothing has to be installed.
    ///
    /// Kept as a method because callers ask a real question — it is just that
    /// the answer stopped depending on anything.
    public func isAvailable() async -> Bool { true }

    // MARK: - Mux

    /// Stream-copies `videoURL` and `audioURL` into a single MP4 at `outputURL`.
    ///
    /// - durationSec: the true media duration when the caller knows it.
    ///   Used to bound the merge — see `muxNatively` for why the files'''
    ///   own declared durations cannot be trusted. Pass nil when unknown.
    /// - Returns: `outputURL`, for symmetry with `StreamDownloader.download`.
    @discardableResult
    public func mux(
        taskID: UUID,
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        durationSec: Double? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        for input in [videoURL, audioURL] where !FileManager.default.fileExists(atPath: input.path) {
            throw MuxError.missingInput(input.lastPathComponent)
        }

        let result = try await muxNatively(
            taskID: taskID, videoURL: videoURL, audioURL: audioURL,
            outputURL: outputURL, durationSec: durationSec
        )
        onProgress?(1.0)
        return result
    }

    // MARK: - Native mux

    /// Merges via AVFoundation, with no re-encode and no subprocess.
    ///
    /// `AVAssetExportPresetPassthrough` is what makes this a mux rather than a
    /// transcode: sample data is copied through, so the result is bit-identical
    /// media in a new container. `shouldOptimizeForNetworkUse` is the moov-atom
    /// move that `-movflags +faststart` does on the ffmpeg path.
    ///
    /// Progress is reported as a single jump to 1.0 rather than sampled. The
    /// operation is seconds even for a 4K feature — 1.77s for 689 MB — and
    /// `AVAssetExportSession`'s own progress reporting differs across the
    /// macOS 14 and 15 APIs; a progress bar nobody sees is not worth two code
    /// paths.
    private func muxNatively(
        taskID: UUID,
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        durationSec: Double?
    ) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        // Throws for a container AVFoundation cannot read (WebM), which is the
        // main reason the caller falls back.
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MuxError.noTrack(videoURL.lastPathComponent, kind: "video")
        }
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw MuxError.noTrack(audioURL.lastPathComponent, kind: "audio")
        }

        let composition = AVMutableComposition()
        guard let videoOut = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioOut = composition.addMutableTrack(
                  withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw MuxError.nativeExportUnavailable
        }

        // Both tracks are inserted over one shared span, and inserting over
        // each track's *own* declared duration instead is a real bug rather
        // than a style choice.
        //
        // YouTube's DASH mp4 files declare a duration in their header that is
        // exactly twice the truth, and AVFoundation believes it — measured on
        // three unrelated videos: 19s read as 37.87, 635s as 1269.13, 213s as
        // 426.08. The sample data is fine; only the header lies. Insert that
        // declared range and the export dutifully produces a file of the
        // stated length, which ffmpeg then reports at half the real frame rate
        // (15fps becoming 7.49fps) — a file that looks plausible and plays
        // wrong. The paired m4a audio declares its duration correctly, which
        // is why the shorter of the two is the trustworthy one here.
        //
        // `durationSec` narrows it further when the caller knows the real
        // figure (yt-dlp and the DASH manifest both report it). Everything is
        // combined with `min` so this can only ever bound the span, never
        // extend it past media that actually exists.
        //
        // The cost is that genuinely mismatched tracks get trimmed to the
        // shorter. For a video and its own audio — the only pairing this app
        // makes — they describe one timeline, so there is nothing to lose.
        var span = CMTimeMinimum(
            try await videoAsset.load(.duration),
            try await audioAsset.load(.duration)
        )
        if let durationSec, durationSec > 0 {
            span = CMTimeMinimum(span, CMTime(seconds: durationSec, preferredTimescale: 600))
        }
        let range = CMTimeRange(start: .zero, duration: span)

        try videoOut.insertTimeRange(range, of: videoTrack, at: .zero)
        try audioOut.insertTimeRange(range, of: audioTrack, at: .zero)

        guard let export = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw MuxError.nativeExportUnavailable
        }
        export.shouldOptimizeForNetworkUse = true

        // The export writes to a scratch file, and only then takes the
        // destination itself. It cannot write straight there:
        // AVAssetExportSession refuses a path that already exists, and the way
        // that used to be dealt with was `removeItem(at: outputURL)` — which
        // deleted whatever the person had there, silently, to make room.
        let scratch = DestinationScratchFile.mux.url(for: taskID, beside: outputURL, extension: "mp4")
        try? FileManager.default.removeItem(at: scratch)

        logger.notice("Muxing natively task=\(taskID, privacy: .public) → \(outputURL.lastPathComponent)")

        exporting[taskID] = export
        defer { exporting[taskID] = nil }

        if #available(macOS 15.0, *) {
            do {
                try await export.export(to: scratch, as: .mp4)
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                if export.status == .cancelled { throw DownloadError.cancelled }
                throw error
            }
        } else {
            export.outputURL = scratch
            export.outputFileType = .mp4
            await export.export()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: scratch)
                if export.status == .cancelled { throw DownloadError.cancelled }
                throw export.error ?? MuxError.nativeExportUnavailable
            }
        }

        guard FileManager.default.fileExists(atPath: scratch.path) else {
            throw MuxError.nativeExportUnavailable
        }

        // Callers delete the input tracks once this returns.
        FileDurability.flush(scratch)

        // Saves beside an unrelated file that arrived while the download ran,
        // never over it. The name that comes back is the one to report.
        let written: URL
        do {
            written = try DownloadDestination.move(scratch, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        logger.notice("Native mux complete task=\(taskID, privacy: .public): \(written.lastPathComponent)")
        return written
    }

    // MARK: - Cancel

    public func cancel(taskID: UUID) {
        exporting[taskID]?.cancelExport()
    }

    public func isRunning(taskID: UUID) -> Bool {
        exporting[taskID] != nil
    }
}

// MARK: - MuxError

public enum MuxError: LocalizedError {
    case missingInput(String)
    /// macOS opened the file but found no track of the kind needed — in
    /// practice an unreadable container, since it reports WebM this way.
    case noTrack(String, kind: String)
    /// macOS refused to build or finish a passthrough export.
    case nativeExportUnavailable

    public var errorDescription: String? {
        switch self {
        case .noTrack(let name, let kind):
            return "macOS can't read the \(kind) track in \(name). This is usually a WebM or Matroska file, which macOS doesn't support."
        case .nativeExportUnavailable:
            return "macOS couldn't combine this video and audio without re-encoding them."
        case .missingInput(let name):
            return "Cannot merge tracks: \(name) is missing."
        }
    }
}
