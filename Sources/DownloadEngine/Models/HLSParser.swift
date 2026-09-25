import Foundation

// MARK: - HLSAudioCandidate

/// One entry from an HLS master playlist's #EXT-X-MEDIA:TYPE=AUDIO group —
/// resolved and sent by the browser extension (see parseHlsManifest in
/// background.js), never reconstructed on this side. The Swift layer only
/// ever sees the ONE media playlist URL for the video variant the person
/// picked, never the master, so it has no way to rediscover which audio
/// renditions exist or which group this variant referenced — that
/// association only exists in the master playlist the extension already
/// parsed client-side.
public struct HLSAudioCandidate: Sendable, Codable, Equatable {
    public let url: URL
    /// BCP-47-ish language tag from the #EXT-X-MEDIA LANGUAGE attribute, or
    /// nil when the rendition didn't declare one.
    public let lang: String?
    /// From the #EXT-X-MEDIA DEFAULT attribute — the rendition a player
    /// would pick with no language preference of its own.
    public let isDefault: Bool

    public init(url: URL, lang: String?, isDefault: Bool) {
        self.url = url
        self.lang = lang
        self.isDefault = isDefault
    }
}

// MARK: - HLSByteRange

/// A sub-range of a resource, per `#EXT-X-BYTERANGE`/`#EXT-X-MAP`'s BYTERANGE
/// attribute (RFC 8216 §4.3.2.2, §4.3.2.4): `length` bytes starting at
/// `start`. `end` is the inclusive last byte, matching the
/// `Range: bytes=<start>-<end>` HTTP header format StreamSegment sends.
///
/// Exists because some real-world HLS delivery (confirmed: Pinterest's CMAF
/// output) addresses every segment of a rendition as a byte range into ONE
/// physical file, rather than one URL per segment — without this, a parser
/// that only understands "one URL = one segment" silently re-downloads that
/// entire file once per nominal segment and concatenates the duplicates,
/// corrupting the assembled output (and, since audio typically uses the same
/// addressing, is the confirmed root cause of split-audio HLS downloads
/// coming out silent on sites using this pattern).
public struct HLSByteRange: Sendable, Equatable {
    public let start: Int64
    public let length: Int64
    public var end: Int64 { start + length - 1 }

    public init(start: Int64, length: Int64) {
        self.start = start
        self.length = length
    }
}

// MARK: - HLSParser

/// Parses an HLS **media** playlist (a variant `.m3u8` — not a master playlist)
/// into a list of downloadable segments, together with any encryption metadata
/// and an optional init segment for fMP4/CMAF streams.
///
/// Only the subset of the HLS spec that real-world streaming sites use for
/// on-demand (VOD) content is handled here. Live streams (`#EXT-X-ENDLIST`
/// absent) are accepted but downloading them makes less sense — the caller
/// should check `isVOD` and warn appropriately.
///
/// Handles `#EXT-X-BYTERANGE` (byte-range-addressed segments sharing one
/// physical file — see `HLSByteRange`'s doc comment for why this matters in
/// practice, not just in theory) on both per-segment tags and `#EXT-X-MAP`'s
/// BYTERANGE attribute, including the spec's offset-omitted continuation form.
///
/// Not handled (no real-world need for downloading):
/// - `#EXT-X-DISCONTINUITY` across different codec/resolution streams
/// - `SAMPLE-AES` / `AES-256` / `CLEARKEY` encryption (DRM; caller gets an error)
/// - `#EXT-X-I-FRAME-STREAM-INF` (thumbnail trick-play playlists)
public struct HLSParser {

    // MARK: - Public types

    /// A single downloadable segment in the media playlist.
    public struct Segment: Sendable {
        /// The fully resolved URL of this segment file.
        public let url: URL
        /// Duration declared by `#EXTINF`, in seconds.
        public let duration: Double
        /// Sequence number (zero-based index from `EXT-X-MEDIA-SEQUENCE`).
        /// Used to derive the AES-128 IV when no explicit IV is given in the key tag.
        public let sequenceNumber: Int
        /// Non-nil when this segment was declared with `#EXT-X-BYTERANGE` —
        /// a specific slice of `url`'s resource, not the whole thing. See
        /// `HLSByteRange`'s doc comment.
        public let byteRange: HLSByteRange?
    }

