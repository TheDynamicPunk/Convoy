import Foundation
import OSLog

// MARK: - DASHSegmentResolver

/// Resolves a DASH MPD document into a flat list of downloadable segment URLs
/// for a specific Representation, identified by `representationId` (preferred)
/// or `bandwidth` (closest match fallback).
///
/// Handles the three segment addressing modes the spec defines:
/// - **SegmentTemplate** with `$Number$` — most common for live/VOD with a
///   regular segment grid.
/// - **SegmentTemplate** with SegmentTimeline — explicit `<S t="" d="" r=""/>
///   entries for irregular segment durations (e.g. ad-splice boundaries).
/// - **SegmentList** — explicit `<SegmentURL media="..."/>` children (less
///   common; mostly found in older DASH content).
/// - **SegmentBase** (single file) — handed back as a single-element list with
///   the resolved BaseURL; caller may route through the existing byte-range engine.
///
/// Deliberately does NOT use `DOMParser`/`XMLDocument` (macOS-only Obj-C
/// classes) — uses Foundation's streaming `XMLParser` instead so this works in
/// the DownloadEngine target without bringing in AppKit.
public struct DASHSegmentResolver {

    private static let logger = Logger(subsystem: "Convoy", category: "DASHSegmentResolver")

    // MARK: - Public output types

    public struct Segment: Sendable {
        public let url: URL
        /// Duration in timescale units (use `timescale` to convert to seconds).
        public let durationTicks: Int64?
        public let timescale: Int64?
    }

    public struct ResolvedStream: Sendable {
        /// Ordered list of segment URLs to download.
        public let segments: [URL]
        /// Initialization segment URL (SegmentTemplate@initialization or
        /// Initialization@sourceURL). Must be downloaded first.
        public let initSegmentURL: URL?
        /// Total presentation duration in seconds (from MPD@mediaPresentationDuration).
        public let totalDuration: Double?
        /// Always `true` for DASH (fMP4 is the only container DASH uses).
        public let isFMP4: Bool
        /// Declared bitrate of the chosen Representation, in bits per second.
        ///
        /// Reported per track rather than left to the caller because video and
        /// audio differ by an order of magnitude: sizing both from one number
        /// makes whichever estimate is derived from it wrong.
        public let bandwidth: Int
    }

    /// What a Representation actually carries. DASH keeps video and audio in
    /// separate Representations far more often than not, so this is the
    /// difference between downloading a film and downloading a silent film.
    public enum TrackKind: Sendable {
        case video
        case audio
        /// Subtitles, thumbnails, event streams — anything that isn't a
        /// downloadable A/V track.
        case other
    }

    /// The tracks needed to produce one playable file.
    public struct ResolvedTracks: Sendable {
        /// The primary track: the chosen video Representation, or — for an
        /// audio-only manifest — the chosen audio one.
        public let video: ResolvedStream
        /// The audio track to merge with `video`, or nil when no merge is needed:
        /// the primary track already carries audio, the manifest declares no
        /// separate audio Representation, or the manifest is audio-only.
        public let audio: ResolvedStream?
        /// Language tag of the chosen audio track, when the manifest declared one.
        public let audioLanguage: String?
    }

    // MARK: - Entry point

