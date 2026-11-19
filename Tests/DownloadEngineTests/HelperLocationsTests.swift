import XCTest
@testable import DownloadEngine

final class HelperLocationsTests: XCTestCase {

    /// rqbit is installed the way quickjs and bgutil-pot are: one executable
    /// directly in the helper folder.
    func testTheTorrentEngineSitsBesideTheOtherSingleFileHelpers() {
        let rqbit = URL(fileURLWithPath: HelperLocations.rqbit)
        XCTAssertEqual(rqbit.lastPathComponent, "rqbit")
        XCTAssertEqual(rqbit.deletingLastPathComponent().path, HelperLocations.binDirectory.path)
    }

    /// Convoy's own copy of each torrent's source lives under the support
    /// folder next to `bin` and `run`, not inside either: `bin` holds helper
    /// binaries that installs replace and `run` holds process records that are
    /// swept at launch, and a torrent's source has to outlive both.
    func testTorrentStateLivesBesideBinAndRunNotInsideThem() {
        let torrents = HelperLocations.torrentsDirectory
        XCTAssertEqual(torrents.lastPathComponent, "torrents")
        XCTAssertEqual(
            torrents.deletingLastPathComponent().path,
            HelperLocations.binDirectory.deletingLastPathComponent().path
        )
        XCTAssertEqual(
            torrents.deletingLastPathComponent().path,
            HelperLocations.runDirectory.deletingLastPathComponent().path
        )
    }
}
