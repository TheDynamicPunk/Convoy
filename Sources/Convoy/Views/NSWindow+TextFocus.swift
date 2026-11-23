import AppKit

extension NSWindow {
    /// Takes focus off the text field being edited, if there is one. A field
    /// commits what was typed as it lets go, so this is also how a click
    /// elsewhere finishes an edit. Anything else holding focus is left alone.
    func releaseTextFocus() {
        if firstResponder is NSText { makeFirstResponder(nil) }
    }
}
