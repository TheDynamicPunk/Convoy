import SwiftUI
import AppKit

/// An invisible SwiftUI view whose only job is to reach into AppKit and
/// hand back the real `NSWindow` hosting it — the standard, reliable way to
/// bridge "which actual window is this SwiftUI content living in right now"
/// without any private-API or string-matching guesswork.
///
/// `updateNSView` (not just `makeNSView`) is what makes this correct across
/// window recreation: SwiftUI calls it again whenever this view's window
/// changes, including every time the WindowGroup spins up a fresh NSWindow
/// instance after the previous one was closed (Cmd+W) — so the callback
/// always fires with the currently-live window, not just the first one ever
/// created.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
