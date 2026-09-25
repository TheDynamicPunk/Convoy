import AppKit
import XCTest
@testable import Convoy

/// Calls the list responder's key and menu methods directly: no window, and
/// nothing is posted to the system.
@MainActor
final class ListKeyResponderTests: XCTestCase {
    private var calls: [String] = []
    private var canSelectAll = true
    private var canDelete = true
    private var view: ListResponderView!
    private var next: Recorder!

    override func setUp() {
        super.setUp()
        calls = []
        view = ListResponderView()
        next = Recorder()
        // Keys the list doesn't take go here rather than to a beep.
        view.nextResponder = next
        refreshHandlers()
    }

    private func refreshHandlers() {
        view.handlers = ListKeyResponder(
            canSelectAll: canSelectAll,
            canDelete: canDelete,
            onArrow: { [unowned self] direction, extend in calls.append("arrow \(direction) \(extend)") },
            onEscape: { [unowned self] in calls.append("escape") },
            onDelete: { [unowned self] in calls.append("delete") },
            onSelectAll: { [unowned self] in calls.append("selectAll") },
            onFocusChange: { _ in }
        )
    }

    private func press(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }

    private let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private let forwardDelete = String(UnicodeScalar(NSDeleteFunctionKey)!)
    private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    func testArrowsMoveAndShiftExtends() {
        press(down, code: 125, arrowFlags)
        press(up, code: 126, arrowFlags)
        press(down, code: 125, arrowFlags.union(.shift))
        XCTAssertEqual(calls, ["arrow 1 false", "arrow -1 false", "arrow 1 true"])
        XCTAssertTrue(next.keyCodes.isEmpty)
    }

    func testEscapeClears() {
        press("\u{1B}", code: 53)
        XCTAssertEqual(calls, ["escape"])
    }

    func testDeleteAndForwardDeleteDelete() {
        press("\u{7F}", code: 51)
        press(forwardDelete, code: 117, [.function])
        XCTAssertEqual(calls, ["delete", "delete"])
    }

    func testOtherKeysAndCommandCombosPassOn() {
        press("a", code: 0)
        press(up, code: 126, arrowFlags.union(.command))
        press("\u{7F}", code: 51, [.command])
        XCTAssertEqual(calls, [])
        XCTAssertEqual(next.keyCodes, [0, 126, 51])
    }

    func testMenuActions() {
        view.selectAll(nil)
        view.delete(nil)
        view.cancelOperation(nil)
        XCTAssertEqual(calls, ["selectAll", "delete", "escape"])
    }

    func testMenuValidationFollowsListState() {
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        let delete = NSMenuItem(title: "Delete", action: #selector(ListResponderView.delete(_:)), keyEquivalent: "")
        XCTAssertTrue(view.validateMenuItem(selectAll))
        XCTAssertTrue(view.validateMenuItem(delete))

        canSelectAll = false
        canDelete = false
        refreshHandlers()
        XCTAssertFalse(view.validateMenuItem(selectAll))
        XCTAssertFalse(view.validateMenuItem(delete))
    }

    func testAcceptsFirstResponder() {
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    func testUnclaimedFocus() {
        let root = NSView()
        let column = NSView()
        let sidebar = NSView()
        root.addSubview(column)
        root.addSubview(sidebar)
        column.addSubview(view)

        // Nothing, or a view that only contains the list: no real home.
        XCTAssertTrue(ListResponderView.isUnclaimed(nil, in: nil, around: view))
        XCTAssertTrue(ListResponderView.isUnclaimed(root, in: nil, around: view))
        XCTAssertTrue(ListResponderView.isUnclaimed(column, in: nil, around: view))
        // The list itself, or another control, is a real home.
        XCTAssertFalse(ListResponderView.isUnclaimed(view, in: nil, around: view))
        XCTAssertFalse(ListResponderView.isUnclaimed(sidebar, in: nil, around: view))
        XCTAssertFalse(ListResponderView.isUnclaimed(NSResponder(), in: nil, around: view))
    }
}

private final class Recorder: NSResponder {
    var keyCodes: [UInt16] = []
    override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}
