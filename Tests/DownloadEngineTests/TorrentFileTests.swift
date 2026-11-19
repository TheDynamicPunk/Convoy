import XCTest
@testable import DownloadEngine

/// Tests for reading a `.torrent` file: what is in it, and which torrent it is.
///
/// The expected info hashes in the fixtures were computed independently with
/// Python's hashlib over the exact bytes of each `info` dictionary, so they
/// check the parser against something other than itself.
final class TorrentFileTests: XCTestCase {

    // MARK: - Fixtures

    private let pieces = "6:pieces20:aaaaaaaaaaaaaaaaaaaa"

    /// Fixture A: a single file, canonical key order.
    private let infoA = "d6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae"
    private let torrentA = "d8:announce20:http://t.example/ann4:infod6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    private let hashA = "3facef60ceef085adc8d0bad64202f88ef953279"
    private let base32A = "H6WO6YGO54EFVXENBOWWIIBPRDXZKMTZ"

    /// Fixture B: two files, one in a sub-folder, trackers only in `announce-list`.
    private let torrentB = "d13:announce-listll19:http://t1.example/a19:http://t2.example/ael19:udp://t3.example:80ee4:infod5:filesld6:lengthi3e4:pathl1:a5:b.txteed6:lengthi4e4:pathl5:c.bineee4:name4:pack12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    private let hashB = "2716855658cc83fb5cdeb6cf708a8dab27641cef"

    /// Fixture C: the same content as A, but the `info` keys are not in sorted
    /// order. Hashing a re-encoded copy would give a different answer from
    /// hashing the bytes as written, and only the second is right.
    private let torrentC = "d4:infod4:name3:abc6:lengthi5e12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    private let hashC = "89e247aba9b108e9a4667cb926b66def9b0b2c32"

    private func torrent(info: String) -> Data { Data("d4:info\(info)e".utf8) }

