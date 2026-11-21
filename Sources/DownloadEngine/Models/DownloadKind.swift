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

    /// A BitTorrent download driven by `TorrentEngine` (rqbit in production).
    public struct Torrent: Equatable, Sendable {
        /// The v1 info hash identifying this torrent across restarts.
        public let infoHash: TorrentInfoHash
        /// Optional v2 SHA-256 hex digest for hybrid torrents.
        public let infoHashV2: String?
        /// Original magnet link, if the torrent came from one.
        public let magnetURI: String?
        /// Path to Convoy's stored `.torrent` copy under `torrentsDirectory/<id>/source.torrent`.
        public var storedTorrentPath: String?
        /// File indexes to download, or nil for all files.
        public var selectedFiles: Set<Int>?
        /// Whole-torrent payload size in bytes (used for upfront disk-space checks,
        /// since rqbit allocates deselected files too). Nil until metadata resolves.
        public var wholeTorrentSize: Int64?
        /// Whether this task has already claimed its destination folder via `mkdir`.
        public var hasClaimedFolder: Bool

        public init(
            infoHash: TorrentInfoHash,
            infoHashV2: String? = nil,
            magnetURI: String? = nil,
            storedTorrentPath: String? = nil,
            selectedFiles: Set<Int>? = nil,
            wholeTorrentSize: Int64? = nil,
            hasClaimedFolder: Bool = false
        ) {
            self.infoHash = infoHash
            self.infoHashV2 = infoHashV2
            self.magnetURI = magnetURI
            self.storedTorrentPath = storedTorrentPath
            self.selectedFiles = selectedFiles
            self.wholeTorrentSize = wholeTorrentSize
            self.hasClaimedFolder = hasClaimedFolder
        }
    }

    /// Plain HTTP/HTTPS/FTP download using the streaming probe and segment engine.
    case direct
    case youTube(YouTube)
    case stream(Stream)
    case torrent(Torrent)
}
