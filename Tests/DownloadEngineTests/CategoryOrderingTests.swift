import XCTest
@testable import DownloadEngine

/// Moving categories up and down, and what moving them actually changes.
///
/// The test that matters most is the last of the ordering ones: the whole
/// point of the arrows is that they decide which category wins a file that
/// fits two, so that is checked through the real router rather than assumed.
final class CategoryOrderingTests: XCTestCase {

    private func category(_ name: String, extensions: [String] = ["pdf"]) -> DownloadCategory {
        DownloadCategory(name: name, folderPath: "/Users/test/\(name)", extensions: extensions)
    }

    private func names(_ list: [DownloadCategory]) -> [String] { list.map(\.name) }

    // MARK: - Moving

    func testMovingDownSwapsWithTheNextOne() {
        let list = [category("A"), category("B"), category("C")]
        XCTAssertEqual(names(CategoryOrdering.moved(list[0].id, .down, in: list)), ["B", "A", "C"])
    }

    func testMovingUpSwapsWithThePreviousOne() {
        let list = [category("A"), category("B"), category("C")]
        XCTAssertEqual(names(CategoryOrdering.moved(list[2].id, .up, in: list)), ["A", "C", "B"])
    }

    func testTheTopCannotMoveUpAndTheBottomCannotMoveDown() {
        let list = [category("A"), category("B"), category("C")]
        XCTAssertFalse(CategoryOrdering.canMove(list[0].id, .up, in: list))
        XCTAssertFalse(CategoryOrdering.canMove(list[2].id, .down, in: list))
        XCTAssertTrue(CategoryOrdering.canMove(list[0].id, .down, in: list))
        XCTAssertTrue(CategoryOrdering.canMove(list[2].id, .up, in: list))
        XCTAssertTrue(CategoryOrdering.canMove(list[1].id, .up, in: list))
        XCTAssertTrue(CategoryOrdering.canMove(list[1].id, .down, in: list))
    }

    func testAnImpossibleMoveChangesNothing() {
        let list = [category("A"), category("B")]
        XCTAssertEqual(CategoryOrdering.moved(list[0].id, .up, in: list), list)
        XCTAssertEqual(CategoryOrdering.moved(list[1].id, .down, in: list), list)
    }

    func testAnUnknownCategoryCannotMoveAndChangesNothing() {
        let list = [category("A"), category("B")]
        let stranger = UUID()
        XCTAssertFalse(CategoryOrdering.canMove(stranger, .up, in: list))
        XCTAssertFalse(CategoryOrdering.canMove(stranger, .down, in: list))
        XCTAssertEqual(CategoryOrdering.moved(stranger, .down, in: list), list)
    }

    func testAListOfOneOrNoneCannotMoveAtAll() {
        let one = [category("A")]
        XCTAssertFalse(CategoryOrdering.canMove(one[0].id, .up, in: one))
        XCTAssertFalse(CategoryOrdering.canMove(one[0].id, .down, in: one))
        XCTAssertEqual(CategoryOrdering.moved(UUID(), .up, in: []), [])
    }

    func testMovingKeepsEveryCategoryExactlyAsItWas() {
        var list = [category("A"), category("B"), category("C")]
        list[1].extensions = ["zip"]
        let moved = CategoryOrdering.moved(list[1].id, .up, in: list)
        XCTAssertEqual(Set(moved.map(\.id)), Set(list.map(\.id)))
        XCTAssertEqual(moved.first { $0.id == list[1].id }, list[1], "only the position may change")
    }

    func testMovingACategoryChangesWhichOneWinsAFileThatFitsBoth() throws {
        let documents = category("Documents")
        let work = category("Work")
        let before = [documents, work]
        XCTAssertEqual(CategoryRouter.match(filename: "a.pdf", hosts: [], in: before)?.name, "Documents")

        let after = CategoryOrdering.moved(work.id, .up, in: before)

        XCTAssertEqual(CategoryRouter.match(filename: "a.pdf", hosts: [], in: after)?.name, "Work")
    }

    // MARK: - Dragging a row onto another

    func testDroppingOntoALowerRowPutsItJustBelowThatRow() {
        let list = [category("A"), category("B"), category("C"), category("D")]
        XCTAssertEqual(names(CategoryOrdering.moved(list[0].id, onto: list[2].id, in: list)), ["B", "C", "A", "D"])
    }