    private func assertThrows(_ data: Data, _ expected: TorrentFileError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TorrentFile(data), file: file, line: line) { error in
            XCTAssertEqual(error as? TorrentFileError, expected, file: file, line: line)
        }
    }

    // MARK: - A single file

    func testReadsASingleFileTorrent() throws {
        let file = try TorrentFile(Data(torrentA.utf8))

        XCTAssertEqual(file.infoHash.hex, hashA)
        XCTAssertEqual(file.name, "abc")
        XCTAssertEqual(file.files, [TorrentFile.Entry(path: ["abc"], length: 5)])
        XCTAssertEqual(file.totalSize, 5)
        XCTAssertFalse(file.isMultiFile)
        XCTAssertFalse(file.isPrivate)
        XCTAssertEqual(file.trackers, ["http://t.example/ann"])
    }

    // MARK: - Several files

    func testReadsAMultiFileTorrentInOrder() throws {
        let file = try TorrentFile(Data(torrentB.utf8))

        XCTAssertEqual(file.infoHash.hex, hashB)
        XCTAssertEqual(file.name, "pack")
        XCTAssertEqual(file.files, [
            TorrentFile.Entry(path: ["a", "b.txt"], length: 3),
            TorrentFile.Entry(path: ["c.bin"], length: 4),
        ])
        XCTAssertEqual(file.files.map(\.displayPath), ["a/b.txt", "c.bin"])
        XCTAssertEqual(file.totalSize, 7)
        XCTAssertTrue(file.isMultiFile)
    }

    func testTrackersFromBothAnnounceFieldsAreMergedWithoutRepeats() throws {
        let data = Data("d8:announce19:http://t1.example/a13:announce-listll19:http://t1.example/a19:http://t2.example/aee4:info\(infoA)e".utf8)
        XCTAssertEqual(try TorrentFile(data).trackers, ["http://t1.example/a", "http://t2.example/a"])

        XCTAssertEqual(
            try TorrentFile(Data(torrentB.utf8)).trackers,
            ["http://t1.example/a", "http://t2.example/a", "udp://t3.example:80"]
        )
    }

    func testAPrivateTorrentIsMarkedPrivate() throws {
        let info = "d6:lengthi5e4:name3:abc12:piece lengthi16384e\(pieces)7:privatei1ee"
        XCTAssertTrue(try TorrentFile(torrent(info: info)).isPrivate)
    }

    // MARK: - Which torrent it is

    /// The hash is over the bytes as they were written, not over a tidied copy.
    func testTheHashCoversTheInfoBytesAsWrittenEvenWhenTheirKeysAreOutOfOrder() throws {
        XCTAssertEqual(try TorrentFile(Data(torrentC.utf8)).infoHash.hex, hashC)
    }

    /// The case duplicate detection exists for: the same content arriving once
    /// as a magnet link and once as a file.
    func testAMagnetLinkAndATorrentFileForTheSameContentHaveOneIdentity() throws {
        let fromFile = try TorrentFile(Data(torrentA.utf8))
        let fromBase32 = try MagnetURI("magnet:?xt=urn:btih:\(base32A)")
        let fromHex = try MagnetURI("magnet:?xt=urn:btih:\(hashA)&dn=abc")

        XCTAssertEqual(fromFile.infoHash, fromBase32.infoHash)
        XCTAssertEqual(fromFile.infoHash, fromHex.infoHash)
    }

    // MARK: - Not a usable torrent

    func testBytesThatAreNotBencodeAreReportedAsSuch() {
        assertThrows(Data("not bencode".utf8), .invalidBencode(.malformed(offset: 0)))
    }

    func testValidBencodeThatIsNotATorrent() {
        assertThrows(Data("i5e".utf8), .notATorrent)
        assertThrows(Data("d3:fooi1ee".utf8), .missingField("info"))
        assertThrows(Data("d4:infoi5ee".utf8), .invalidField("info"))
    }

    func testRequiredFieldsMustBePresent() {
        assertThrows(torrent(info: "d6:lengthi5e12:piece lengthi16384e\(pieces)e"), .missingField("name"))
        assertThrows(torrent(info: "d4:name3:abc12:piece lengthi16384e\(pieces)e"), .missingField("length or files"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc\(pieces)e"), .missingField("piece length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi16384ee"), .missingField("pieces"))
    }

    func testNumbersAndPieceDataMustMakeSense() {
        assertThrows(torrent(info: "d6:lengthi-5e4:name3:abc12:piece lengthi16384e\(pieces)e"), .invalidField("length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi0e\(pieces)e"), .invalidField("piece length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces3:abce"), .invalidField("pieces"))
        assertThrows(torrent(info: "d5:filesi5e4:name1:x12:piece lengthi16384e\(pieces)e"), .invalidField("files"))
    }

    func testAnEmptyFileListOrAnEmptyPathIsInvalid() {
        assertThrows(torrent(info: "d5:filesle4:name1:x12:piece lengthi16384e\(pieces)e"), .invalidField("files"))
        assertThrows(
            torrent(info: "d5:filesld6:lengthi1e4:pathleee4:name1:x12:piece lengthi16384e\(pieces)e"),
            .invalidField("path")
        )
    }

    func testTotalSizesThatOverflowAreRefused() {
        let info = "d5:filesld6:lengthi9223372036854775807e4:pathl1:aeed6:lengthi1e4:pathl1:beee4:name1:x12:piece lengthi16384e\(pieces)e"
        assertThrows(torrent(info: info), .invalidField("length"))
    }

    /// A torrent's names become paths on someone's disk. One that climbs out of
    /// its folder, or names something that is not a plain file name, is
    /// refused here rather than trusted to every later step.
    func testNamesThatCouldEscapeTheDownloadFolderAreRefused() {
        assertThrows(torrent(info: "d6:lengthi5e4:name6:../etc12:piece lengthi16384e\(pieces)e"), .unsafePath("../etc"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:a/b12:piece lengthi16384e\(pieces)e"), .unsafePath("a/b"))
        assertThrows(torrent(info: "d6:lengthi5e4:name2:..12:piece lengthi16384e\(pieces)e"), .unsafePath(".."))
        assertThrows(torrent(info: "d6:lengthi5e4:name1:.12:piece lengthi16384e\(pieces)e"), .unsafePath("."))
        assertThrows(torrent(info: "d6:lengthi5e4:name0:12:piece lengthi16384e\(pieces)e"), .unsafePath(""))
        assertThrows(
            torrent(info: "d5:filesld6:lengthi1e4:pathl2:..3:bbbeee4:name1:x12:piece lengthi16384e\(pieces)e"),
            .unsafePath("..")
        )
    }

    /// Version 2 torrents carry no v1 hash, and v1 hashes are all this app
    /// identifies by, so it says so instead of misreading one.
    func testAVersionTwoOnlyTorrentIsSaidToBeUnsupported() {
        let info = "d9:file treede12:meta versioni2e4:name1:x12:piece lengthi16384ee"
        assertThrows(torrent(info: info), .v2Only)
    }
}
