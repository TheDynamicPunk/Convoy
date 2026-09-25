import Foundation
import OSLog

public struct ResolvedMedia {
    public let url: URL
    public let headers: [String: String]
    public let suggestedFilename: String?
    public let totalBytes: Int64?
}

/// What a resolve turned up about a video: the qualities on offer, plus the
/// handful of details worth showing while the user chooses.
///
/// The title, duration and thumbnail all come out of the same `--dump-json`
/// yt-dlp already runs, so surfacing them costs nothing beyond reading three
/// more keys — and they turn the ~2s that resolve takes from a blank wait
/// into a recognisable video.
public struct YouTubeVideoInfo: Sendable {
    public let title: String
    public let durationSeconds: Double?
    public let thumbnailURL: URL?
    public let options: [YouTubeFormatOption]
    /// One per language on a video with dubbed audio, original first. Empty
    /// when there is only one language, and so nothing to choose.
    public let audioTracks: [YouTubeAudioTrack]
    let audioCandidates: [YouTubeResolver.AudioCandidate]

    init(
        title: String,
        durationSeconds: Double?,
        thumbnailURL: URL?,
        options: [YouTubeFormatOption],
        audioTracks: [YouTubeAudioTrack] = [],
        audioCandidates: [YouTubeResolver.AudioCandidate] = []
    ) {
        self.title = title
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.options = options
        self.audioTracks = audioTracks
        self.audioCandidates = audioCandidates
    }

    /// The track to merge into a video-only pick: in `language` on a dubbed
    /// video, the only one there is otherwise. Chosen here rather than left
    /// to yt-dlp's `bestaudio` — see `MergeAudio`.
    public func mergeAudio(language: String?) -> MergeAudio? {
        YouTubeResolver.pickMergeAudio(from: audioCandidates, language: language)
    }
}

/// One language of a video with dubbed audio.
public struct YouTubeAudioTrack: Identifiable, Sendable, Equatable {
    /// yt-dlp's code for it, e.g. "hi" or "en-US".
    public let language: String
    public let name: String
    public let isOriginal: Bool
    public var id: String { language }
}

/// A specific audio-only format to merge into a video-only download.
///
/// Naming one matters twice over, which is why this is not just
/// `bestaudio`:
///
/// 1. **It keeps the merge native.** `MediaMuxer` merges through
///    AVFoundation, which cannot read WebM — and yt-dlp's `bestaudio`
///    routinely picks Opus-in-WebM (itag 251) over the same-bitrate AAC
///    (itag 140), because it ranks Opus higher. Asking for AAC by id is what
///    lets the merge happen without ffmpeg at all.
/// 2. **It keeps the result playable.** Opus inside an MP4 is a container
///    macOS will not play: QuickTime and Finder Preview refuse it. An AAC
///    track plays everywhere, which is the same reason `isAppleNativeContainer`
///    already sorts MP4 above WebM.
///
/// Knowing the id up front also means knowing the *size* up front, so a
/// two-file download can report one continuous total instead of discovering
/// the second file's size partway through and growing the total under the
/// user. See `YouTubeDownloader.download`.
public struct MergeAudio: Sendable, Equatable {
    public let formatID: String
    public let ext: String
    public let filesizeBytes: Int64?
    /// What yt-dlp is asked for — see `YouTubeResolver.audioSelector`.
    public let selector: String

    public init(formatID: String, ext: String, filesizeBytes: Int64?, selector: String? = nil) {
        self.formatID = formatID
        self.ext = ext
        self.filesizeBytes = filesizeBytes
        self.selector = selector ?? formatID
    }
}

public struct YouTubeFormatOption: Identifiable, Sendable {
    public let id: String // yt-dlp's format_id
    public let label: String // e.g. "1080p60 · mp4" or "Audio · m4a (128kbps)"
    public let url: URL
    public let headers: [String: String]
    public let ext: String
    public let filesizeBytes: Int64?
    public let height: Int?
    public let hasVideo: Bool
    public let hasAudio: Bool
    /// True for a video-only format when the video also offers an audio-only
    /// track, so the picker can tell whether a video pick will have sound.
    /// Which track is merged is chosen separately (`MergeAudio`); it is
    /// downloaded as its own file and merged by `MediaMuxer`. False for
    /// combined and audio-only formats.
    public let audioMergeAvailable: Bool
}

public enum YouTubeResolverError: LocalizedError {
    case helpersNotInstalled
    case processFailed(String)
    case noPlayableFormat
    case malformedOutput
    /// YouTube refused this request as unattended — the case the PO-Token
    /// provider exists for, and the only reason to spend 41 MB on it.
    case botCheckBlocked

