import XCTest
@testable import DownloadEngine

/// Tests for the info-hash rule in `DownloadIdentity`: a torrent is the same
/// download as another exactly when they are the same torrent, and for
/// nothing else.
///
/// Why names and URLs play no part: a torrent's folder is claimed fresh under
/// a free " (n)" name every time, so two torrents cannot collide on disk the
/// way two files can, and a torrent cannot be "resumed" from an HTTP download
/// or the other way round.
final class DownloadIdentityTorrentTests: XCTestCase {

    private let hashA = TorrentInfoHash(hex: "3facef60ceef085adc8d0bad64202f88ef953279")!
    private let hashB = TorrentInfoHash(hex: "2716855658cc83fb5cdeb6cf708a8dab27641cef")!

    private func identity(_ url: String, name: String, hash: TorrentInfoHash? = nil, size: Int64? = nil) -> DownloadIdentity {
        DownloadIdentity(url: URL(string: url)!, name: name, size: size, torrentInfoHash: hash)
    }

    func testTheSameHashIsTheSameDownloadWhateverTheURLAndName() {
        let fromMagnet = identity("magnet:?xt=urn:btih:\(hashA.hex)", name: "Some Show", hash: hashA)
        let fromFile = identity("https://example.com/other.torrent", name: "different name", hash: hashA)
        XCTAssertTrue(fromMagnet.isSameDownload(as: fromFile))
        XCTAssertTrue(fromFile.isSameDownload(as: fromMagnet))
    }

    /// The size veto exists to keep two renditions of one title apart. An
    /// identical hash is identical content, so it outranks any size.
    func testTheSameHashOutranksTheSizeVeto() {
        let a = identity("magnet:?xt=urn:btih:1", name: "x", hash: hashA, size: 5)
        let b = identity("magnet:?xt=urn:btih:2", name: "x", hash: hashA, size: 6)
        XCTAssertTrue(a.isSameDownload(as: b))
    }

    func testDifferentHashesAreDifferentDownloadsEvenWithTheSameURLAndName() {
        let a = identity("https://example.com/x.torrent", name: "Release", hash: hashA)
        let b = identity("https://example.com/x.torrent", name: "Release", hash: hashB)
        XCTAssertFalse(a.isSameDownload(as: b))
    }

    func testATorrentIsNeverTheSameDownloadAsOneWithoutAHash() {
        let torrent = identity("https://example.com/file.iso", name: "file.iso", hash: hashA)
        let plain = identity("https://example.com/file.iso", name: "file.iso")
        XCTAssertFalse(torrent.isSameDownload(as: plain))
        XCTAssertFalse(plain.isSameDownload(as: torrent))
    }

    func testWithoutHashesTheEarlierRulesStandUnchanged() {
        let a = identity("https://example.com/v.mp4", name: "v.mp4")
        XCTAssertTrue(a.isSameDownload(as: identity("https://example.com/v.mp4", name: "other.mp4")))
        XCTAssertTrue(a.isSameDownload(as: identity("https://example.org/else", name: "V.MP4")))
        XCTAssertFalse(a.isSameDownload(as: identity("https://example.org/else", name: "else.mp4")))
    }

    /// The requirement that started this: the same content added as a magnet
    /// link and as a `.torrent` file must be recognised as one download. The
    /// magnet carries no name, so nothing but the hash can make these equal.
    func testAMagnetAndATorrentFileForTheSameContentAreDuplicates() throws {
        let torrent = "d8:announce20:http://t.example/ann4:infod6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
        let file = try TorrentFile(Data(torrent.utf8))
        let magnet = try MagnetURI("magnet:?xt=urn:btih:H6WO6YGO54EFVXENBOWWIIBPRDXZKMTZ")

        let fromFile = DownloadIdentity(
            url: URL(fileURLWithPath: "/tmp/abc.torrent"), name: file.name, torrentInfoHash: file.infoHash)
        let fromMagnet = DownloadIdentity(
            url: URL(string: "magnet:?xt=urn:btih:H6WO6YGO54EFVXENBOWWIIBPRDXZKMTZ")!,
            name: magnet.displayName ?? "magnet link", torrentInfoHash: magnet.infoHash)

        XCTAssertNotEqual(fromFile.name, fromMagnet.name)
        XCTAssertTrue(fromMagnet.isSameDownload(as: fromFile))
    }
}
