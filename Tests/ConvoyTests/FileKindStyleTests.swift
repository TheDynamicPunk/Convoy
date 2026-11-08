import XCTest
import DownloadEngine
@testable import Convoy

/// Every kind of file needs its own look, or two different kinds would be
/// indistinguishable in the list.
final class FileKindStyleTests: XCTestCase {

    func testEveryKindHasASymbol() {
        for kind in FileKind.allCases {
            XCTAssertFalse(kind.symbol.isEmpty, "\(kind)")
        }
    }

    func testNoTwoKindsShareASymbol() {
        let symbols = FileKind.allCases.map(\.symbol)
        XCTAssertEqual(Set(symbols).count, symbols.count, "\(symbols)")
    }

    func testCodeFilesGetTheirOwnLookNotTheFallbackOne() {
        XCTAssertNotEqual(FileKind.code.symbol, FileKind.other.symbol)
    }
}
