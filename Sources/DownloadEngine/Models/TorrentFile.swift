import Foundation
import CryptoKit

public enum TorrentFileError: Error, LocalizedError, Equatable, Sendable {
    case invalidBencode(Bencode.DecodeError)
    /// Valid bencode, but not a dictionary.
    case notATorrent
    case missingField(String)
    case invalidField(String)
    /// A name or path component that could point outside the download folder,
    /// or is not a plain file name. Carries the offending text.
    case unsafePath(String)
    /// A version 2 torrent with no v1 hash to identify it by.
    case v2Only
    /// The `.torrent` file exceeds the maximum allowed metadata size.
    case fileTooLarge(Int64)

    public var errorDescription: String? {
        switch self {
        case .v2Only:
            return "BitTorrent v2-only torrents aren't supported yet."
        case .unsafePath:
            return "This torrent contains an unsafe file path."
        case .fileTooLarge:
            return "This .torrent file is too large to open."
        case .invalidBencode, .notATorrent, .missingField, .invalidField:
            return "This file is not a valid torrent."
        }
    }
}

/// What a `.torrent` file says: which torrent it is, what is in it, and where
/// to find peers.
///
/// A torrent's names end up as paths on someone's disk and the file is
/// written by strangers, so a name or path component that is empty, `.`,
/// `..` or contains a `/` makes the whole file unusable here instead of being
/// passed on for every later step to remember to distrust.
public struct TorrentFile: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// Path components below the torrent's folder. A single-file torrent
        /// has one entry whose path is just its name.
        public let path: [String]
        public let length: Int64
        /// BEP 47 padding entry (`attr` containing `"p"`). Kept in `files` so
        /// file indexes stay aligned with the engine's `only_files` and
        /// `file_progress`, but excluded from `totalSize`.
        public let isPadding: Bool

        public init(path: [String], length: Int64, isPadding: Bool = false) {
            self.path = path
            self.length = length
            self.isPadding = isPadding
        }

        public var displayPath: String { path.joined(separator: "/") }
    }

    /// Hard cap on `.torrent` metadata file size to prevent UI freezes and OOMs.
    public static let maxFileSizeBytes: Int64 = 25 * 1024 * 1024
    /// Hard cap on SHA-1 piece entries in `info.pieces`.
    public static let maxPieceCount = 1_000_000

    /// The identity: SHA-1 over the `info` dictionary's bytes exactly as written.
    public let infoHash: TorrentInfoHash
    /// Not yet made safe to use as a file name beyond the path checks above.
    public let name: String
    public let files: [Entry]
    public let totalSize: Int64
    /// Number of SHA-1 pieces in `info.pieces`, used to trim trailing padding bits
    /// from the engine's byte-aligned `/haves` bitfield.
    public let pieceCount: Int
    /// `announce` and `announce-list` merged, each address once.
    public let trackers: [String]
    public let isMultiFile: Bool
    /// Private torrents forbid peer sources other than their own trackers.
    public let isPrivate: Bool
    /// The bytes this was read from, as received. A torrent resolved from a
    /// magnet link is saved and added from these, so what the engine is given
    /// is exactly what the swarm sent, and its hash is unchanged.
    public let source: Data

    public init(_ data: Data) throws {
        if Int64(data.count) > Self.maxFileSizeBytes {
            throw TorrentFileError.fileTooLarge(Int64(data.count))
        }
        // A copy, so offsets into it are the offsets the reader reports even
        // when the caller handed over a slice of something larger.
        let input = Data(data)
        let decoded: Bencode.Decoded
        do {
            decoded = try Bencode.decode(input)
        } catch let error as Bencode.DecodeError {
            throw TorrentFileError.invalidBencode(error)
        }

        guard case .dictionary = decoded.value else { throw TorrentFileError.notATorrent }
        guard let infoRange = decoded.topLevelRanges["info"], let info = decoded.value["info"] else {
            throw TorrentFileError.missingField("info")
        }
        guard case .dictionary = info else { throw TorrentFileError.invalidField("info") }

        if info["meta version"]?.integer == 2, info["pieces"] == nil {
            throw TorrentFileError.v2Only
        }

        guard let nameValue = info["name.utf-8"] ?? info["name"] else { throw TorrentFileError.missingField("name") }
        guard let name = nameValue.string else { throw TorrentFileError.invalidField("name") }
        try Self.validate(component: name)

        let entries: [Entry]
        let multiFile: Bool
        if let filesValue = info["files"] {
            guard let list = filesValue.list, !list.isEmpty else { throw TorrentFileError.invalidField("files") }
            entries = try list.map(Self.entry(from:))
            multiFile = true
        } else if let lengthValue = info["length"] {
            guard let length = lengthValue.integer, length >= 0 else { throw TorrentFileError.invalidField("length") }
            entries = [Entry(path: [name], length: length)]
            multiFile = false
        } else {
            throw TorrentFileError.missingField("length or files")
        }

        guard let pieceLengthValue = info["piece length"] else { throw TorrentFileError.missingField("piece length") }
        guard let pieceLength = pieceLengthValue.integer, pieceLength > 0 else {
            throw TorrentFileError.invalidField("piece length")
        }
        guard let piecesValue = info["pieces"] else { throw TorrentFileError.missingField("pieces") }
        guard let pieces = piecesValue.bytes, !pieces.isEmpty, pieces.count % 20 == 0 else {
            throw TorrentFileError.invalidField("pieces")
        }

        var total: Int64 = 0
        var streamTotal: Int64 = 0
        for entry in entries {
            let (streamSum, streamOverflow) = streamTotal.addingReportingOverflow(entry.length)
            if streamOverflow { throw TorrentFileError.invalidField("length") }
            streamTotal = streamSum
            if !entry.isPadding {
                let (sum, overflow) = total.addingReportingOverflow(entry.length)
                if overflow { throw TorrentFileError.invalidField("length") }
                total = sum
            }
        }

        let pieceCount = pieces.count / 20
        let expectedPieces: Int64 = streamTotal == 0 ? 0 : ((streamTotal - 1) / pieceLength) + 1
        guard pieceCount <= Self.maxPieceCount, Int64(pieceCount) == expectedPieces else {
            throw TorrentFileError.invalidField("pieces")
        }

        var announced: [String] = []
        if let announce = decoded.value["announce"]?.string { announced.append(announce) }
        for tier in decoded.value["announce-list"]?.list ?? [] {
            announced.append(contentsOf: (tier.list ?? []).compactMap(\.string))
        }

        self.infoHash = TorrentInfoHash(digest: Insecure.SHA1.hash(data: input[infoRange]))
        self.name = name
        self.files = entries
        self.totalSize = total
        self.pieceCount = pieceCount
        self.trackers = TorrentTrackers.cleaned(announced)
        self.isMultiFile = multiFile
        self.isPrivate = info["private"]?.integer == 1
        self.source = input
    }

    private static func entry(from value: Bencode.Value) throws -> Entry {
        guard case .dictionary = value else { throw TorrentFileError.invalidField("files") }
        guard let length = value["length"]?.integer, length >= 0 else { throw TorrentFileError.invalidField("length") }
        guard let components = (value["path.utf-8"] ?? value["path"])?.list, !components.isEmpty else {
            throw TorrentFileError.invalidField("path")
        }
        let path = try components.map { component -> String in
            guard let text = component.string else { throw TorrentFileError.invalidField("path") }
            try validate(component: text)
            return text
        }
        let isPadding = value["attr"]?.string?.contains("p") == true
        return Entry(path: path, length: length, isPadding: isPadding)
    }

    private static func validate(component: String) throws {
        if component.isEmpty || component == "." || component == ".."
            || component.contains("/") || component.contains("\\")
            || component.contains(":") || component.contains("\0") {
            throw TorrentFileError.unsafePath(component)
        }
        for scalar in component.unicodeScalars {
            let v = scalar.value
            // Reject ASCII/Unicode control characters and BiDi override/isolate
            // controls (e.g. U+202E RLO) that can spoof file extensions.
            if v < 0x20 || v == 0x7F || scalar.properties.generalCategory == .control
                || (0x202A...0x202E).contains(v)
                || (0x2066...0x2069).contains(v)
                || v == 0x200E || v == 0x200F || v == 0x061C {
                throw TorrentFileError.unsafePath(component)
            }
        }
    }
}