    /// Resolves the video and audio tracks needed for one playable file.
    ///
    /// A non-nil `audio` means the two tracks must be merged after downloading —
    /// each is a complete, valid, and individually useless fMP4 file. Callers that
    /// cannot merge should check this *before* transferring anything.
    ///
    /// - representationId: exact ID match for the primary track (preferred — what
    ///   the browser sends when it knows the ID from the parsed manifest).
    /// - bandwidth: closest-match fallback, applied within the video
    ///   Representations only. Matching across the whole pool would let an audio
    ///   Representation win on a low-bitrate video, which is how a "download" ends
    ///   up being sound with no picture.
    /// - preferredAudioLanguage: BCP-47 tag, matched loosely so "en" accepts
    ///   "en-US". Falls back to the manifest's own ordering when absent or unmatched.
    public static func resolveTracks(
        mpdText: String,
        baseURL: URL,
        representationId: String?,
        bandwidth: Int?,
        preferredAudioLanguage: String? = nil
    ) -> ResolvedTracks? {
        guard let mpd = MPDDocument.parse(text: mpdText, baseURL: baseURL) else { return nil }

        // Every Period's Representations are pooled together and exactly one is
        // picked from the pool as the primary track.
        //
        // KNOWN LIMITATION — multi-Period manifests (the usual shape for
        // ad-spliced VOD) are not stitched. Whichever Period the matched
        // Representation happens to live in is the only one whose segments get
        // resolved, so the output covers that Period alone and stops at its
        // boundary. Left as-is deliberately rather than refused, since a partial
        // file is what this has always produced; doing it properly means
        // concatenating across Periods and handling the codec/resolution changes
        // that can occur at each splice. The warning below is so the truncation
        // shows up in a log instead of being entirely invisible.
        let indexedReps: [(period: Int, rep: MPDRepresentation)] = mpd.periods.enumerated()
            .flatMap { periodIdx, period in
                period.adaptationSets.flatMap(\.representations).map { (periodIdx, $0) }
            }
        guard !indexedReps.isEmpty else { return nil }

        let videoReps = indexedReps.filter { kind(of: $0.rep) == .video }
        let audioReps = indexedReps.filter { kind(of: $0.rep) == .audio }

        // Bandwidth matching happens within one kind. Video when the manifest has
        // any; audio for a genuinely audio-only manifest (podcast/radio DASH),
        // where the audio track *is* the download; everything as a last resort
        // when nothing could be classified, which preserves the old behaviour for
        // manifests that declare neither mimeType nor codecs.
        let pool = !videoReps.isEmpty ? videoReps : (!audioReps.isEmpty ? audioReps : indexedReps)

        let target: (period: Int, rep: MPDRepresentation)?
        if let rid = representationId {
            // An exact ID match wins over the pool restriction: if the caller named
            // a specific Representation, that's a decision already made upstream.
            target = indexedReps.first(where: { $0.rep.id == rid })
                ?? closestByBandwidth(pool, to: bandwidth)
        } else {
            target = closestByBandwidth(pool, to: bandwidth)
        }
        guard let (chosenPeriod, rep) = target else { return nil }

        if mpd.periods.count > 1 {
            logger.warning("""
                MPD declares \(mpd.periods.count, privacy: .public) Periods but only \
                Period \(chosenPeriod, privacy: .public) will be downloaded — \
                multi-Period stitching is not implemented, so the file ends at that \
                Period's boundary.
                """)
        }

        let segments = resolveSegments(for: rep, mpdBaseURL: baseURL)
        guard !segments.isEmpty else { return nil }

        let primary = ResolvedStream(
            segments: segments,
            initSegmentURL: rep.initSegmentURL,
            totalDuration: mpd.totalDurationSec,
            isFMP4: true,
            bandwidth: rep.bandwidth
        )

        // A separate audio track is only wanted when the primary really is a
        // video-only track. A muxed Representation (codecs listing both a video
        // and an audio codec) is already complete, and an audio primary would
        // otherwise get a second audio track merged into it.
        guard kind(of: rep) == .video, !carriesAudio(rep) else {
            return ResolvedTracks(video: primary, audio: nil, audioLanguage: nil)
        }

        // Restricted to the chosen Period: merging audio from a different Period
        // would splice unrelated media onto the video.
        let candidates = audioReps.filter { $0.period == chosenPeriod }.map(\.rep)
        guard let audioRep = selectAudio(candidates, preferring: preferredAudioLanguage) else {
            if !candidates.isEmpty {
                logger.warning("Manifest declares audio Representations but none could be selected — output will be silent.")
            }
            return ResolvedTracks(video: primary, audio: nil, audioLanguage: nil)
        }

        let audioSegments = resolveSegments(for: audioRep, mpdBaseURL: baseURL)
        guard !audioSegments.isEmpty else {
            // Proceed video-only rather than failing outright — a silent file is
            // recoverable, and the warning says why it happened.
            logger.warning("""
                Audio Representation \(audioRep.id ?? "<no id>", privacy: .public) resolved to zero \
                segments — continuing with video only, so the output will be silent.
                """)
            return ResolvedTracks(video: primary, audio: nil, audioLanguage: nil)
        }

        logger.notice("""
            Split tracks: video \(rep.id ?? "<no id>", privacy: .public) \
            (\(rep.bandwidth, privacy: .public) bps, \(segments.count, privacy: .public) segs) + \
            audio \(audioRep.id ?? "<no id>", privacy: .public) \
            (\(audioRep.bandwidth, privacy: .public) bps, \(audioSegments.count, privacy: .public) segs, \
            lang=\(audioRep.lang ?? "unset", privacy: .public)) — these must be merged.
            """)

        return ResolvedTracks(
            video: primary,
            audio: ResolvedStream(
                segments: audioSegments,
                initSegmentURL: audioRep.initSegmentURL,
                totalDuration: mpd.totalDurationSec,
                isFMP4: true,
                bandwidth: audioRep.bandwidth
            ),
            audioLanguage: audioRep.lang
        )
    }

