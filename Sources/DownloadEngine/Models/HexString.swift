import Foundation

extension Sequence where Element == UInt8 {
    /// The bytes as lowercase hex, two digits each.
    ///
    /// The one definition of how a hash is written down. It was spelled out as
    /// `map { String(format: "%02x", $0) }.joined()` at three call sites (the
    /// helper list's download check, in memory and from a file, and the
    /// manifest tool) and a fourth was about to be written for BitTorrent info
    /// hashes. Every CryptoKit `Digest` is a sequence of bytes, so this serves
    /// SHA-256 and SHA-1 alike, and `Data` and `[UInt8]` too.
    ///
    /// Public because `HelperManifestTool` is a separate target.
    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(underestimatedCount * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
