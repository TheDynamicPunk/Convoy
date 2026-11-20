import XCTest
import CryptoKit
@testable import DownloadEngine

/// Tests for the one normalised form of a BitTorrent v1 info hash.
///
/// Magnet links write the same 20 bytes two ways (40 hex digits or 32 base32
/// characters) and a `.torrent` yields them as a SHA-1 digest. Duplicate
/// detection compares hashes, so all three must land on one representation.
final class TorrentInfoHashTests: XCTestCase {

    // Computed independently with Python's hashlib / base64 over a known info
    // dictionary (the same one `TorrentFileTests` uses as fixture A).
    private let hex = TorrentFixtures.hashA
    private let base32 = TorrentFixtures.base32A

    func testHexIsAcceptedAndLowercased() {
        XCTAssertEqual(TorrentInfoHash(hex: hex)?.hex, hex)
        XCTAssertEqual(TorrentInfoHash(hex: hex.uppercased())?.hex, hex)
    }

    func testHexOfTheWrongLengthOrAlphabetIsRefused() {
        XCTAssertNil(TorrentInfoHash(hex: String(hex.dropLast())))
        XCTAssertNil(TorrentInfoHash(hex: hex + "0"))
        XCTAssertNil(TorrentInfoHash(hex: String(repeating: "g", count: 40)))
        XCTAssertNil(TorrentInfoHash(hex: ""))
    }

    func testBase32DecodesToTheSameHashAsHex() {
        XCTAssertEqual(TorrentInfoHash(base32: base32), TorrentInfoHash(hex: hex))
        XCTAssertEqual(TorrentInfoHash(base32: base32.lowercased()), TorrentInfoHash(hex: hex))
    }

    func testBase32OfTheWrongLengthOrAlphabetIsRefused() {
        XCTAssertNil(TorrentInfoHash(base32: String(base32.dropLast())))
        XCTAssertNil(TorrentInfoHash(base32: base32 + "A"))
        // 0, 1, 8 and 9 are not in the RFC 4648 alphabet.
        for bad in ["0", "1", "8", "9", "=", "-"] {
            XCTAssertNil(TorrentInfoHash(base32: bad + String(base32.dropFirst())), "accepted \(bad)")
        }
        XCTAssertNil(TorrentInfoHash(base32: ""))
    }

    func testASHA1DigestBecomesAHash() {
        // FIPS 180-1 test vector for "abc".
        XCTAssertEqual(
            TorrentInfoHash(digest: Insecure.SHA1.hash(data: Data("abc".utf8))).hex,
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
    }

    func testHashesCompareByValueAndCanKeyASet() throws {
        let fromHex = try XCTUnwrap(TorrentInfoHash(hex: hex))
        let fromBase32 = try XCTUnwrap(TorrentInfoHash(base32: base32))
        XCTAssertEqual(Set([fromHex, fromBase32]).count, 1)
    }

    func testTrackerCleaningDeduplicatesSchemeAndHostCaseInsensitivelyWhileKeepingPathCaseSensitive() {
        let cleaned = TorrentTrackers.cleaned([
            "HTTP://Tracker.Example/ann?key=AbC",
            "http://tracker.example/ann?key=AbC",
            "http://tracker.example/ann?key=abc",
            "http://tracker.example/Ann?key=AbC",
        ])
        XCTAssertEqual(cleaned, [
            "HTTP://Tracker.Example/ann?key=AbC",
            "http://tracker.example/ann?key=abc",
            "http://tracker.example/Ann?key=AbC",
        ])
    }
}