    /// Resolves only the primary track.
    ///
    /// Kept for callers that genuinely want a single track and will accept a
    /// silent file. Anything producing a file for a user should call
    /// `resolveTracks` instead — this cannot tell you that audio was left behind.
    public static func resolve(
        mpdText: String,
        baseURL: URL,
        representationId: String?,
        bandwidth: Int?
    ) -> ResolvedStream? {
        resolveTracks(
            mpdText: mpdText, baseURL: baseURL,
            representationId: representationId, bandwidth: bandwidth
        )?.video
    }

    // MARK: - Track classification

    /// Classifies a Representation by mimeType/contentType, falling back to the
    /// codecs string.
    ///
    /// `@mimeType` is the reliable signal and the parser already inherits it from
    /// the AdaptationSet (including `@contentType`, whose values are the bare
    /// "video"/"audio"/"text" — hence prefix matching rather than equality). Some
    /// manifests declare neither on either level but do carry `@codecs`, which is
    /// enough to tell a track apart.
    private static func kind(of rep: MPDRepresentation) -> TrackKind {
        if let mime = rep.mimeType?.lowercased(), !mime.isEmpty {
            if mime.hasPrefix("video") { return .video }
            if mime.hasPrefix("audio") { return .audio }
            if mime.hasPrefix("text") || mime.hasPrefix("application") || mime.hasPrefix("image") {
                return .other
            }
        }
        let codecs = (rep.codecs ?? "").lowercased()
        guard !codecs.isEmpty else { return .other }
        if videoCodecMarkers.contains(where: codecs.contains) { return .video }
        if audioCodecMarkers.contains(where: codecs.contains) { return .audio }
        return .other
    }

    /// True when a video Representation's codecs list also names an audio codec —
    /// a muxed track that needs nothing merged into it. Uncommon in DASH but legal.
    private static func carriesAudio(_ rep: MPDRepresentation) -> Bool {
        let codecs = (rep.codecs ?? "").lowercased()
        guard !codecs.isEmpty else { return false }
        return audioCodecMarkers.contains(where: codecs.contains)
    }

    private static let videoCodecMarkers = [
        "avc1", "avc3", "hev1", "hvc1", "vp8", "vp9", "vp09", "av01", "mp4v", "dvh1", "dvhe",
    ]
    private static let audioCodecMarkers = [
        "mp4a", "ac-3", "ec-3", "ac-4", "opus", "vorbis", "alac", "flac", "dts",
    ]

    // MARK: - Representation selection

    /// Picks one audio Representation from the candidates for a Period.
    ///
    /// Narrows by preference before comparing bitrate, so a requested language
    /// beats a higher-bitrate track in another one. Each step is skipped when it
    /// would eliminate everything, so an unmatched preference degrades to the next
    /// signal rather than to nothing.
    private static func selectAudio(
        _ reps: [MPDRepresentation],
        preferring language: String?
    ) -> MPDRepresentation? {
        guard !reps.isEmpty else { return nil }
        var pool = reps

        if let language, !language.isEmpty {
            let matches = pool.filter { AudioLanguage.matches($0.lang, preferred: language) }
            if !matches.isEmpty { pool = matches }
        }

        // Role@value="main" is how a manifest marks the primary audio among
        // descriptive-audio / commentary alternatives.
        if pool.count > 1 {
            let main = pool.filter(\.roleIsMain)
            if !main.isEmpty { pool = main }
        }

        // Still ambiguous across languages: take the manifest's first-declared
        // one, which is what a player defaults to absent a user preference.
        if pool.count > 1, let firstLang = pool.compactMap(\.lang).first {
            let sameLanguage = pool.filter { $0.lang == nil || $0.lang == firstLang }
            if !sameLanguage.isEmpty { pool = sameLanguage }
        }

        return pool.max(by: { $0.bandwidth < $1.bandwidth })
    }

