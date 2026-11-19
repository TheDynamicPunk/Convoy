import XCTest
import CryptoKit
@testable import DownloadEngine

/// Tests for the one place bytes become lowercase hex.
///
/// The format has to match what `String(format: "%02x", ...)` produced at the
/// three call sites this replaced, because the output is compared against
/// hashes already committed in `helpers.json` and published by upstreams.
final class HexStringTests: XCTestCase {

    func testEmptyInputIsAnEmptyString() {
        XCTAssertEqual(Data().hexString, "")
    }

    func testEveryByteIsTwoLowercaseDigits() {
        XCTAssertEqual(Data([0x00, 0x0f, 0xab, 0xff]).hexString, "000fabff")
    }

    /// The old idiom, kept here as the oracle: all 256 byte values agree.
    func testMatchesTheFormatStringItReplaced() {
        let all = (0...255).map { UInt8($0) }
        XCTAssertEqual(all.hexString, all.map { String(format: "%02x", $0) }.joined())
    }

    /// FIPS 180-2 test vector for "abc".
    func testSHA256DigestOfABC() {
        XCTAssertEqual(
            SHA256.hash(data: Data("abc".utf8)).hexString,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// The info-hash parser's case: SHA-1 is 20 bytes, so 40 digits.
    func testSHA1DigestOfABC() {
        XCTAssertEqual(
            Insecure.SHA1.hash(data: Data("abc".utf8)).hexString,
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        )
    }
}
