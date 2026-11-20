import Foundation

/// Which engine drives a `DownloadTask`, together with the configuration that
/// belongs only to that engine.
///
/// One explicit value rather than parallel optional clusters on `DownloadTask`:
/// every branch (`start`, `pause`, `cancel`, `identity`, persistence, segment
/// map, activity message) switches on `kind`, so adding a new download kind
/// makes the compiler point at every place that has to handle it.
public enum DownloadKind: Equatable, Sendable {

    /// A YouTube download driven end to end by yt-dlp.
    public struct YouTube: Equatable, Sendable {
        /// yt-dlp `-f` format selector (for example `"137,140"`).
        public let formatSelector: String
        /// Watch page URL; yt-dlp re-resolves fresh stream URLs each run.
        public let pageURL: URL

        public init(formatSelector: String, pageURL: URL) {
            self.formatSelector = formatSelector
            self.pageURL = pageURL
        }
    }

    /// A native HLS or DASH stream download driven by `StreamDownloader`.
    public struct Stream: Equatable, Sendable {
        /// Manifest or variant-playlist URL sniffed from the browser.
        public let url: URL
        /// `"hls"` or `"dash"`.
        public let type: String
        public let representationId: String?
        public let bandwidth: Int?
        /// Preferred DASH audio language captured when the task was created.
        /// Persisting it keeps a paused download's selected audio track stable.
        public let preferredAudioLanguage: String?
        /// Candidate audio renditions for an HLS variant's AUDIO group;
        /// nil/empty for a combined stream and for DASH.
        public let hlsAudioTracks: [HLSAudioCandidate]?

        public init(
            url: URL,
            type: String,
            representationId: String? = nil,
            bandwidth: Int? = nil,
            preferredAudioLanguage: String? = nil,
            hlsAudioTracks: [HLSAudioCandidate]? = nil
        ) {
            self.url = url
            self.type = type
            self.representationId = representationId
            self.bandwidth = bandwidth
            self.preferredAudioLanguage = preferredAudioLanguage
            self.hlsAudioTracks = hlsAudioTracks
        }
    }

    /// Plain HTTP/HTTPS/FTP download using the streaming probe and segment engine.
    case direct
    case youTube(YouTube)
    case stream(Stream)
}