    /// AES-128-CBC encryption applied to media segments.
    ///
    /// The key is fetched from `keyURL` with the same HTTP headers used for
    /// segments themselves. The IV is either:
    /// - The 16-byte value from `IV=0x...` in the `#EXT-X-KEY` tag, or
    /// - The segment's sequence number encoded as a 128-bit big-endian integer
    ///   (the HLS spec default when IV is not present).
    public struct EncryptionInfo: Sendable {
        /// Always `"AES-128"` — `SAMPLE-AES` / other methods produce a parse error.
        public let method: String
        /// Where to fetch the raw 16-byte AES key.
        public let keyURL: URL
        /// Explicit IV from the `#EXT-X-KEY` tag, or `nil` (use sequence number).
        public let iv: Data?
    }

    /// The fully parsed media playlist, ready to hand to `StreamDownloader`.
    public struct ParsedPlaylist: Sendable {
        /// Ordered list of media segments to download.
        public let segments: [Segment]
        /// `#EXT-X-MAP` init segment URL (fMP4/CMAF streams).
        /// Must be prepended to the output file before any media segments.
        public let initSegmentURL: URL?
        /// Non-nil when `#EXT-X-MAP` declared a BYTERANGE attribute — the init
        /// section is a slice of `initSegmentURL`'s resource, not the whole
        /// thing (common when it shares a physical file with the media
        /// segments, same as `Segment.byteRange`).
        public let initSegmentByteRange: HLSByteRange?
        /// Sum of all `#EXTINF` durations.
        public let totalDuration: Double
        /// Non-nil when the playlist carries `#EXT-X-KEY:METHOD=AES-128`.
        /// A SAMPLE-AES or unrecognised method causes `parse` to return `nil`
        /// and sets the `unsupportedEncryption` flag instead.
        public let encryption: EncryptionInfo?
        /// `true` when init segment is present — output file should be `.mp4`.
        /// `false` for MPEG-TS streams — output file should be `.ts`.
        public let isFMP4: Bool
        /// `true` when `#EXT-X-ENDLIST` is present (VOD, finite download).
        /// `false` for live streams (download will stop when segments run out).
        public let isVOD: Bool
        /// `true` when the playlist contained an unsupported encryption method
        /// (SAMPLE-AES, AES-256, etc.). Download should be refused with a clear error.
        public let unsupportedEncryption: Bool
        /// The `#EXT-X-MEDIA-SEQUENCE` value from the playlist.
        /// Used by `StreamDownloader` to derive per-segment AES IVs when no
        /// explicit IV is given in `#EXT-X-KEY`.
        public let mediaSequence: Int
    }


    // MARK: - Parse