    private static func closestByBandwidth(
        _ reps: [(period: Int, rep: MPDRepresentation)],
        to bw: Int?
    ) -> (period: Int, rep: MPDRepresentation)? {
        if let bw {
            return reps.min(by: { abs($0.rep.bandwidth - bw) < abs($1.rep.bandwidth - bw) })
        }
        // No bandwidth hint — pick highest quality (largest bandwidth)
        return reps.max(by: { $0.rep.bandwidth < $1.rep.bandwidth })
    }

    // MARK: - Segment resolution

    private static func resolveSegments(for rep: MPDRepresentation, mpdBaseURL: URL) -> [URL] {
        switch rep.segmentMode {

        // ── SegmentList ─────────────────────────────────────────────────────────────
        case .list(let segURLs, _):
            return segURLs

        // ── SegmentTemplate ($Number$ style) ────────────────────────────────────────
        case .templateNumber(let template, let start, let duration, let timescale, let totalDurationSec):
            guard duration > 0, timescale > 0, totalDurationSec > 0 else { return [] }
            let total = Int64(totalDurationSec * Double(timescale))
            let segDur = Int64(duration)
            let count = Int((total + segDur - 1) / segDur)
            return (0..<count).compactMap { i in
                let number = start + i
                let expanded = expandTemplate(template, repId: rep.id, number: number, bandwidth: rep.bandwidth, time: nil)
                return URL(string: expanded, relativeTo: rep.resolvedBaseURL ?? mpdBaseURL)?.absoluteURL
            }


        // ── SegmentTemplate + SegmentTimeline ───────────────────────────────────────
        case .templateTimeline(let mediaTemplate, let entries, _, let startNumber):
            var urls: [URL] = []
            var number = startNumber
            var time: Int64 = 0
            for entry in entries {
                // @t is optional on all but the first <S>; when absent the segment
                // starts where the previous entry's last repeat ended.
                let t = entry.t ?? time
                let repeatCount = entry.r >= 0 ? entry.r : {
                    // r="-1" means "repeat to the end of the timeline". The end is
                    // only knowable from the presentation duration, which the parser
                    // converts into this Representation's own timescale.
                    //
                    // Ceiling division: a timeline whose remaining duration isn't an
                    // exact multiple of the segment length still needs its trailing
                    // fractional segment. E.g. 42 ticks remaining at d=4 needs 11
                    // segments (covering ticks 0–44, the last one shorter than
                    // nominal) — floor division here previously computed 10 and
                    // silently dropped the last 2 ticks of content entirely. Real
                    // encoders routinely produce a final segment shorter than the
                    // rest, so this is the common case, not an edge case.
                    guard entry.d > 0, let totalDur = rep.totalDurationTicks, totalDur > t else { return 0 }
                    let remaining = totalDur - t
                    let segmentCount = (remaining + entry.d - 1) / entry.d
                    return Int(max(0, segmentCount - 1))
                }()
                for i in 0...repeatCount {
                    // Each repeat advances $Time$ by exactly one segment duration.
                    // Holding it constant across the repeats — as this did — yields
                    // N copies of the same URL, so a timeline stream downloaded the
                    // first segment repeatedly instead of the whole thing.
                    let segStart = t + Int64(i) * entry.d
                    let expanded = expandTemplate(mediaTemplate, repId: rep.id, number: number,
                                                  bandwidth: rep.bandwidth, time: segStart)
                    if let url = URL(string: expanded, relativeTo: rep.resolvedBaseURL ?? mpdBaseURL)?.absoluteURL {
                        urls.append(url)
                    }
                    number += 1
                }
                time = t + entry.d * Int64(repeatCount + 1)
            }
            return urls

        // ── SegmentBase / fallback: treat BaseURL as single file ────────────────────
        case .base:
            // Only meaningful if the manifest actually declared a <BaseURL>
            // somewhere in this Representation's ancestor chain. Without one,
            // resolvedBaseURL falls all the way back to the .mpd URL itself, and
            // returning that would hand the downloader the manifest XML to save
            // as the media file.
            guard rep.hasExplicitBaseURL, let url = rep.resolvedBaseURL else { return [] }
            return [url]
        }
    }

    // MARK: - Template expansion

