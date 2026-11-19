import Foundation
import CryptoKit

/// A BitTorrent v1 info hash: the 20-byte SHA-1 that names a torrent.
///
/// One normalised form for the three ways it arrives. A magnet link writes it
/// as 40 hex digits or as 32 base32 characters, and a `.torrent` file yields
/// it as a SHA-1 digest. Duplicate detection compares hashes, so a value that
/// could still be upper- or lowercase, or hex or base32, would call the same
/// torrent two different things.
struct TorrentInfoHash: Hashable, Sendable, CustomStringConvertible {
    /// 40 lowercase hex digits.
    let hex: String

    init?(hex text: String) {
        guard text.utf8.count == 40, Self.isHexDigits(text) else { return nil }
        self.hex = text.lowercased()
    }

    init(digest: Insecure.SHA1Digest) {
        self.hex = digest.hexString
    }

    /// RFC 4648 base32, 32 characters with no padding (160 bits, exactly 20
    /// bytes), either case. Magnet links from older clients use this form.
    init?(base32 text: String) {
        let input = Array(text.utf8)
        guard input.count == 32 else { return nil }

        var buffer: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(20)
        for character in input {
            let value: UInt8
            switch character {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = character - UInt8(ascii: "A")
            case UInt8(ascii: "a")...UInt8(ascii: "z"): value = character - UInt8(ascii: "a")
            case UInt8(ascii: "2")...UInt8(ascii: "7"): value = character - UInt8(ascii: "2") + 26
            default: return nil
            }
            buffer = (buffer << 5) | UInt64(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> UInt64(bitCount)) & 0xff))
                buffer &= (1 << UInt64(bitCount)) - 1
            }
        }
        self.hex = bytes.hexString
    }

    var description: String { hex }

    /// Whether every character is a hex digit, either case.
    static func isHexDigits(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
                || ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F"))
        }
    }
}

/// Which tracker addresses are worth keeping, shared by the magnet and
/// `.torrent` readers so the two cannot disagree.
enum TorrentTrackers {
    private static let schemes: Set<String> = ["http", "https", "udp", "ws", "wss"]

    /// The usable addresses, each once, in the order they were offered. An
    /// address is usable when it has one of the schemes trackers speak and a
    /// host; the rest is junk that only a hand-edited link contains.
    static func cleaned(_ candidates: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let text = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), schemes.contains(scheme),
                  let host = url.host, !host.isEmpty,
                  seen.insert(text).inserted else { continue }
            result.append(text)
        }
        return result
    }
}
