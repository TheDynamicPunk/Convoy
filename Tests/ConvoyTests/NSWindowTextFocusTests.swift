import AppKit
import XCTest
@testable import Convoy

@MainActor
final class NSWindowTextFocusTests: XCTestCase {

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }

    func testReleasingTextFocusEndsEditingAField() {
        let window = makeWindow()
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(window.firstResponder is NSText, "a field being edited is answered by its field editor")

        window.releaseTextFocus()

        XCTAssertFalse(window.firstResponder is NSText)
    }

    func testReleasingTextFocusLeavesAnythingElseFocused() {
        let window = makeWindow()
        let view = FocusableView(frame: NSRect(x: 10, y: 10, width: 50, height: 50))
        window.contentView?.addSubview(view)
        XCTAssertTrue(window.makeFirstResponder(view))

        window.releaseTextFocus()

        XCTAssertTrue(window.firstResponder === view)
    }
}