    func testDroppingOntoAHigherRowPutsItJustAboveThatRow() {
        let list = [category("A"), category("B"), category("C"), category("D")]
        XCTAssertEqual(names(CategoryOrdering.moved(list[3].id, onto: list[1].id, in: list)), ["A", "D", "B", "C"])
    }

    func testDroppingOntoANeighbourSwapsThem() {
        let list = [category("A"), category("B"), category("C")]
        XCTAssertEqual(names(CategoryOrdering.moved(list[0].id, onto: list[1].id, in: list)), ["B", "A", "C"])
        XCTAssertEqual(names(CategoryOrdering.moved(list[2].id, onto: list[1].id, in: list)), ["A", "C", "B"])
    }

    func testDroppingOntoItselfOrAStrangerChangesNothing() {
        let list = [category("A"), category("B")]
        XCTAssertEqual(CategoryOrdering.moved(list[0].id, onto: list[0].id, in: list), list)
        XCTAssertEqual(CategoryOrdering.moved(list[0].id, onto: UUID(), in: list), list)
        XCTAssertEqual(CategoryOrdering.moved(UUID(), onto: list[1].id, in: list), list)
        XCTAssertNil(CategoryOrdering.dropSide(of: list[0].id, onto: list[0].id, in: list))
        XCTAssertNil(CategoryOrdering.dropSide(of: UUID(), onto: list[1].id, in: list))
    }

    func testTheDropIndicatorAlwaysMatchesWhereTheRowActuallyLands() {
        // The line drawn while dragging and the move made on drop come from
        // different functions; this pins them together for every pair.
        let list = [category("A"), category("B"), category("C"), category("D")]
        for dragged in list {
            for target in list where target.id != dragged.id {
                let side = CategoryOrdering.dropSide(of: dragged.id, onto: target.id, in: list)
                let after = CategoryOrdering.moved(dragged.id, onto: target.id, in: list)
                let draggedIndex = after.firstIndex { $0.id == dragged.id }!
                let targetIndex = after.firstIndex { $0.id == target.id }!
                XCTAssertEqual(
                    side == .below, draggedIndex > targetIndex,
                    "\(dragged.name) onto \(target.name)"
                )
                XCTAssertEqual(abs(draggedIndex - targetIndex), 1, "it lands directly beside the target")
            }
        }
    }

    func testDroppingKeepsEveryCategoryExactlyAsItWas() {
        var list = [category("A"), category("B"), category("C")]
        list[2].extensions = ["zip"]
        let after = CategoryOrdering.moved(list[2].id, onto: list[0].id, in: list)
        XCTAssertEqual(Set(after.map(\.id)), Set(list.map(\.id)))
        XCTAssertEqual(after.first { $0.id == list[2].id }, list[2], "only the position may change")
        XCTAssertEqual(after.count, list.count)
    }

    func testDraggingChangesWhichOneWinsAFileThatFitsBoth() {
        let documents = category("Documents")
        let work = category("Work")
        let before = [documents, work]
        XCTAssertEqual(CategoryRouter.match(filename: "a.pdf", hosts: [], in: before)?.name, "Documents")

        let after = CategoryOrdering.moved(work.id, onto: documents.id, in: before)

        XCTAssertEqual(CategoryRouter.match(filename: "a.pdf", hosts: [], in: after)?.name, "Work")
    }

    // MARK: - Is sorting in effect

    func testSortingNeedsAtLeastOneCategoryWithAUsableFolder() {
        let usable = category("Usable")
        let noFolder = DownloadCategory(name: "NoFolder", folderPath: "", extensions: ["pdf"])
        let relative = DownloadCategory(name: "Relative", folderPath: "Music", extensions: ["pdf"])

        XCTAssertTrue(CategoryRouting.hasAnyRoutableCategory([usable]))
        XCTAssertTrue(CategoryRouting.hasAnyRoutableCategory([noFolder, relative, usable]))
        XCTAssertFalse(CategoryRouting.hasAnyRoutableCategory([noFolder]))
        XCTAssertFalse(CategoryRouting.hasAnyRoutableCategory([noFolder, relative]))
        XCTAssertFalse(CategoryRouting.hasAnyRoutableCategory([]))
    }
}
