import Foundation
@testable import DownloadEngine

/// Hand-built `.torrent` files shared by the tests that read, identify or
/// download torrents.
///
/// All text, so a failing test can be read. The hashes were computed
/// independently with Python's hashlib over the exact bytes of each `info`
/// dictionary, so they check the code against something other than itself.
enum TorrentFixtures {

    static let pieces = "6:pieces20:aaaaaaaaaaaaaaaaaaaa"

    // MARK: A: one file, canonical key order

    static let infoA = "d6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaae"
    static let torrentA = "d8:announce20:http://t.example/ann4:infod6:lengthi5e4:name3:abc12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    static let hashA = "3facef60ceef085adc8d0bad64202f88ef953279"
    static let base32A = "H6WO6YGO54EFVXENBOWWIIBPRDXZKMTZ"

    // MARK: B: two files, one in a sub-folder, trackers only in announce-list

    static let torrentB = "d13:announce-listll19:http://t1.example/a19:http://t2.example/ael19:udp://t3.example:80ee4:infod5:filesld6:lengthi3e4:pathl1:a5:b.txteed6:lengthi4e4:pathl5:c.bineee4:name4:pack12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    static let hashB = "2716855658cc83fb5cdeb6cf708a8dab27641cef"

    // MARK: C: the same content as A, but the info keys are out of sorted order

    /// Hashing a re-encoded copy would give a different answer from hashing the
    /// bytes as written, and only the second is right. Its name and size match
    /// A's, so it also stands in for "a different torrent whose file would land
    /// on A's".
    static let torrentC = "d4:infod4:name3:abc6:lengthi5e12:piece lengthi16384e6:pieces20:aaaaaaaaaaaaaaaaaaaaee"
    static let hashC = "89e247aba9b108e9a4667cb926b66def9b0b2c32"

    static var dataA: Data { Data(torrentA.utf8) }
    static var dataB: Data { Data(torrentB.utf8) }
    static var dataC: Data { Data(torrentC.utf8) }
}
