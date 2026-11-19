import XCTest
@testable import DownloadEngine

/// Tests for reading a magnet link: which torrent it names, what it calls it,
/// and where to ask for peers. Nothing is fetched.
final class MagnetURITests: XCTestCase {

    private let hex = "3facef60ceef085adc8d0bad64202f88ef953279"
    private let base32 = "H6WO6YGO54EFVXENBOWWIIBPRDXZKMTZ"
    /// A BEP 52 multihash: "1220" says "SHA-256, 32 bytes", then the digest.
    private let v2Digest = String(repeating: "ab", count: 32)

    private func assertThrows(_ link: String, _ expected: MagnetURIError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MagnetURI(link), file: file, line: line) { error in
            XCTAssertEqual(error as? MagnetURIError, expected, file: file, line: line)
        }
    }

    // MARK: - The ordinary link

    func testReadsTheHashTheNameAndTheTrackers() throws {
        let magnet = try MagnetURI(
            "magnet:?xt=urn:btih:\(hex)&dn=My+Show%20S01&tr=udp%3A%2F%2Ftracker.example%3A80&tr=http://t.example/ann"
        )
        XCTAssertEqual(magnet.infoHash.hex, hex)
        XCTAssertEqual(magnet.displayName, "My Show S01")
        XCTAssertEqual(magnet.trackers, ["udp://tracker.example:80", "http://t.example/ann"])
        XCTAssertNil(magnet.infoHashV2)
    }

    func testABase32HashIsTheSameTorrentAsTheHexOne() throws {
        let fromBase32 = try MagnetURI("magnet:?xt=urn:btih:\(base32)")
        let fromHex = try MagnetURI("magnet:?xt=urn:btih:\(hex)")
        XCTAssertEqual(fromBase32.infoHash, fromHex.infoHash)
    }

    func testSchemeKeysAndHashAreCaseInsensitive() throws {
        let magnet = try MagnetURI("MAGNET:?XT=URN:BTIH:\(hex.uppercased())&DN=Name")
        XCTAssertEqual(magnet.infoHash.hex, hex)
        XCTAssertEqual(magnet.displayName, "Name")
    }

    func testSurroundingWhitespaceFromAPasteIsIgnored() throws {
        XCTAssertEqual(try MagnetURI("  \n magnet:?xt=urn:btih:\(hex) \n").infoHash.hex, hex)
    }

    // MARK: - Names

    /// A plus in a query is a space, an encoded plus is a plus.
    func testPlusMeansSpaceButAnEncodedPlusStaysAPlus() throws {
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&dn=C%2B%2B+Primer")
        XCTAssertEqual(magnet.displayName, "C++ Primer")
    }

    /// Hand-made links often skip the encoding, spaces and non-ASCII included.
    func testAnUnencodedNameStillParses() throws {
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&dn=Ünïcode name [x]")
        XCTAssertEqual(magnet.displayName, "Ünïcode name [x]")
    }

    func testAStrayPercentSignDoesNotLoseTheLink() throws {
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&dn=100%")
        XCTAssertEqual(magnet.infoHash.hex, hex)
        XCTAssertEqual(magnet.displayName, "100%")
    }

    func testAnEmptyOrMissingNameIsNil() throws {
        XCTAssertNil(try MagnetURI("magnet:?xt=urn:btih:\(hex)").displayName)
        XCTAssertNil(try MagnetURI("magnet:?xt=urn:btih:\(hex)&dn=").displayName)
        XCTAssertNil(try MagnetURI("magnet:?xt=urn:btih:\(hex)&dn=%20%20").displayName)
    }

    // MARK: - Trackers

    func testTrackersAreDedupedInOrderAndJunkIsDropped() throws {
        let magnet = try MagnetURI(
            "magnet:?xt=urn:btih:\(hex)&tr=http://a.example/x&tr=notaurl&tr=http://b.example/x&tr=http://a.example/x&tr="
        )
        XCTAssertEqual(magnet.trackers, ["http://a.example/x", "http://b.example/x"])
    }

    // MARK: - Version 2 hashes

    /// A hybrid link carries both. The v1 hash is the identity; the v2 digest
    /// is kept so a later version need not parse the link again.
    func testAHybridLinkKeepsTheV2DigestBesideTheV1Hash() throws {
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&xt=urn:btmh:1220\(v2Digest)")
        XCTAssertEqual(magnet.infoHash.hex, hex)
        XCTAssertEqual(magnet.infoHashV2, v2Digest)
    }

    func testALinkWithOnlyAV2HashIsSaidToBeUnsupportedNotMalformed() {
        assertThrows("magnet:?xt=urn:btmh:1220\(v2Digest)&dn=x", .v2Only)
    }

    func testAMultihashThatIsNotSHA256IsIgnored() throws {
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&xt=urn:btmh:1114\(String(repeating: "cd", count: 20))")
        XCTAssertNil(magnet.infoHashV2)
    }

    // MARK: - Not a usable magnet link

    func testSomethingThatIsNotAMagnetLink() {
        assertThrows("https://example.com/file.torrent", .notAMagnetLink)
        assertThrows("", .notAMagnetLink)
        assertThrows("magnet", .notAMagnetLink)
        assertThrows("not a url at all", .notAMagnetLink)
    }

    func testAMagnetLinkNamingNoTorrent() {
        assertThrows("magnet:?", .noInfoHash)
        assertThrows("magnet:?dn=Only+A+Name&tr=http://a.example/x", .noInfoHash)
        assertThrows("magnet:?xt=urn:sha1:\(hex)", .noInfoHash)
    }

    func testAHashThatIsNeitherHexNorBase32() {
        assertThrows("magnet:?xt=urn:btih:abc123", .malformedInfoHash("abc123"))
        assertThrows("magnet:?xt=urn:btih:\(String(repeating: "z", count: 40))",
                     .malformedInfoHash(String(repeating: "z", count: 40)))
    }

    func testTheFirstUsableV1HashWins() throws {
        let other = String(repeating: "1", count: 40)
        let magnet = try MagnetURI("magnet:?xt=urn:btih:\(hex)&xt=urn:btih:\(other)")
        XCTAssertEqual(magnet.infoHash.hex, hex)
    }
}