    /// Expands a DASH segment template string, substituting the four
    /// allowed identifiers: `$RepresentationID$`, `$Number$`, `$Bandwidth$`, `$Time$`.
    /// Format suffixes like `$Number%05d$` are also handled.
    ///
    /// Internal (not private) so `MPDXMLParser` — a separate type in the same
    /// module — can call this when expanding init segment URLs from templates.
    internal static func expandTemplate(_ template: String, repId: String?, number: Int, bandwidth: Int, time: Int64?) -> String {
        var result = template
        result = result.replacingOccurrences(of: "$RepresentationID$", with: repId ?? "")
        result = result.replacingOccurrences(of: "$Bandwidth$", with: "\(bandwidth)")

        // Number with optional format
        result = replaceWithFormat(result, key: "Number", value: Int64(number))
        // Time with optional format
        if let t = time {
            result = replaceWithFormat(result, key: "Time", value: t)
        }
        result = result.replacingOccurrences(of: "$$", with: "$")
        return result
    }

    private static func replaceWithFormat(_ s: String, key: String, value: Int64) -> String {
        var result = s
        // Match $Key%formatSpec$ (e.g. $Number%05d$) or plain $Key$
        let pattern = "\\$\(key)(?:%([^$]+))?\\$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(result.startIndex..., in: result)
        let matches = regex.matches(in: result, range: range).reversed()
        for match in matches {
            let fullRange = Range(match.range, in: result)!
            if match.numberOfRanges > 1, let fmtRange = Range(match.range(at: 1), in: result) {
                let fmt = "%" + result[fmtRange]
                result.replaceSubrange(fullRange, with: String(format: fmt, value))
            } else {
                result.replaceSubrange(fullRange, with: "\(value)")
            }
        }
        return result
    }
}

// MARK: - Internal MPD document model

/// Internal representation of the parsed MPD — not exposed publicly.
private struct MPDDocument {
    let periods: [MPDPeriod]
    let totalDurationSec: Double?

    static func parse(text: String, baseURL: URL) -> MPDDocument? {
        let parser = MPDXMLParser(text: text, baseURL: baseURL)
        return parser.parse()
    }
}

private struct MPDPeriod {
    let adaptationSets: [MPDAdaptationSet]
}

private struct MPDAdaptationSet {
    let representations: [MPDRepresentation]
}

enum MPDSegmentMode {
    case list(segments: [URL], initURL: URL?)
    /// `totalDurationSec` is the presentation duration in **seconds** — the
    /// resolver multiplies it by `timescale` itself. (It was previously labelled
    /// `totalDurationTicks` while still being handed seconds, which read as a
    /// unit bug in the arithmetic that consumes it.)
    case templateNumber(mediaTemplate: String, startNumber: Int, duration: Int64, timescale: Int64, totalDurationSec: Double)
    case templateTimeline(mediaTemplate: String, entries: [TimelineEntry], initTemplate: String?, startNumber: Int)
    case base
}

struct TimelineEntry {
    var t: Int64?   // absolute start time in timescale ticks (optional)
    var d: Int64    // duration in ticks
    var r: Int      // repeat count; -1 means "to end of timeline"
}

private struct MPDRepresentation {
    let id: String?
    let bandwidth: Int
    let mimeType: String?
    let codecs: String?
    var resolvedBaseURL: URL?
    var initSegmentURL: URL?
    var segmentMode: MPDSegmentMode
    /// Presentation duration expressed in *this* Representation's timescale
    /// ticks. Only used to expand a SegmentTimeline `r="-1"` ("repeat to the end
    /// of the timeline"), which is unresolvable without it.
    var totalDurationTicks: Int64?
    /// True when a `<BaseURL>` element was actually present at MPD, Period,
    /// AdaptationSet or Representation level. `resolvedBaseURL` is never nil —
    /// it falls back to the manifest's own URL — so this is the only way to tell
    /// a real media BaseURL from that fallback.
    var hasExplicitBaseURL: Bool
    /// BCP-47 language tag from AdaptationSet@lang, used to choose between
    /// alternative audio tracks. nil on single-language manifests.
    var lang: String?
    /// True when the owning AdaptationSet carries `<Role value="main"/>` — how a
    /// manifest distinguishes the primary audio from commentary or
    /// descriptive-audio alternatives.
    var roleIsMain: Bool
}

// MARK: - MPD XML Parser (Foundation XMLParser delegate)