    public var errorDescription: String? {
        switch self {
        case .helpersNotInstalled:
            return "yt-dlp isn't installed yet. Open Settings → YouTube to install the download helpers, then try again."
        case .processFailed(let detail):
            return "yt-dlp failed: \(detail)"
        case .noPlayableFormat:
            return "yt-dlp couldn't find a downloadable format for this video (YouTube may be blocking this session)."
        case .malformedOutput:
            return "yt-dlp returned output Convoy couldn't parse."
        case .botCheckBlocked:
            return """
            YouTube is asking this download to prove it isn't automated. \
            Two things help: turn on "Use browser cookies for YouTube" in \
            Settings, and install the PO-Token provider there (about 41 MB).
            """
        }
    }
}

/// Resolves a YouTube (or any yt-dlp-supported) URL down to a real, direct,
/// currently-valid media URL — by shelling out to the real yt-dlp binary
/// rather than reimplementing any of YouTube's cipher/SABR/PO-Token logic
/// ourselves. yt-dlp only ever resolves the URL here (--dump-json, no
/// download); the actual byte transfer still goes through our own
/// DownloadTask/DownloadSegment engine, so pause/resume/persistence/UI all
/// keep working exactly as they do for every other site.
///
/// yt-dlp and its PO-Token provider (bgutil-pot) are NOT bundled in the repo
/// — both ship prebuilt macOS binaries from their own GitHub releases, which
/// YouTubeHelperInstaller fetches on request from Settings → YouTube. When
/// YouTube changes something and breaks extraction, updating the helper is
/// all it takes; no Swift code here needs to change.
public actor YouTubeResolver {
    public static let shared = YouTubeResolver()

    private let logger = Logger(subsystem: "Convoy", category: "YouTubeResolver")
    private var potProcess: Process?

    private var binDir: URL { HelperLocations.binDirectory }

    private var ytdlpPath: String { HelperLocations.ytdlp }
    private var potPath: String { binDir.appendingPathComponent("bgutil-pot").path }

    public func isSupported(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("youtube.com") || host == "youtu.be"
    }

    /// Appends `ratebypass=yes` to a googlevideo.com URL if it's missing.
    /// A minor, secondary knob — historically not the main throttling
    /// mechanism. That was the CDN URL's `n` query parameter: YouTube's
    /// player JS transforms `n` into a token the CDN checks per-request, and
    /// an un-transformed `n` was throttled server-side (the familiar ~1 Mbps
    /// cap) no matter what headers or parallelism the client used. yt-dlp
    /// solves that with its EJS challenge-solver scripts, which need a real
    /// JS runtime — see `HelperLocations.jsRuntimeArguments()`.
    ///
    /// Worth knowing how much of that is still live: measured against
    /// YouTube in Sep 2026, the client yt-dlp now defaults to (`visionos`)
    /// returns URLs carrying `sig` and `lsparams` but **no `n` parameter at
    /// all**, and downloads ran at ~85 Mbps with a JS runtime, with a
    /// different one, and with none. The runtime still earns its place —
    /// other videos do exercise the solver, and yt-dlp now warns that
    /// extraction without a runtime is deprecated and may hide formats — but
    /// "downloads crawl at 1 Mbps without it" is no longer the symptom to
    /// expect, and this function is not what would fix it if it were.
    /// (See https://github.com/yt-dlp/yt-dlp/wiki/EJS.)
    ///
    /// Idempotent: if `ratebypass` is already in the query we leave it
    /// untouched. Non-googlevideo URLs pass through unchanged.
    static func bypassGooglevideoThrottle(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), host.hasSuffix("googlevideo.com") else {
            return url
        }
        let urlString = url.absoluteString
        if urlString.contains("ratebypass=yes") {
            return url
        }
        let separator = urlString.contains("?") ? "&" : "?"
        return URL(string: urlString + separator + "ratebypass=yes") ?? url
    }

    /// Ensures googlevideo.com headers include Origin and Referer.
    ///
    /// yt-dlp's `--dump-json` `http_headers` include User-Agent, Accept,
    /// Accept-Language, and Sec-Fetch-Mode — but NOT `Origin` or `Referer`.
    /// yt-dlp adds those internally in its own downloader code, so when it
    /// downloads itself things work fine. But since Convoy uses its
    /// own download engine with the pre-resolved URLs, those headers are
    /// missing and YouTube's CDN returns 403 Forbidden without them.
    static func ensureYouTubeCDNHeaders(_ headers: [String: String], for url: URL) -> [String: String] {
        guard let host = url.host?.lowercased(), host.hasSuffix("googlevideo.com") else {
            return headers
        }
        var result = headers
        if result["Origin"] == nil {
            result["Origin"] = "https://www.youtube.com"
        }
        if result["Referer"] == nil {
            result["Referer"] = "https://www.youtube.com/"
        }
        return result
    }

    /// Short, human-readable codec name from yt-dlp's raw vcodec string
    /// (e.g. "avc1.640028" -> "H.264"). Used both in the label (so two
    /// same-resolution formats that are genuinely different files, e.g. AV1
    /// vs H.264 at 1080p, don't render as identical-looking rows) and as
    /// part of the dedup key below.
    private static func friendlyVideoCodec(_ vcodec: String?) -> String? {
        guard let vcodec, vcodec != "none" else { return nil }
        let lower = vcodec.lowercased()
        if lower.hasPrefix("avc1") || lower.hasPrefix("h264") { return "H.264" }
        if lower.hasPrefix("av01") { return "AV1" }
        if lower.hasPrefix("vp09") || lower.hasPrefix("vp9") { return "VP9" }
        if lower.hasPrefix("vp8") { return "VP8" }
        if lower.hasPrefix("hev1") || lower.hasPrefix("hvc1") || lower.hasPrefix("hevc") { return "HEVC" }
        return nil
    }

    /// Lists every real, currently-resolved format yt-dlp found for this
    /// URL — not just "best". A single --dump-json call (no -f filter)
    /// already returns a full "formats" array with each entry's own
    /// already-resolved url, so this needs no extra yt-dlp invocations per
    /// quality choice.
    public func listFormats(url: URL) async throws -> YouTubeVideoInfo {
        guard FileManager.default.fileExists(atPath: ytdlpPath) else {
            throw YouTubeResolverError.helpersNotInstalled
        }

        await ensurePotProviderRunning()

        var args = ["--dump-json", "--no-warnings"]
        args += HelperLocations.pluginArguments()
        args += HelperLocations.jsRuntimeArguments()
        args += HelperLocations.youtubePlayerClientArguments()
        if FileManager.default.fileExists(atPath: potPath) {
            args += ["--extractor-args", "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416"]
        }
        args.append(url.absoluteString)

        logger.notice("Listing formats for \(url.absoluteString) via yt-dlp")
        let (stdout, stderr, exitCode) = try await runWithTimeout(ytdlpPath, args: args, timeoutSeconds: 45)

        guard exitCode == 0 else {
            logger.error("yt-dlp exited \(exitCode): \(stderr)")
            if Self.looksLikeBotCheck(stderr) { throw YouTubeResolverError.botCheckBlocked }
            throw YouTubeResolverError.processFailed(stderr.isEmpty ? "exit code \(exitCode)" : stderr)
        }

        var parsedObj: [String: Any]?
        for line in stdout.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["formats"] != nil || obj["url"] != nil {
                parsedObj = obj
                break
            }
        }
        if parsedObj == nil, let data = stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsedObj = obj
        }

        guard let obj = parsedObj else {
            logger.error("yt-dlp JSON parsing failed. Output: \(stdout.prefix(300))")
            throw YouTubeResolverError.malformedOutput
        }
        return try Self.videoInfo(from: obj)
    }

    /// Turns yt-dlp's `--dump-json` object into what the picker offers.
    /// Separate from `listFormats` so it can be tested against saved output.
    static func videoInfo(from obj: [String: Any]) throws -> YouTubeVideoInfo {
        let title = (obj["title"] as? String) ?? "video"
        let durationSeconds = obj["duration"] as? Double
        // yt-dlp reports a single best "thumbnail" alongside the full
        // "thumbnails" ladder; the former is enough for a small preview and
        // avoids picking from the ladder ourselves.
        let thumbnailURL = (obj["thumbnail"] as? String).flatMap(URL.init(string:))
        let topHeaders = obj["http_headers"] as? [String: String] ?? [:]

        guard let formatsArray = obj["formats"] as? [[String: Any]] else {
            throw YouTubeResolverError.noPlayableFormat
        }

        // Videos with dubbed audio carry one copy of each audio format per
        // language, all at the same bitrate and container.
        let audioLanguages = Set(formatsArray.compactMap { f -> String? in
            guard (f["vcodec"] as? String ?? "none") == "none",
                  (f["acodec"] as? String ?? "none") != "none" else { return nil }
            return f["language"] as? String
        })
        let isMultiLanguage = audioLanguages.count > 1
        // On a dubbed video the audio-only rows are listed once, in the
        // original's language, and the Audio picker supplies the language —
        // otherwise every quality repeats once per dub.
        let originalLanguage = formatsArray.first { f in
            (f["vcodec"] as? String ?? "none") == "none" && Self.isOriginalAudio(f)
        }?["language"] as? String
        let rowLanguage = isMultiLanguage ? (originalLanguage ?? audioLanguages.sorted().first) : nil

        var options: [YouTubeFormatOption] = []
        // Whether this video has any audio-only track at all — the yes/no
        // behind `audioMergeAvailable`.
        var anyAudioOnlyFormatExists = false
        // Every audio-only format, in every language, with the fields
        // `pickMergeAudio` ranks on.
        var audioCandidates: [AudioCandidate] = []

        for f in formatsArray {
            guard let urlString = f["url"] as? String, let rawURL = URL(string: urlString) else { continue }
            // Only plain-HTTP formats are offered.
            //
            // An allowlist rather than a "skip m3u8" rule, because the things
            // worth excluding are not one family:
            //
            // - **Streaming (`m3u8`) formats.** yt-dlp downloads these with
            //   its native HLS downloader and stitches the fragments into an
            //   mp4 that AVFoundation then refuses to open ("Cannot Open"),
            //   so `MediaMuxer` cannot merge them and the download stops
            //   partway to ask for ffmpeg. They are also pure duplication:
            //   measured across four videos, every height they offer is also
            //   offered over https, and https goes higher — there was no
            //   height anywhere that only a streaming format could reach.
            // - **Storyboards (`mhtml`).** Sheets of thumbnail images. They
            //   declare a `vcodec` of "images", so the hasVideo test below
            //   counts them as video and they were being listed as
            //   downloadable qualities at 27p, 45p, 90p and 180p.
            //
            // Safe as an allowlist because `listFormats` is only ever called
            // for a YouTube URL (NewDownloadView gates on isSingleYouTubeURL),
            // where https is what every real format uses.
            let proto = (f["protocol"] as? String)?.lowercased() ?? ""
            guard proto == "https" || proto == "http" else { continue }

            // WebM is not offered either, for the same reason and one more.
            //
            // AVFoundation cannot read it, so `MediaMuxer` cannot merge a
            // WebM video track and the download would stop partway to ask for
            // ffmpeg — and a merged WebM would not play in QuickTime or Finder
            // Preview anyway, which is why the sort below already ranked it
            // last.
            //
            // It also did not win on size in any case measured. YouTube
            // publishes VP9-in-WebM
            // alongside AV1-in-MP4 at the same heights, and across one full
            // ladder the AV1 was smaller at every rung — 96.9 MB of VP9
            // against 75.1 MB of AV1 at 1080p60, and the same ordering down
            // to 144p. Checked across five videos, every
            // height offered in WebM is also offered in MP4, so nothing is
            // lost: `heights lost if webm dropped: none`, every time.
            //
            // Audio too, not just video: m4a was present on all five, so
            // dropping Opus-in-WebM costs no track and avoids handing someone
            // an audio file macOS refuses to play.
            guard !Self.isWebMContainer(f["ext"] as? String) else { continue }
            // googlevideo.com throttles any URL lacking `ratebypass=yes` to
            // ~500 kbps total — shared across connections, so parallel
            // segments don't help. yt-dlp appends it in most configs, but
            // some extractor-args combinations (PO-Token flow in particular)
            // skip it; append defensively so a download that resolved through
            // a path that didn't add it still saturates the link. Idempotent.
            let mediaURL = Self.bypassGooglevideoThrottle(rawURL)
            guard let formatId = f["format_id"] as? String else { continue }

            let vcodec = f["vcodec"] as? String
            let acodec = f["acodec"] as? String
            let hasVideo = vcodec != nil && vcodec != "none"
            let hasAudio = acodec != nil && acodec != "none"
            guard hasVideo || hasAudio else { continue }

            let ext = (f["ext"] as? String) ?? "mp4"
            let filesize = (f["filesize"] as? NSNumber)?.int64Value ?? (f["filesize_approx"] as? NSNumber)?.int64Value
            let height = (f["height"] as? NSNumber)?.intValue
            let fps = (f["fps"] as? NSNumber)?.intValue
            let note = f["format_note"] as? String
            let headers = Self.ensureYouTubeCDNHeaders(
                (f["http_headers"] as? [String: String]) ?? topHeaders,
                for: mediaURL
            )

            // YouTube's own name for the rung ("2160p60 HDR"), exactly as its
            // player's quality menu shows it; YouTube works it out for every
            // shape. The pixel height is only a fallback: a 3840×2026 video is
            // 2160p there, not 2026p.
            let rung = (note?.isEmpty == false ? note : nil)
                ?? height.map { "\($0)p" + ((fps ?? 0) > 30 ? "\(fps!)" : "") }
                ?? formatId

            let label: String
            if hasVideo && hasAudio {
                label = "\(rung) · \(ext)"
            } else if hasVideo {
                var suffix = ext
                if let codec = Self.friendlyVideoCodec(vcodec) { suffix += " " + codec }
                label = "\(rung) · \(suffix)"
            } else {
                let abr = (f["abr"] as? NSNumber)?.intValue
                let rate = abr.map { " (\($0)kbps)" } ?? ""
                label = "Audio · \(ext)\(rate)"
            }

            let language = f["language"] as? String
            if hasAudio && !hasVideo {
                anyAudioOnlyFormatExists = true
                audioCandidates.append(AudioCandidate(
                    id: formatId,
                    ext: ext.lowercased(),
                    abr: (f["abr"] as? NSNumber)?.doubleValue ?? 0,
                    bytes: filesize,
                    isOriginal: Self.isOriginalAudio(f),
                    language: isMultiLanguage ? language : nil
                ))
                if isMultiLanguage && language != rowLanguage { continue }
            }

            let option = YouTubeFormatOption(
                id: formatId, label: label, url: mediaURL, headers: headers,
                ext: ext, filesizeBytes: filesize, height: height, hasVideo: hasVideo, hasAudio: hasAudio,
                audioMergeAvailable: false
            )
            options.append(option)
        }

        // yt-dlp can report the exact same underlying stream more than once
        // when it queries multiple internal player clients (web/ios/android
        // /tv) - each client's response becomes its own formats-array entry
        // with a different format_id, but the same height/ext/codec, and
        // often the same size. Left alone these render as visually
        // duplicate rows with nothing to tell them apart. Collapse rows with
        // the same label down to one representative, preferring whichever
        // actually reports a filesize. The label, not height/ext/codec: it
        // carries YouTube's rung name, so "1080p60 HDR" and "1080p60" of the
        // same codec stay two choices. A pair whose
        // sizes differ by more than ~5% is kept as two rows instead - that's
        // a real difference (a genuinely distinct bitrate variant), not a
        // client-response duplicate, and dropping it would throw away a
        // real, differently-sized download option.
        var dedupedOptions: [YouTubeFormatOption] = []
        var indexForKey: [String: Int] = [:]
        for option in options {
            // Audio-only rows used to skip this pass entirely, which is why a
            // single video could list the same track six times: YouTube
            // returns it from several internal player clients, and adds `-drc`
            // variants (the same audio, quieter). Each is a distinct
            // format_id, so nothing collapsed them — but the label carries
            // only container and bitrate, so all six rendered as the identical
            // string "Audio · m4a (129kbps) — 10.3 MB", with no way to tell
            // them apart and no reason to want to.
            //
            // Keying on the label is the literal statement of the rule: rows
            // that render identically collapse to one. The
            // size-differs-by-5% escape below still applies, so two tracks
            // that really are different sizes stay as two rows.
            let key = option.label
            if let idx = indexForKey[key] {
                let existing = dedupedOptions[idx]
                switch (existing.filesizeBytes, option.filesizeBytes) {
                case (nil, .some):
                    dedupedOptions[idx] = option
                case let (.some(e), .some(n)) where abs(Double(e - n)) / Double(max(e, 1)) > 0.05:
                    dedupedOptions.append(option)
                    indexForKey[key] = dedupedOptions.count - 1
                default:
                    break
                }
            } else {
                dedupedOptions.append(option)
                indexForKey[key] = dedupedOptions.count - 1
            }
        }
        options = dedupedOptions

        // Flag every video-only option once the full list is known, so the
        // picker can say whether picking it gets an audio track merged in.
        options = options.map { option in
            guard option.hasVideo && !option.hasAudio, anyAudioOnlyFormatExists else { return option }
            return YouTubeFormatOption(
                id: option.id, label: option.label + " (+ audio)", url: option.url, headers: option.headers,
                ext: option.ext, filesizeBytes: option.filesizeBytes, height: option.height,
                hasVideo: option.hasVideo, hasAudio: option.hasAudio, audioMergeAvailable: true
            )
        }

        // Combined (video+audio, plays standalone) formats first, best
        // quality first; then video-only paired with audio (real quality,
        // via local muxing); audio-only last.
        //
        // At equal resolution, MP4-family wins over WebM. YouTube usually
        // offers the same height in both (e.g. itag 137 mp4/avc1 alongside itag
        // 248 webm/vp9), and macOS cannot open a .webm through AVFoundation at
        // all — QuickTime and Finder Preview both refuse it regardless of which
        // audio got muxed in. Ordering MP4 first means the default selection,
        // and the obvious pick at any given resolution, lands on a file that
        // actually opens. WebM entries are still offered, just not preferred.
        options.sort { a, b in
            let aCombined = a.hasVideo && a.hasAudio
            let bCombined = b.hasVideo && b.hasAudio
            if aCombined != bCombined { return aCombined && !bCombined }
            if a.hasVideo != b.hasVideo { return a.hasVideo && !b.hasVideo }
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) > (b.height ?? 0) }
            let aNative = Self.isAppleNativeContainer(a.ext)
            let bNative = Self.isAppleNativeContainer(b.ext)
            if aNative != bNative { return aNative && !bNative }
            return (a.filesizeBytes ?? 0) > (b.filesizeBytes ?? 0)
        }

        // From the candidates rather than `audioLanguages`: a language offered
        // only in WebM cannot be merged, so it is not a choice.
        let trackLanguages = Set(audioCandidates.compactMap(\.language))
        let audioTracks = trackLanguages.count > 1 ? trackLanguages.map { code in
            YouTubeAudioTrack(
                language: code,
                name: Locale.current.localizedString(forIdentifier: code) ?? code,
                isOriginal: code == originalLanguage
            )
        }.sorted { a, b in
            if a.isOriginal != b.isOriginal { return a.isOriginal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        } : []

        return YouTubeVideoInfo(
            title: title,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            options: options,
            audioTracks: audioTracks,
            audioCandidates: audioCandidates
        )
    }

    /// Tallest video, not `options.first`: the sort below puts combined
    /// formats first, so "first" was itag 18 (360p) on a video offering 4K.
    /// Equal heights keep the sort's order — MP4 over WebM.
    public static func defaultFormatID(from options: [YouTubeFormatOption]) -> String? {
        let videoOptions = options.filter(\.hasVideo)
        guard !videoOptions.isEmpty else { return options.first?.id }
        let tallest = videoOptions.map { $0.height ?? 0 }.max() ?? 0
        return videoOptions.first { ($0.height ?? 0) == tallest }?.id
    }

    /// Chooses the audio track to merge into a video-only pick.
    ///
    /// AAC (`m4a`) first, at the highest bitrate offered, and only then
    /// anything else — see `MergeAudio` for why that order is the whole
    /// point rather than a preference.
    ///
    /// `-drc` variants are skipped when a plain one exists. Those are
    /// dynamic-range-compressed alternates YouTube offers alongside the
    /// normal track; they are the same content quieter, and picking one by
    /// accident because it sorted first would quietly flatten the audio.
    static func pickMergeAudio(from candidates: [AudioCandidate], language: String? = nil) -> MergeAudio? {
        let inLanguage = language.map { lang in candidates.filter { $0.language == lang } } ?? candidates
        guard !inLanguage.isEmpty else { return nil }

        let plain = inLanguage.filter { !$0.id.hasSuffix("-drc") }
        let pool = plain.isEmpty ? inLanguage : plain

        // Language outranks everything, and it has to.
        //
        // A video with dubbed audio carries one track per language. YouTube
        // encodes the dubs at a hair *above* the original — measured on a
        // 24-language video, every dub at 129.478 kbps against the original's
        // 129.475 — so ranking on bitrate first hands back a Marathi or
        // Spanish track for an English video. yt-dlp's own `bestaudio`, which
        // naming a format by id replaced, sorts language third, above
        // quality and bitrate, which is why this never used to happen.
        //
        // If nothing is flagged original (single-language videos flag
        // nothing) every candidate ties here and the container and bitrate
        // rules decide, exactly as before.
        let best = pool.max { a, b in
            if a.isOriginal != b.isOriginal { return !a.isOriginal && b.isOriginal }
            let aNative = Self.isAppleNativeContainer(a.ext)
            let bNative = Self.isAppleNativeContainer(b.ext)
            if aNative != bNative { return !aNative && bNative }
            return a.abr < b.abr
        }
        guard let best else { return nil }
        return MergeAudio(
            formatID: best.id, ext: best.ext, filesizeBytes: best.bytes,
            selector: audioSelector(formatID: best.id, language: language)
        )
    }

    /// An audio-only format as `listFormats` saw it.
    struct AudioCandidate: Sendable, Equatable {
        let id: String
        let ext: String
        let abr: Double
        let bytes: Int64?
        let isOriginal: Bool
        /// Set only on a video with more than one language.
        let language: String?
    }

    /// What yt-dlp is asked for to get `formatID`'s track in `language`.
    ///
    /// By language on a dubbed video, not by id: yt-dlp numbers each
    /// language's copy of an itag ("140-17" Hindi, "140-23" English), and a
    /// paused download re-runs yt-dlp with this string, possibly days later.
    /// The numbering held across runs and player clients when measured, but
    /// nothing promises it; the language is what was chosen. Single-language
    /// videos use plain itags ("140") and keep them.
    ///
    /// A language that has since gone yields no file rather than a different
    /// language — `YouTubeDownloader` reports that as a failure.
    public static func audioSelector(formatID: String, language: String?) -> String {
        guard let language else { return formatID }
        let itag = formatID.split(separator: "-").first.map(String.init) ?? formatID
        return "\(languageSelectorPrefix)\(itag)-][language=\(language)]"
    }

    private static let languageSelectorPrefix = "ba[format_id^="

    /// Whether the file yt-dlp wrote as `<format id>.<ext>` is the one
    /// `selector` — a plain id, or an `audioSelector` — asked for.
    static func fileStem(_ stem: String, satisfies selector: String) -> Bool {
        guard selector.hasPrefix(languageSelectorPrefix),
              let end = selector.firstIndex(of: "]") else { return stem == selector }
        return stem.hasPrefix(selector[selector.index(selector.startIndex, offsetBy: languageSelectorPrefix.count)..<end])
    }

    /// The Settings preference when this video has that dub, else the original.
    public static func defaultAudioLanguage(in tracks: [YouTubeAudioTrack], preferred: String) -> String? {
        tracks.first { AudioLanguage.matches($0.language, preferred: preferred) }?.language
            ?? tracks.first(where: \.isOriginal)?.language
            ?? tracks.first?.language
    }

    /// Whether yt-dlp's complaint is YouTube demanding proof of a human.
    ///
    /// Matched on yt-dlp's wording rather than an exit code, because the exit
    /// code is the same 1 it uses for everything. "Only images are available"
    /// belongs here too: that is what a SABR-enforced client returns when it
    /// declines to serve media, and it reads as a format problem rather than
    /// a refusal.
    static func looksLikeBotCheck(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("sign in to confirm")
            || lower.contains("not a bot")
            || lower.contains("confirm you\u{2019}re not a bot")
            || lower.contains("only images are available")
    }

    /// Whether this format is the video's own audio rather than a dub.
    ///
    /// yt-dlp marks the original track with a `language_preference` of 10 and
    /// leaves dubs at -1. Single-language videos flag nothing, so "not
    /// original" is never taken to mean "dubbed" — only "no reason to prefer
    /// it over any other".
    static func isOriginalAudio(_ format: [String: Any]) -> Bool {
        ((format["language_preference"] as? NSNumber)?.intValue ?? -1) >= 10
    }

    /// Containers macOS can open through AVFoundation (QuickTime, Finder
    /// Preview, Quick Look). WebM and its Matroska parent are absent
    /// deliberately — AVFoundation returns "Cannot Open" for them, so a .webm
    /// download is only playable in a third-party player like VLC.
    /// WebM and its Matroska parent — the containers AVFoundation returns
    /// "Cannot Open" for.
    private static func isWebMContainer(_ ext: String?) -> Bool {
        guard let ext = ext?.lowercased() else { return false }
        return ext == "webm" || ext == "mkv" || ext == "mka"
    }

    private static func isAppleNativeContainer(_ ext: String) -> Bool {
        ["mp4", "m4v", "mov", "m4a"].contains(ext.lowercased())
    }

    public func resolve(url: URL, format: String? = nil) async throws -> ResolvedMedia {
        guard FileManager.default.fileExists(atPath: ytdlpPath) else {
            throw YouTubeResolverError.helpersNotInstalled
        }

        await ensurePotProviderRunning()

        var args = ["--dump-json", "--no-warnings"]
        args += HelperLocations.pluginArguments()
        // Not pinned to a player client, unlike the other call sites: this
        // returns one directly-fetchable URL, so it needs a format carrying
        // both streams — itag 18, which the pin removes. Pinned, the spec
        // below fails with "Requested format is not available". Unpinned sees
        // a superset, so any itag the picker offered still re-resolves here.
        if let format = format {
            args += ["-f", format]
        } else {
            args += ["-f", "best[ext=mp4]/best"]
        }
        
        args += HelperLocations.jsRuntimeArguments()
        if FileManager.default.fileExists(atPath: potPath) {
            args += ["--extractor-args", "youtubepot-bgutilhttp:base_url=http://127.0.0.1:4416"]
        }
        args.append(url.absoluteString)

        logger.notice("Resolving \(url.absoluteString) via yt-dlp")
        let (stdout, stderr, exitCode) = try await runWithTimeout(ytdlpPath, args: args, timeoutSeconds: 45)

        guard exitCode == 0 else {
            logger.error("yt-dlp exited \(exitCode): \(stderr)")
            throw YouTubeResolverError.processFailed(stderr.isEmpty ? "exit code \(exitCode)" : stderr)
        }

        var parsedObj: [String: Any]?
        for line in stdout.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["url"] != nil || obj["formats"] != nil {
                parsedObj = obj
                break
            }
        }
        if parsedObj == nil, let data = stdout.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsedObj = obj
        }

        guard let obj = parsedObj else {
            logger.error("yt-dlp JSON parsing failed in resolve. Output: \(stdout.prefix(300))")
            throw YouTubeResolverError.malformedOutput
        }

        guard let urlString = obj["url"] as? String, let rawURL = URL(string: urlString) else {
            throw YouTubeResolverError.noPlayableFormat
        }
        // See bypassGooglevideoThrottle for the full rationale. Without this
        // every parallel Range segment we open is sharing a single ~500 kbps
        // budget, so the user's 100 Mbps link crawls.
        let mediaURL = Self.bypassGooglevideoThrottle(rawURL)

        var headers: [String: String] = [:]
        if let httpHeaders = obj["http_headers"] as? [String: String] {
            headers = httpHeaders
        }
        headers = Self.ensureYouTubeCDNHeaders(headers, for: mediaURL)

        let title = obj["title"] as? String
        let ext = obj["ext"] as? String
        let filename = title.map { "\($0)\(ext.map { ".\($0)" } ?? "")" }

        let filesize = (obj["filesize"] as? NSNumber)?.int64Value
            ?? (obj["filesize_approx"] as? NSNumber)?.int64Value

        return ResolvedMedia(url: mediaURL, headers: headers, suggestedFilename: filename, totalBytes: filesize)
    }

    /// Public entry point to the PO-Token provider bring-up, for
    /// YouTubeDownloader — which drives yt-dlp itself and so needs the same
    /// provider running before it starts, without duplicating the launch and
    /// health-check logic.
    public func ensurePotProviderRunningIfNeeded() async {
        await ensurePotProviderRunning()
    }

    /// Starts the local PO-Token provider if the binary is present and no
    /// working instance is currently running.
    ///
    /// Self-healing rather than one-shot: the old version set a `potStarted`
    /// flag the moment it *attempted* a launch and never looked at it again
    /// for the rest of the app session — so if bgutil-pot died immediately
    /// (e.g. port 4416 already held by another instance — this has happened
    /// in practice, e.g. a manually-launched `bgutil-pot server` left running
    /// from a Terminal debugging session) or crashed partway through, every
    /// subsequent resolve for the rest of the session would either get no
    /// PO-Token at all or point `--extractor-args` at a dead server, with no
    /// way to recover short of relaunching Convoy. Every call here
    /// now actually verifies a live, listening instance exists — ours or
    /// someone else's — before deciding whether to (re)launch.
    private func ensurePotProviderRunning() async {
        guard FileManager.default.fileExists(atPath: potPath) else {
            logger.notice("bgutil-pot not installed — continuing without a PO-Token provider")
            return
        }

        // Something (ours from an earlier call, or an independently-launched
        // instance — e.g. a manual `bgutil-pot server` left running in a
        // Terminal) is already listening on the port. Nothing to do.
        if await isPotServerReachable() { return }

        // Our own previously-launched process is tracked but no longer
        // listening (crashed, or never actually bound the port) — clean up
        // the stale reference before trying again.
        if let stale = potProcess {
            if stale.isRunning { stale.terminate() }
            potProcess = nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: potPath)
        // Bare invocation defaults to one-shot "Script Mode" (generates a
        // single token and exits) — we need the persistent HTTP server that
        // yt-dlp polls on 127.0.0.1:4416, which requires the explicit
        // "server" subcommand. Without this the process either exits
        // immediately or sits idle, and yt-dlp hangs forever waiting for a
        // token response that can never arrive.
        process.arguments = ["server", "--port", "4416"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            potProcess = process
            logger.notice("bgutil-pot started (pid \(process.processIdentifier, privacy: .public))")
            // Give it a moment to bind its port before yt-dlp tries to use
            // it, then actually confirm it worked rather than assuming —
            // a port conflict or crash-on-start exits the child within
            // milliseconds of this, well before yt-dlp would ever notice on
            // its own (it would just silently proceed without a token, or
            // hang waiting on a server that isn't there).
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !process.isRunning {
                logger.error("bgutil-pot exited immediately after launch (likely a port conflict on 4416) — checking if something else is already serving there")
                potProcess = nil
                if await isPotServerReachable() {
                    logger.notice("Port 4416 is already served by another process — proceeding with that instance")
                } else {
                    logger.error("Port 4416 has no reachable PO-Token server — continuing without one")
                }
            }
        } catch {
            logger.error("Failed to start bgutil-pot: \(error.localizedDescription)")
        }
    }

    /// A real connection attempt to the PO-Token server's port, not just a
    /// "did our Process object launch" check — the two can disagree (a
    /// process can start and still fail to bind its port, or exit moments
    /// later) and only the actual socket state tells us whether yt-dlp's
    /// `--extractor-args` pointing at 127.0.0.1:4416 is pointing at
    /// something real.
    private func isPotServerReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:4416/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "GET"
        // Any response at all (even a 404 for a path bgutil-pot doesn't
        // recognize at GET /) proves something is listening and accepting
        // HTTP on that port — that's all this needs to confirm. A thrown
        // error (connection refused, timeout) means nothing's there.
        return (try? await URLSession.cookieless.data(for: request)) != nil
    }

    /// Same as run(), but can never hang forever — if yt-dlp doesn't finish
    /// within the timeout (network stall, a hung token request, etc.) this
    /// kills the process and surfaces a clear timeout error instead of
    /// leaving the task stuck on "Starting" with no explanation.
    ///
    /// Reads stdout/stderr incrementally via readabilityHandler rather than
    /// only after the process exits. Reading only at the end is a classic
    /// Process/Pipe deadlock: macOS pipes have a small fixed buffer (64KB),
    /// and --dump-json output (thumbnails, every format, subtitle metadata)
    /// can exceed that easily. Once full, the child blocks trying to write
    /// more and waits for us to drain it — but if we're waiting for it to
    /// *finish* before reading anything, neither side ever moves. This was
    /// almost certainly why yt-dlp appeared to "hang" even on requests that
    /// would otherwise resolve in under a second.
    private func runWithTimeout(_ executable: String, args: [String], timeoutSeconds: Int) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = DataAccumulator()
        let stderrBuffer = DataAccumulator()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBuffer.append(data) }
        }

        return try await withThrowingTaskGroup(of: (stdout: String, stderr: String, exitCode: Int32).self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        // Drain anything left in the pipe after the readability
                        // handler's last callback but before it was torn down.
                        let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        if !remainingOut.isEmpty { stdoutBuffer.append(remainingOut) }
                        if !remainingErr.isEmpty { stderrBuffer.append(remainingErr) }

                        let stdout = String(data: stdoutBuffer.data, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
                        continuation.resume(returning: (stdout, stderr, proc.terminationStatus))
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if process.isRunning { process.terminate() }
                throw YouTubeResolverError.processFailed("timed out after \(timeoutSeconds)s — yt-dlp never returned")
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Thread-safe byte accumulator for the readabilityHandler callbacks above,
/// which fire on a background dispatch queue outside this actor's isolation.
private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        _data.append(chunk)
    }
}
