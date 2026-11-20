import XCTest
@testable import DownloadEngine

/// Tests for reading a `.torrent` file: what is in it, and which torrent it is.
///
/// The expected info hashes in the fixtures were computed independently with
/// Python's hashlib over the exact bytes of each `info` dictionary, so they
/// check the parser against something other than itself.
final class TorrentFileTests: XCTestCase {

    // MARK: - Fixtures (shared: see TorrentFixtures)

    private func torrent(info: String) -> Data { Data("d4:info\(info)e".utf8) }

    private func assertThrows(_ data: Data, _ expected: TorrentFileError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TorrentFile(data), file: file, line: line) { error in
            XCTAssertEqual(error as? TorrentFileError, expected, file: file, line: line)
        }
    }

    // MARK: - A single file

    func testReadsASingleFileTorrent() throws {
        let file = try TorrentFile(Data(TorrentFixtures.torrentA.utf8))

        XCTAssertEqual(file.infoHash.hex, TorrentFixtures.hashA)
        XCTAssertEqual(file.name, "abc")
        XCTAssertEqual(file.files, [TorrentFile.Entry(path: ["abc"], length: 5)])
        XCTAssertEqual(file.totalSize, 5)
        XCTAssertFalse(file.isMultiFile)
        XCTAssertFalse(file.isPrivate)
        XCTAssertEqual(file.trackers, ["http://t.example/ann"])
    }

    // MARK: - Several files

    func testReadsAMultiFileTorrentInOrder() throws {
        let file = try TorrentFile(Data(TorrentFixtures.torrentB.utf8))

        XCTAssertEqual(file.infoHash.hex, TorrentFixtures.hashB)
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
        let data = Data("d8:announce19:http://t1.example/a13:announce-listll19:http://t1.example/a19:http://t2.example/aee4:info\(TorrentFixtures.infoA)e".utf8)
        XCTAssertEqual(try TorrentFile(data).trackers, ["http://t1.example/a", "http://t2.example/a"])

        XCTAssertEqual(
            try TorrentFile(Data(TorrentFixtures.torrentB.utf8)).trackers,
            ["http://t1.example/a", "http://t2.example/a", "udp://t3.example:80"]
        )
    }

    func testAPrivateTorrentIsMarkedPrivate() throws {
        let info = "d6:lengthi5e4:name3:abc12:piece lengthi16384e\(TorrentFixtures.pieces)7:privatei1ee"
        XCTAssertTrue(try TorrentFile(torrent(info: info)).isPrivate)
    }

    func testBEP47PaddingFilesStayIndexedButAreExcludedFromTotalSize() throws {
        let files =
            "d6:lengthi10e4:pathl5:a.binee"
            + "d4:attr1:p6:lengthi6e4:pathl4:.pad1:6ee"
            + "d4:attr1:x6:lengthi4e4:pathl5:b.binee"
            + "d4:attr2:ph6:lengthi12e4:pathl4:.pad2:12ee"
        let info = "d5:filesl\(files)e4:name4:pack12:piece lengthi16384e\(TorrentFixtures.pieces)e"

        let file = try TorrentFile(torrent(info: info))

        XCTAssertEqual(file.files.count, 4)
        XCTAssertEqual(file.files.map(\.isPadding), [false, true, false, true])
        XCTAssertEqual(file.files.map(\.displayPath), ["a.bin", ".pad/6", "b.bin", ".pad/12"])
        XCTAssertEqual(file.totalSize, 14)
    }

    func testUTF8NameAndPathKeysTakePrecedenceOverLegacyKeys() throws {
        let utf8Name = "café"
        let utf8ByteCount = utf8Name.utf8.count
        let singleWithBoth = "d6:lengthi5e4:name6:legacy10:name.utf-8\(utf8ByteCount):\(utf8Name)12:piece lengthi16384e\(TorrentFixtures.pieces)e"
        let single = try TorrentFile(torrent(info: singleWithBoth))
        XCTAssertEqual(single.name, utf8Name)
        XCTAssertEqual(single.files, [TorrentFile.Entry(path: [utf8Name], length: 5)])

        let singleUTF8Only = "d6:lengthi5e10:name.utf-8\(utf8ByteCount):\(utf8Name)12:piece lengthi16384e\(TorrentFixtures.pieces)e"
        XCTAssertEqual(try TorrentFile(torrent(info: singleUTF8Only)).name, utf8Name)

        let utf8File = "café.txt"
        let multi = "d5:filesld6:lengthi3e4:pathl7:old.txte10:path.utf-8l3:dir\(utf8File.utf8.count):\(utf8File)eee10:name.utf-8\(utf8ByteCount):\(utf8Name)12:piece lengthi16384e\(TorrentFixtures.pieces)e"
        let parsedMulti = try TorrentFile(torrent(info: multi))
        XCTAssertEqual(parsedMulti.name, utf8Name)
        XCTAssertEqual(parsedMulti.files, [TorrentFile.Entry(path: ["dir", utf8File], length: 3)])
    }

    // MARK: - The bytes it was read from

    /// A torrent resolved from a magnet link is saved, and later added, exactly
    /// as it was received. Rebuilding it from the parsed fields would change
    /// the bytes, and with them the hash.
    func testKeepsTheBytesItWasReadFrom() throws {
        XCTAssertEqual(try TorrentFile(TorrentFixtures.dataA).source, TorrentFixtures.dataA)
    }

    /// A `Data` that is a slice of a bigger buffer counts its indexes from
    /// wherever the slice starts, which must not shift where the info
    /// dictionary is found.
    func testReadsATorrentThatIsASliceOfALargerBuffer() throws {
        var padded = Data("padding before the torrent".utf8)
        let start = padded.count
        padded.append(TorrentFixtures.dataA)
        padded.append(Data("and after".utf8))
        let slice = padded[start..<(start + TorrentFixtures.dataA.count)]
        XCTAssertNotEqual(slice.startIndex, 0)

        let file = try TorrentFile(slice)

        XCTAssertEqual(file.infoHash.hex, TorrentFixtures.hashA)
        XCTAssertEqual(file.source, TorrentFixtures.dataA)
    }

    // MARK: - Which torrent it is

    /// The hash is over the bytes as they were written, not over a tidied copy.
    func testTheHashCoversTheInfoBytesAsWrittenEvenWhenTheirKeysAreOutOfOrder() throws {
        XCTAssertEqual(try TorrentFile(Data(TorrentFixtures.torrentC.utf8)).infoHash.hex, TorrentFixtures.hashC)
    }

    /// The case duplicate detection exists for: the same content arriving once
    /// as a magnet link and once as a file.
    func testAMagnetLinkAndATorrentFileForTheSameContentHaveOneIdentity() throws {
        let fromFile = try TorrentFile(Data(TorrentFixtures.torrentA.utf8))
        let fromBase32 = try MagnetURI("magnet:?xt=urn:btih:\(TorrentFixtures.base32A)")
        let fromHex = try MagnetURI("magnet:?xt=urn:btih:\(TorrentFixtures.hashA)&dn=abc")

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
        assertThrows(torrent(info: "d6:lengthi5e12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .missingField("name"))
        assertThrows(torrent(info: "d4:name3:abc12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .missingField("length or files"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc\(TorrentFixtures.pieces)e"), .missingField("piece length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi16384ee"), .missingField("pieces"))
    }

    func testNumbersAndPieceDataMustMakeSense() {
        assertThrows(torrent(info: "d6:lengthi-5e4:name3:abc12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .invalidField("length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi0e\(TorrentFixtures.pieces)e"), .invalidField("piece length"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces3:abce"), .invalidField("pieces"))
        assertThrows(torrent(info: "d5:filesi5e4:name1:x12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .invalidField("files"))
    }

    func testAnEmptyFileListOrAnEmptyPathIsInvalid() {
        assertThrows(torrent(info: "d5:filesle4:name1:x12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .invalidField("files"))
        assertThrows(
            torrent(info: "d5:filesld6:lengthi1e4:pathleee4:name1:x12:piece lengthi16384e\(TorrentFixtures.pieces)e"),
            .invalidField("path")
        )
    }

    func testTotalSizesThatOverflowAreRefused() {
        let info = "d5:filesld6:lengthi9223372036854775807e4:pathl1:aeed6:lengthi1e4:pathl1:beee4:name1:x12:piece lengthi16384e\(TorrentFixtures.pieces)e"
        assertThrows(torrent(info: info), .invalidField("length"))
    }

    /// A torrent's names become paths on someone's disk. One that climbs out of
    /// its folder, or names something that is not a plain file name, is
    /// refused here rather than trusted to every later step.
    func testNamesThatCouldEscapeTheDownloadFolderAreRefused() {
        assertThrows(torrent(info: "d6:lengthi5e4:name6:../etc12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .unsafePath("../etc"))
        assertThrows(torrent(info: "d6:lengthi5e4:name3:a/b12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .unsafePath("a/b"))
        assertThrows(torrent(info: "d6:lengthi5e4:name2:..12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .unsafePath(".."))
        assertThrows(torrent(info: "d6:lengthi5e4:name1:.12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .unsafePath("."))
        assertThrows(torrent(info: "d6:lengthi5e4:name0:12:piece lengthi16384e\(TorrentFixtures.pieces)e"), .unsafePath(""))
        assertThrows(
            torrent(info: "d5:filesld6:lengthi1e4:pathl2:..3:bbbeee4:name1:x12:piece lengthi16384e\(TorrentFixtures.pieces)e"),
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