/// Walks the MPD XML tree using Foundation's event-driven SAX parser, which
/// works in every Swift target (no DOMParser / NSXMLDocument dependency).
private final class MPDXMLParser: NSObject, XMLParserDelegate {
    private let text: String
    private let baseURL: URL
    private var result: MPDDocument?

    // ── Parse state ─────────────────────────────────────────────────────────────
    private var mpdDuration: Double?
    /// Period@duration for the Period currently being walked. A static
    /// (VOD) manifest is allowed to carry its duration here instead of on
    /// MPD@mediaPresentationDuration, and some do.
    private var periodDuration: Double?
    /// First Period@duration seen, used as the document-level duration when
    /// MPD@mediaPresentationDuration is absent.
    private var firstPeriodDuration: Double?
    private var mpdBaseURL: URL
    private var periodBaseURL: URL
    private var asetBaseURL: URL
    private var repBaseURL: URL?

    /// Whether a `<BaseURL>` element was actually seen at each level. These
    /// mirror the four URL vars above and inherit the same way (Period from MPD,
    /// AdaptationSet from Period, Representation from AdaptationSet), because the
    /// URLs alone can't answer "was one declared?" — they're pre-seeded with the
    /// manifest URL so that relative segment templates resolve.
    private var mpdHasBase = false
    private var periodHasBase = false
    private var asetHasBase = false
    private var repHasBase = false

    /// Accumulates `<BaseURL>` text across callbacks. XMLParser is free to
    /// deliver one text node in several `foundCharacters` calls — it splits on
    /// entity references and on its own internal buffer boundaries — so the value
    /// is only complete once the element closes. Resolving per-callback silently
    /// truncates any URL long enough to straddle a boundary.
    private var baseURLBuffer = ""

    private var periods: [MPDPeriod] = []
    private var currentAsets: [MPDAdaptationSet] = []
    private var currentReps: [MPDRepresentation] = []

    // Working Representation fields
    private var curId: String?
    private var curBandwidth = 0
    private var curMimeType: String?
    private var curCodecs: String?
    private var curLang: String?
    private var curRoleMain = false
    private var curInitURL: URL?
    private var curSegmentMode: MPDSegmentMode = .base
    private var curTotalDurationTicks: Int64?

    // SegmentTemplate fields
    private var stMediaTemplate: String?
    private var stInitTemplate: String?
    private var stStartNumber = 1
    private var stDuration: Int64 = 0
    private var stTimescale: Int64 = 1
    private var stTimeline: [TimelineEntry] = []
    private var hasTimeline = false

    // SegmentList fields
    private var slInitURL: URL?
    private var slSegmentURLs: [URL] = []

    // AdaptationSet shared fields (inherited by Representations)
    private var asetMimeType: String?
    private var asetLang: String?
    private var asetRoleMain = false
    private var asetTimescale: Int64 = 1
    private var asetSTMedia: String?
    private var asetSTInit: String?
    private var asetSTDuration: Int64 = 0
    private var asetSTStartNumber = 1

    private var elementStack: [String] = []

    init(text: String, baseURL: URL) {
        self.text = text
        self.baseURL = baseURL
        self.mpdBaseURL = baseURL
        self.periodBaseURL = baseURL
        self.asetBaseURL = baseURL
    }

    func parse() -> MPDDocument? {
        guard let data = text.data(using: .utf8) else { return nil }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return result
    }

    // ── XMLParserDelegate ────────────────────────────────────────────────────────

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let name = localName(elementName)
        elementStack.append(name)

