import XCTest
@testable import DownloadEngine

final class TorrentPersistenceTests: XCTestCase {

    func testPersistedTorrentRoundTripsOptionalFields() throws {
        let hash = try XCTUnwrap(TorrentInfoHash(hex: "0123456789abcdef0123456789abcdef01234567"))
        let kind = DownloadKind.Torrent(
            infoHash: hash,
            infoHashV2: nil,
            magnetURI: "magnet:?xt=urn:btih:\(hash.hex)",
            storedTorrentPath: "/tmp/source.torrent",
            selectedFiles: [0, 2],
            wholeTorrentSize: 4096,
            hasClaimedFolder: true,
            pieceCount: 10
        )
        let bitfield = Data([0xFF, 0xC0])
        let persisted = PersistedDownloadTask.PersistedTorrent(
            from: kind,
            wasSeeding: true,
            uploadedBytes: 1024,
            pieceBitfield: bitfield
        )

        let data = try JSONEncoder().encode(persisted)
        let decoded = try JSONDecoder().decode(PersistedDownloadTask.PersistedTorrent.self, from: data)
        XCTAssertEqual(decoded, persisted)
        XCTAssertEqual(decoded.uploadedBytes, 1024)
        XCTAssertEqual(decoded.pieceBitfield, bitfield)
        XCTAssertEqual(decoded.pieceCount, 10)
    }

    func testPersistedTorrentDecodesLegacySnapshotWithoutOptionalFields() throws {
        let legacyJSON = """
        {
            "infoHashHex": "0123456789abcdef0123456789abcdef01234567",
            "hasClaimedFolder": false
        }
        """
        let decoded = try JSONDecoder().decode(
            PersistedDownloadTask.PersistedTorrent.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertEqual(decoded.infoHashHex, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertNil(decoded.uploadedBytes)
        XCTAssertNil(decoded.pieceBitfield)
        XCTAssertNil(decoded.pieceCount)
    }
}
