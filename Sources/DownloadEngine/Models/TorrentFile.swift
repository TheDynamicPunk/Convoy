import Foundation
import CryptoKit

enum TorrentFileError: Error, Equatable {
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
}

/// What a `.torrent` file says: which torrent it is, what is in it, and where
/// to find peers.
///
/// A torrent's names end up as paths on someone's disk and the file is
/// written by strangers, so a name or path component that is empty, `.`,
/// `..` or contains a `/` makes the whole file unusable here instead of being
/// passed on for every later step to remember to distrust.
struct TorrentFile: Equatable, Sendable {

    struct Entry: Equatable, Sendable {
        /// Path components below the torrent's folder. A single-file torrent
        /// has one entry whose path is just its name.
        let path: [String]
        let length: Int64

        var displayPath: String { path.joined(separator: "/") }
    }

    /// The identity: SHA-1 over the `info` dictionary's bytes exactly as written.
    let infoHash: TorrentInfoHash
    /// Not yet made safe to use as a file name beyond the path checks above.
    let name: String
    let files: [Entry]
    let totalSize: Int64
    /// `announce` and `announce-list` merged, each address once.
    let trackers: [String]
    let isMultiFile: Bool
    /// Private torrents forbid peer sources other than their own trackers.
    let isPrivate: Bool

    init(_ data: Data) throws {
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

        guard let nameValue = info["name"] else { throw TorrentFileError.missingField("name") }
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
        for entry in entries {
            let (sum, overflow) = total.addingReportingOverflow(entry.length)
            if overflow { throw TorrentFileError.invalidField("length") }
            total = sum
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
        self.trackers = TorrentTrackers.cleaned(announced)
        self.isMultiFile = multiFile
        self.isPrivate = info["private"]?.integer == 1
    }

    private static func entry(from value: Bencode.Value) throws -> Entry {
        guard case .dictionary = value else { throw TorrentFileError.invalidField("files") }
        guard let length = value["length"]?.integer, length >= 0 else { throw TorrentFileError.invalidField("length") }
        guard let components = value["path"]?.list, !components.isEmpty else { throw TorrentFileError.invalidField("path") }
        let path = try components.map { component -> String in
            guard let text = component.string else { throw TorrentFileError.invalidField("path") }
            try validate(component: text)
            return text
        }
        return Entry(path: path, length: length)
    }

    private static func validate(component: String) throws {
        if component.isEmpty || component == "." || component == ".."
            || component.contains("/") || component.contains("\0") {
            throw TorrentFileError.unsafePath(component)
        }
    }
}