        switch name {
        case "MPD":
            if let dur = attributes["mediaPresentationDuration"] {
                mpdDuration = parseISO8601Duration(dur)
            }

        case "BaseURL":
            // Text content is accumulated in foundCharacters and resolved in
            // didEndElement, once the whole value is known.
            baseURLBuffer = ""

        case "Period":
            currentAsets = []
            periodBaseURL = mpdBaseURL
            periodHasBase = mpdHasBase
            periodDuration = attributes["duration"].flatMap { parseISO8601Duration($0) }
            if firstPeriodDuration == nil { firstPeriodDuration = periodDuration }

        case "AdaptationSet":
            currentReps = []
            asetBaseURL = periodBaseURL
            asetHasBase = periodHasBase
            asetMimeType = attributes["mimeType"] ?? attributes["contentType"]
            asetLang = attributes["lang"]
            asetRoleMain = false
            asetTimescale = Int64(attributes["timescale"] ?? "") ?? 1
            asetSTMedia = nil; asetSTInit = nil
            asetSTDuration = 0; asetSTStartNumber = 1

        case "Role":
            // <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>. Only the
            // AdaptationSet-level one matters here; the scheme is not checked
            // because "main" is unambiguous across the schemes in the wild.
            if inAdaptationSet(), attributes["value"]?.lowercased() == "main" {
                asetRoleMain = true
            }

        case "Representation":
            curId = attributes["id"]
            curBandwidth = Int(attributes["bandwidth"] ?? "") ?? 0
            curMimeType = attributes["mimeType"] ?? asetMimeType
            curCodecs = attributes["codecs"]
            curLang = attributes["lang"] ?? asetLang
            curRoleMain = asetRoleMain
            curInitURL = nil
            curSegmentMode = .base
            curTotalDurationTicks = nil
            repBaseURL = nil
            repHasBase = asetHasBase
            stMediaTemplate = asetSTMedia
            stInitTemplate = asetSTInit
            stDuration = asetSTDuration
            stTimescale = asetTimescale
            stStartNumber = asetSTStartNumber
            stTimeline = []
            hasTimeline = false
            slSegmentURLs = []
            slInitURL = nil

        case "SegmentTemplate":
            let template = attributes["media"] ?? ""
            let initTmpl = attributes["initialization"]
            let dur = Int64(attributes["duration"] ?? "") ?? 0
            let ts = Int64(attributes["timescale"] ?? "") ?? 1
            let start = Int(attributes["startNumber"] ?? "") ?? 1
            if inRepresentation() {
                if !template.isEmpty { stMediaTemplate = template }
                if let i = initTmpl { stInitTemplate = i }
                if dur > 0 { stDuration = dur }
                if ts > 0 { stTimescale = ts }
                stStartNumber = start
            } else if inAdaptationSet() {
                if !template.isEmpty { asetSTMedia = template }
                if let i = initTmpl { asetSTInit = i }
                if dur > 0 { asetSTDuration = dur }
                if ts > 0 { asetTimescale = ts }
                asetSTStartNumber = start
            }

        case "SegmentTimeline":
            hasTimeline = true
            stTimeline = []

        case "S":
            if hasTimeline {
                let t = attributes["t"].flatMap { Int64($0) }
                let d = Int64(attributes["d"] ?? "") ?? 0
                let r = Int(attributes["r"] ?? "") ?? 0
                stTimeline.append(TimelineEntry(t: t, d: d, r: r))
            }

        case "SegmentList":
            // Only override when the attribute is actually present. Assigning the
            // `?? 1` default unconditionally would reset a timescale already
            // inherited from an enclosing SegmentTemplate/AdaptationSet.
            if let tsAttr = attributes["timescale"], let ts = Int64(tsAttr), ts > 0 {
                stTimescale = ts
            }

        case "SegmentURL":
            if let mediaAttr = attributes["media"],
               let url = URL(string: mediaAttr, relativeTo: repBaseURL ?? asetBaseURL)?.absoluteURL {
                slSegmentURLs.append(url)
            }

        case "Initialization":
            let src = attributes["sourceURL"] ?? attributes["source"] ?? ""
            let base = repBaseURL ?? asetBaseURL
            if !src.isEmpty, let url = URL(string: src, relativeTo: base)?.absoluteURL {
                curInitURL = url
                slInitURL = url
            }

        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Accumulate only — see baseURLBuffer. Nothing is resolved until the
        // element closes, since this can fire several times for one text node.
        guard elementStack.last == "BaseURL" else { return }
        baseURLBuffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = localName(elementName)
        defer { if elementStack.last == name { elementStack.removeLast() } }

        switch name {
        case "BaseURL":
            let trimmed = baseURLBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            baseURLBuffer = ""
            guard !trimmed.isEmpty else { break }
            // elementStack still has "BaseURL" on top at this point — the defer
            // above pops it only after this switch — so the owning element is the
            // one directly beneath it.
            let owner = elementStack.dropLast().last ?? ""
            let parentBase: URL
            switch owner {
            case "MPD": parentBase = baseURL
            case "Period": parentBase = mpdBaseURL
            case "AdaptationSet": parentBase = periodBaseURL
            case "Representation": parentBase = asetBaseURL
            default: parentBase = baseURL
            }
            guard let resolved = URL(string: trimmed, relativeTo: parentBase)?.absoluteURL else { break }
            switch owner {
            case "MPD": mpdBaseURL = resolved; mpdHasBase = true
            case "Period": periodBaseURL = resolved; periodHasBase = true
            case "AdaptationSet": asetBaseURL = resolved; asetHasBase = true
            case "Representation": repBaseURL = resolved; repHasBase = true
            default: break
            }

        case "Period":
            if !currentAsets.isEmpty {
                periods.append(MPDPeriod(adaptationSets: currentAsets))
            }
            currentAsets = []

        case "AdaptationSet":
            if !currentReps.isEmpty {
                currentAsets.append(MPDAdaptationSet(representations: currentReps))
            }
            currentReps = []

        case "Representation":
            let base = repBaseURL ?? asetBaseURL
            // Resolve init segment URL from template if not set by Initialization element
            var initURL = curInitURL
            if initURL == nil, let tmpl = stInitTemplate, !tmpl.isEmpty {
                let expanded = DASHSegmentResolver.expandTemplate(tmpl, repId: curId, number: stStartNumber, bandwidth: curBandwidth, time: nil)
                initURL = URL(string: expanded, relativeTo: base)?.absoluteURL
            }

            // Presentation duration converted into this Representation's own
            // timescale. Computed here, at the close tag, because stTimescale is
            // only final now — a Representation-level <SegmentTemplate> is allowed
            // to override the AdaptationSet's, and does so after the open tag.
            //
            // Without this, SegmentTimeline `r="-1"` has no end to count towards
            // and collapses to a single segment, so a stream that describes itself
            // as "one 4s segment, repeated to the end" downloads exactly 4 seconds.
            let durationSec = mpdDuration ?? periodDuration
            if let durationSec, durationSec > 0, stTimescale > 0 {
                curTotalDurationTicks = Int64(durationSec * Double(stTimescale))
            }

            let mode: MPDSegmentMode
            if !slSegmentURLs.isEmpty {
                mode = .list(segments: slSegmentURLs, initURL: slInitURL ?? curInitURL)
            } else if let mediaTemplate = stMediaTemplate, !mediaTemplate.isEmpty {
                if hasTimeline {
                    mode = .templateTimeline(mediaTemplate: mediaTemplate, entries: stTimeline,
                                             initTemplate: stInitTemplate, startNumber: stStartNumber)
                } else if stDuration > 0 {
                    mode = .templateNumber(mediaTemplate: mediaTemplate, startNumber: stStartNumber,
                                           duration: stDuration, timescale: stTimescale,
                                           totalDurationSec: durationSec ?? 0)
                } else {
                    mode = .base
                }
            } else {
                mode = .base
            }

            let rep = MPDRepresentation(
                id: curId, bandwidth: curBandwidth,
                mimeType: curMimeType, codecs: curCodecs,
                resolvedBaseURL: repBaseURL ?? asetBaseURL,
                initSegmentURL: initURL,
                segmentMode: mode,
                totalDurationTicks: curTotalDurationTicks,
                hasExplicitBaseURL: repHasBase,
                lang: curLang,
                roleIsMain: curRoleMain
            )
            currentReps.append(rep)


        case "MPD":
            result = MPDDocument(periods: periods, totalDurationSec: mpdDuration ?? firstPeriodDuration)

        default: break
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────────

    private func localName(_ name: String) -> String {
        // Strip XML namespace prefix (e.g. "dash:Representation" → "Representation")
        if let colonIndex = name.firstIndex(of: ":") {
            return String(name[name.index(after: colonIndex)...])
        }
        return name
    }

    private func inRepresentation() -> Bool { elementStack.contains("Representation") }
    private func inAdaptationSet() -> Bool { elementStack.contains("AdaptationSet") && !inRepresentation() }

    /// Parses ISO 8601 duration strings like "PT1H2M3.5S" to seconds.
    private func parseISO8601Duration(_ raw: String) -> Double? {
        let pattern = #"^-?P(?:(\d+(?:\.\d+)?)Y)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)W)?(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func g(_ i: Int) -> Double {
            guard let r = Range(match.range(at: i), in: raw) else { return 0 }
            return Double(raw[r]) ?? 0
        }
        let secs = g(1) * 31_556_952 + g(2) * 2_629_746 + g(3) * 604_800 + g(4) * 86_400
                 + g(5) * 3_600 + g(6) * 60 + g(7)
        return secs > 0 ? secs : nil
    }
}