    /// Parses `text` as an HLS media playlist, resolving relative URLs against `baseURL`.
    ///
    /// Returns `nil` when:
    /// - The text is not a valid M3U8 playlist (missing `#EXTM3U`)
    /// - The playlist is a **master** playlist (`#EXT-X-STREAM-INF` present) — the
    ///   browser already resolved the variant; this should never happen.
    /// - No `#EXTINF` segments are found.
    ///
    /// Returns a result with `unsupportedEncryption = true` (and `encryption = nil`)
    /// when a non-AES-128 / non-NONE key method is encountered, so the caller can
    /// show a clear "DRM-protected, cannot download" message rather than silently
    /// producing a broken file.
    public static func parse(text: String, baseURL: URL) -> ParsedPlaylist? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }

        // Must start with the magic tag.
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }
        // Master playlists contain variant declarations — we never deal with those here.
        guard !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) else { return nil }

        var segments: [Segment] = []
        var initSegmentURL: URL? = nil
        var initSegmentByteRange: HLSByteRange? = nil
        var totalDuration: Double = 0
        var encryption: EncryptionInfo? = nil
        var unsupportedEncryption = false
        var isFMP4 = false
        var isVOD = false
        var mediaSequence = 0
        var pendingDuration: Double? = nil
        // #EXT-X-BYTERANGE for the segment about to be read (applies only to
        // the next URI line, per RFC 8216 §4.3.2.2).
        var pendingByteRangeValue: (length: Int64, offset: Int64?)? = nil
        // Tracks the continuation case: an EXT-X-BYTERANGE with no @offset
        // means "starts right after the previous sub-range of the SAME
        // resource" — both pieces of state reset whenever a segment isn't a
        // byte-range continuation of the one before it.
        var runningByteOffset: Int64? = nil
        var lastByteRangeURL: URL? = nil

        // AES-128 key changes mid-playlist are allowed by the spec. Track the current
        // key separately from `encryption` so we can update it per-segment.
        var currentEncryption: EncryptionInfo? = nil

        for line in lines {
            if line.isEmpty || (line.hasPrefix("#") && !line.hasPrefix("#EXT")) { continue }

            // ── VOD marker ───────────────────────────────────────────────────────────
            if line == "#EXT-X-ENDLIST" {
                isVOD = true
                continue
            }

            // ── Media sequence (for IV derivation) ───────────────────────────────────
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let raw = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                mediaSequence = Int(raw) ?? 0
                continue
            }

            // ── Init segment (fMP4/CMAF) ──────────────────────────────────────────────
            if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uriRaw = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                   let resolved = resolveURL(uriRaw, against: baseURL) {
                    initSegmentURL = resolved
                    isFMP4 = true
                    // BYTERANGE on EXT-X-MAP always carries an explicit offset
                    // (RFC 8216 §4.3.2.4) — there's no "previous segment"
                    // continuation concept for an init section the way there
                    // is for media segments, so a value missing @offset is
                    // malformed and silently ignored rather than guessed at.
                    if let brRaw = attrs["BYTERANGE"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                       let parsed = parseByteRangeValue(brRaw), let offset = parsed.offset {
                        initSegmentByteRange = HLSByteRange(start: offset, length: parsed.length)
                    }
                }
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                // Applies only to the next URI line (RFC 8216 §4.3.2.2).
                pendingByteRangeValue = parseByteRangeValue(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
                continue
            }

            // ── Encryption ────────────────────────────────────────────────────────────
            if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                if method == "NONE" {
                    currentEncryption = nil
                } else if method == "AES-128" {
                    let uriRaw = attrs["URI"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) ?? ""
                    guard let keyURL = resolveURL(uriRaw, against: baseURL) else { continue }
                    let iv = attrs["IV"].flatMap { parseHexData(String($0)) }
                    currentEncryption = EncryptionInfo(method: "AES-128", keyURL: keyURL, iv: iv)
                    // Use the first key encountered as the playlist-level encryption info.
                    if encryption == nil { encryption = currentEncryption }
                } else {
                    // SAMPLE-AES, AES-256, CLEARKEY, etc. — DRM, can't download.
                    unsupportedEncryption = true
                    currentEncryption = nil
                }
                continue
            }

            // ── Segment duration ──────────────────────────────────────────────────────
            if line.hasPrefix("#EXTINF:") {
                let rest = line.dropFirst("#EXTINF:".count)
                // EXTINF value is "duration[,title]" — grab everything before the comma.
                let durationStr = rest.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(rest)
                pendingDuration = Double(durationStr.trimmingCharacters(in: .whitespaces))
                continue
            }

            // ── Skip other tags ───────────────────────────────────────────────────────
            if line.hasPrefix("#") { continue }

            // ── URI line ──────────────────────────────────────────────────────────────
            guard let duration = pendingDuration else { continue }
            pendingDuration = nil

            guard let segURL = resolveURL(line, against: baseURL) else { continue }

            var byteRange: HLSByteRange? = nil
            if let pending = pendingByteRangeValue {
                let offset: Int64
                if let o = pending.offset {
                    offset = o
                } else if lastByteRangeURL == segURL, let prevEnd = runningByteOffset {
                    offset = prevEnd
                } else {
                    // Spec (RFC 8216 §4.3.2.2) requires a previous same-resource
                    // sub-range when @offset is omitted, or the value is
                    // undefined. Every real playlist seen in practice always
                    // includes @offset — falling back to 0 degrades gracefully
                    // for a technically malformed but likely still-usable
                    // playlist rather than dropping the segment outright.
                    offset = 0
                }
                byteRange = HLSByteRange(start: offset, length: pending.length)
                runningByteOffset = offset + pending.length
                lastByteRangeURL = segURL
                pendingByteRangeValue = nil
            } else {
                // No BYTERANGE tag for this segment — it's the whole resource,
                // not a sub-range. Also resets continuation tracking: per spec
                // the offset-omitted shortcut only chains across consecutive
                // byte-range segments of the same resource.
                runningByteOffset = nil
                lastByteRangeURL = nil
            }

            let seqNum = mediaSequence + segments.count
            segments.append(Segment(url: segURL, duration: duration, sequenceNumber: seqNum, byteRange: byteRange))
            totalDuration += duration

            // If the playlist has unsupported encryption anywhere, that segment
            // range will produce garbage — but we still enumerate all segments
            // so the caller knows the full scope of the problem.
        }

        guard !segments.isEmpty else { return nil }

        return ParsedPlaylist(
            segments: segments,
            initSegmentURL: initSegmentURL,
            initSegmentByteRange: initSegmentByteRange,
            totalDuration: totalDuration,
            encryption: unsupportedEncryption ? nil : encryption,
            isFMP4: isFMP4,
            isVOD: isVOD,
            unsupportedEncryption: unsupportedEncryption,
            mediaSequence: mediaSequence
        )

    }

    // MARK: - Helpers

    /// Resolves a URI string against a base URL. Returns `nil` on failure.
    private static func resolveURL(_ raw: String, against base: URL) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    /// Parses an `EXT-X-BYTERANGE`/`EXT-X-MAP` BYTERANGE value: `<n>[@<o>]`
    /// (RFC 8216 §4.3.2.2) — `n` is the sub-range length, the optional `o` is
    /// its start offset. This function has no notion of "the previous
    /// segment"; when `o` is omitted, the caller resolves the correct
    /// continuation offset (see the URI-line handling in `parse`).
    /// One `#EXT-X-STREAM-INF` entry of a master playlist.
    public struct MasterVariant: Sendable, Equatable {
        public let url: URL
        public let bandwidth: Int
        /// The variant's split audio, from the `#EXT-X-MEDIA:TYPE=AUDIO`
        /// renditions its AUDIO group names. Empty when its segments carry sound.
        public let audio: [HLSAudioCandidate]
    }

    /// The variants of a master playlist, or nil when `text` isn't one.
    public static func parseMaster(text: String, baseURL: URL) -> [MasterVariant]? {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return nil }

        var audioGroups: [String: [HLSAudioCandidate]] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MEDIA:".count)))
            guard attrs["TYPE"] == "AUDIO", let group = attrs["GROUP-ID"], let uri = attrs["URI"],
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            audioGroups[group, default: []].append(
                HLSAudioCandidate(url: url, lang: attrs["LANGUAGE"], isDefault: attrs["DEFAULT"] == "YES"))
        }

        var variants: [MasterVariant] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty }), !uri.hasPrefix("#"),
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            variants.append(MasterVariant(
                url: url,
                bandwidth: Int(attrs["BANDWIDTH"] ?? "") ?? 0,
                audio: attrs["AUDIO"].flatMap { audioGroups[$0] } ?? []))
        }
        return variants.isEmpty ? nil : variants
    }

    private static func parseByteRangeValue(_ raw: String) -> (length: Int64, offset: Int64?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", maxSplits: 1)
        guard let first = parts.first, let length = Int64(first), length > 0 else { return nil }
        guard parts.count > 1 else { return (length, nil) }
        guard let offset = Int64(parts[1]) else { return (length, nil) }
        return (length, offset)
    }

    /// Parses a comma-separated HLS attribute list (KEY=VALUE,KEY="quoted,val").
    /// The same logic lives in background.js — keeping both in sync manually is
    /// fine since this is a well-defined spec fragment (not policy).
    private static func parseAttributeList(_ str: String) -> [String: String] {
        var attrs: [String: String] = [:]
        // Match KEY=VALUE or KEY="..." pairs. A quoted value may contain commas.
        var remaining = str[str.startIndex...]
        while !remaining.isEmpty {
            // Strip leading whitespace / commas
            remaining = remaining.drop(while: { $0 == "," || $0 == " " })
            guard let eqRange = remaining.range(of: "=") else { break }
            let key = String(remaining[..<eqRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            remaining = remaining[eqRange.upperBound...]

            let value: String
            if remaining.hasPrefix("\"") {
                // Quoted: scan for closing quote
                remaining = remaining.dropFirst()
                if let closeQ = remaining.firstIndex(of: "\"") {
                    value = String(remaining[..<closeQ])
                    remaining = remaining[closeQ...].dropFirst()
                } else {
                    value = String(remaining)
                    remaining = remaining[remaining.endIndex...]
                }
            } else {
                // Unquoted: scan for next comma
                if let comma = remaining.firstIndex(of: ",") {
                    value = String(remaining[..<comma])
                    remaining = remaining[comma...]
                } else {
                    value = String(remaining)
                    remaining = remaining[remaining.endIndex...]
                }
            }
            if !key.isEmpty { attrs[key] = value }
        }
        return attrs
    }

    /// Parses a hex string like `0x0123456789ABCDEF...` into raw bytes.
    private static func parseHexData(_ raw: String) -> Data? {
        var hex = raw.uppercased()
        if hex.hasPrefix("0X") { hex = String(hex.dropFirst(2)) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        return data.isEmpty ? nil : data
    }
}
