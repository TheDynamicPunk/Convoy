import AppKit

/// How the app asks to become the active app.
///
/// macOS 14 made activation cooperative: a plain `NSApp.activate()` is only
/// honoured when the person has just interacted with this app, or when another
/// app explicitly opens it (via NSWorkspace.open or a URL scheme). It is
/// silently declined otherwise, which includes a full-screen browser being
/// frontmost while the request arrives over a background IPC channel.
///
/// `NSRunningApplication.activate(from:options:)` names the app the person was
/// just using as the sender of the hand-off, and the capture and prompt paths
/// use it with the browser as the sender. What has been checked by hand is
/// that this works with a full-screen Chrome in front *together with* the
/// policy lift in `DockIconPolicy` when the Dock icon is hidden. The two
/// haven't been separated, so don't assume either one alone is enough.
///
/// Settings additionally asks AppKit for all of its windows
/// (`SettingsWindowTracker`), so it calls `NSRunningApplication` directly as
/// well as through here.
@MainActor
enum AppActivation {
    /// Activates Convoy, naming `senderApp` as the app the person was just
    /// using. With no sender, or when the sender is Convoy itself (it can
    /// already be frontmost when the menu bar button is clicked), there is no
    /// hand-off to name, so it falls back to plain `NSApp.activate()`.
    static func activate(from senderApp: NSRunningApplication? = nil) {
        if let sender = senderApp, sender != .current {
            NSRunningApplication.current.activate(from: sender, options: [])
        } else {
            NSApp.activate()
        }
    }
}
