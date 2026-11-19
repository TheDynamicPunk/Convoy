import XCTest
@testable import DownloadEngine

/// Tests for the bencode reader behind `.torrent` files.
///
/// It exists for two reasons beyond reading values: the torrent's identity is
/// a hash of the exact bytes of its `info` dictionary, so the reader reports
/// where that dictionary sits in the input, and it reads files that came off
/// the internet, so it must refuse hostile ones without crashing or running
/// out of memory.
final class BencodeTests: XCTestCase {

    private func decode(_ text: String) throws -> Bencode.Value {
        try Bencode.decode(Data(text.utf8)).value
    }

    private func assertThrows(_ text: String, _ expected: Bencode.DecodeError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try Bencode.decode(Data(text.utf8)), file: file, line: line) { error in
            XCTAssertEqual(error as? Bencode.DecodeError, expected, file: file, line: line)
        }
    }

    // MARK: - Values

    func testIntegers() throws {
        XCTAssertEqual(try decode("i42e"), .integer(42))
        XCTAssertEqual(try decode("i-7e"), .integer(-7))
        XCTAssertEqual(try decode("i0e"), .integer(0))
        XCTAssertEqual(try decode("i9223372036854775807e"), .integer(Int64.max))
    }

    func testByteStringsMayHoldAnyBytes() throws {
        XCTAssertEqual(try decode("4:spam"), .bytes(Data("spam".utf8)))
        XCTAssertEqual(try decode("0:"), .bytes(Data()))
        XCTAssertEqual(
            try Bencode.decode(Data([0x32, 0x3a, 0x00, 0xff])).value,
            .bytes(Data([0x00, 0xff]))
        )
    }

    func testListsAndDictionariesNest() throws {
        let value = try decode("d3:bagl1:a1:bi1ee3:cow3:mooe")
        XCTAssertEqual(value["cow"]?.string, "moo")
        XCTAssertEqual(value["bag"]?.list, [.bytes(Data("a".utf8)), .bytes(Data("b".utf8)), .integer(1)])
        XCTAssertNil(value["missing"])
    }

    func testAccessorsReturnNilForTheWrongKind() throws {
        let value = try decode("i5e")
        XCTAssertEqual(value.integer, 5)
        XCTAssertNil(value.string)
        XCTAssertNil(value.list)
        XCTAssertNil(value["x"])
    }

    func testAStringThatIsNotUTF8HasNoStringFormButKeepsItsBytes() throws {
        let value = try Bencode.decode(Data([0x31, 0x3a, 0xff])).value
        XCTAssertNil(value.string)
        XCTAssertEqual(value.bytes, Data([0xff]))
    }

    // MARK: - Where the top-level values sit

    func testReportsTheExactBytesOfEachTopLevelValue() throws {
        let info = "d6:lengthi5e4:name3:abce"
        let input = Data("d4:infod6:lengthi5e4:name3:abce3:zzzi1ee".utf8)

        let decoded = try Bencode.decode(input)

        let range = try XCTUnwrap(decoded.topLevelRanges["info"])
        XCTAssertEqual(Data(input[range]), Data(info.utf8))
        XCTAssertEqual(Data(input[try XCTUnwrap(decoded.topLevelRanges["zzz"])]), Data("i1e".utf8))
    }

    /// Only the outermost dictionary is indexed; an `info` nested deeper is
    /// somebody else's key and must not be mistaken for the real one.
    func testNestedKeysAreNotReportedAsTopLevel() throws {
        let decoded = try Bencode.decode(Data("d5:outerd4:infoi1eee".utf8))
        XCTAssertNil(decoded.topLevelRanges["info"])
        XCTAssertNotNil(decoded.topLevelRanges["outer"])
    }

    func testAnInputThatIsNotADictionaryHasNoTopLevelRanges() throws {
        XCTAssertTrue(try Bencode.decode(Data("li1ee".utf8)).topLevelRanges.isEmpty)
    }

    // MARK: - Hostile and broken input

    func testEmptyInput() {
        assertThrows("", .empty)
    }

    func testTruncatedInput() {
        assertThrows("i42", .truncated)
        assertThrows("5:abc", .truncated)
        assertThrows("l1:a", .truncated)
        assertThrows("d3:key", .truncated)
        assertThrows("5", .truncated)
    }

    func testTrailingBytesAfterTheValue() {
        assertThrows("i1eXYZ", .trailingData)
    }

    func testAnUnknownTokenIsReportedWithItsPosition() {
        assertThrows("lxe", .malformed(offset: 1))
    }

    func testBadIntegers() {
        assertThrows("ie", .malformed(offset: 1))
        assertThrows("i-e", .malformed(offset: 2))
        assertThrows("i1x2e", .malformed(offset: 2))
        assertThrows("i99999999999999999999e", .malformed(offset: 1))
    }

    /// A length prefix is a claim, not a fact. One that is larger than the
    /// whole input, or than any integer, must not reach an allocation.
    func testAStringLengthLargerThanTheInputIsRefused() {
        assertThrows("99999999:abc", .truncated)
        assertThrows("99999999999999999999:abc", .malformed(offset: 0))
    }

    func testNestingDeepEnoughToExhaustTheStackIsRefused() {
        assertThrows(String(repeating: "l", count: 10_000), .tooDeep)
        assertThrows(String(repeating: "d1:a", count: 10_000), .tooDeep)
    }

    func testADictionaryKeyThatIsNotAStringIsRefused() {
        assertThrows("di1ei2ee", .malformed(offset: 1))
    }

    /// Two `info` keys would let one reading hash one dictionary and another
    /// reading describe a different one.
    func testADuplicateKeyIsRefused() {
        assertThrows("d1:ai1e1:ai2ee", .duplicateKey("a"))
    }

    func testInputLargerThanAnyRealTorrentIsRefusedUpFront() {
        let huge = Data(count: Bencode.maxInputSize + 1)
        XCTAssertThrowsError(try Bencode.decode(huge)) { error in
            XCTAssertEqual(error as? Bencode.DecodeError, .tooLarge)
        }
    }
}
