import Foundation

enum MagnetURIError: Error, Equatable {
    /// Not text that starts with `magnet:`.
    case notAMagnetLink
    /// A magnet link, but it names no torrent we can identify.
    case noInfoHash
    /// An `urn:btih:` value that is neither 40 hex digits nor 32 base32 characters.
    case malformedInfoHash(String)
    /// Names only a version 2 hash. Identity here is the v1 hash, so there is
    /// nothing to compare, and the link is reported rather than misread.
    case v2Only
}

/// What a magnet link says: which torrent, what to call it, where to ask for
/// peers. Reading it fetches nothing.
struct MagnetURI: Equatable, Sendable {
    /// The v1 info hash, the identity used for duplicate detection.
    let infoHash: TorrentInfoHash
    /// The SHA-256 digest from a `urn:btmh:` hash, when the link carries one
    /// (a hybrid torrent). Kept so a later version need not parse again.
    let infoHashV2: String?
    /// `dn`, not yet made safe to use as a file name.
    let displayName: String?
    let trackers: [String]

    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("magnet:") else { throw MagnetURIError.notAMagnetLink }

        // A plus in a query means a space and an encoded one (%2B) means a
        // plus. Settling the first before anything is decoded keeps them
        // apart; afterwards they would look the same.
        let spaced = trimmed.replacingOccurrences(of: "+", with: "%20")

        // Links written by hand skip the percent-encoding (spaces, brackets,
        // non-ASCII), so the strict reading would lose them.
        guard let components = URLComponents(string: spaced, encodingInvalidCharacters: true),
              components.scheme?.lowercased() == "magnet" else {
            throw MagnetURIError.notAMagnetLink
        }
        let items = (components.queryItems ?? []).map { (name: $0.name.lowercased(), value: $0.value ?? "") }

        var v1: TorrentInfoHash?
        var v2: String?
        var malformed: String?
        for item in items where item.name == "xt" {
            let lowered = item.value.lowercased()
            if lowered.hasPrefix("urn:btih:") {
                let text = String(item.value.dropFirst("urn:btih:".count))
                if let hash = TorrentInfoHash(hex: text) ?? TorrentInfoHash(base32: text) {
                    v1 = v1 ?? hash
                } else {
                    malformed = malformed ?? text
                }
            } else if lowered.hasPrefix("urn:btmh:") {
                // "1220" is the multihash header for a 32-byte SHA-256.
                let multihash = lowered.dropFirst("urn:btmh:".count)
                if multihash.hasPrefix("1220"), multihash.count == 68,
                   TorrentInfoHash.isHexDigits(multihash.dropFirst(4)) {
                    v2 = v2 ?? String(multihash.dropFirst(4))
                }
            }
        }

        if let v1 {
            infoHash = v1
        } else if let malformed {
            throw MagnetURIError.malformedInfoHash(malformed)
        } else if v2 != nil {
            throw MagnetURIError.v2Only
        } else {
            throw MagnetURIError.noInfoHash
        }
        infoHashV2 = v2

        let name = items.first { $0.name == "dn" }?.value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = (name?.isEmpty == false) ? name : nil

        trackers = TorrentTrackers.cleaned(items.filter { $0.name == "tr" }.map(\.value))
    }
}
