import AppKit

/// Holds a live reference to the app's actual main content window, captured
/// directly from AppKit at the moment SwiftUI creates it — via
/// `WindowAccessor` in `ConvoyApp.swift`.
///
/// This replaces two earlier, both-fragile approaches: first guessing at a
/// private AppKit window class name, then guessing at the exact identifier
/// string SwiftUI assigns a `WindowGroup(id:)` window instance (which turned
/// out to vary — a freshly recreated window after Cmd+W didn't reliably
/// carry the same identifier, causing duplicate windows). Holding the actual
/// object reference sidesteps string-matching of any kind: there's nothing
/// to guess, we're just remembering the window AppKit already handed us.
@MainActor
final class MainWindowTracker {
    static let shared = MainWindowTracker()
    
    private init() {}
    
    /// Weak so this never keeps a closed window alive by accident — also
    /// explicitly nil'd in the notification observer below rather than
    /// relying purely on weak-reference deallocation timing, so
    /// `openMainWindow()` can never observe a stale reference to a window
    /// that's mid-close.
    private(set) weak var mainWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    
    /// Called by `WindowAccessor` every time the main WindowGroup's content
    /// view appears in a window — including the very first launch and every
    /// subsequent recreation after the previous window was closed. Always
    /// keeps this pointed at whichever window instance is actually current.
    ///
    /// Deliberately observes NSWindow.willCloseNotification rather than
    /// becoming the window's NSWindowDelegate — assigning .delegate would
    /// silently overwrite any delegate SwiftUI itself sets on the window
    /// (now or in a future macOS version), which is exactly the kind of
    /// fragile side-effect this whole fix is meant to eliminate.
    func register(_ window: NSWindow) {
        guard window !== mainWindow else { return }
        
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        
        mainWindow = window
        // A new window is one of the moments the Dock icon has come back after
        // being hidden. The correction re-activates the app, so this window
        // stays in front.
        DockIconPolicy.restoreIfDrifted()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this closure *runs* on the main
            // thread at runtime, but that's not something the Swift
            // compiler can verify statically as satisfying @MainActor
            // isolation — hence the warning. Task { @MainActor in ... }
            // makes the hop explicit and compiler-checked instead of
            // relying on an implicit runtime guarantee the type system
            // can't see.
            Task { @MainActor in
                self?.mainWindow = nil
            }
        }
    }
    
    /// The single entry point for "bring the main window to the front,
    /// creating it fresh if it doesn't exist yet." Every trigger (a capture,
    /// a prompt that needs an answer, the menu bar button, a reopen from the
    /// Dock, Finder or Spotlight, future ones) calls this and nothing else.
    /// It used to be written out separately in
    /// StatusItemManager.openMainWindow() and
    /// AppDelegate.applicationShouldHandleReopen(), which is exactly how a
    /// real bug happened: the two copies drifted out of sync (one called
    /// NSApp.activate, the other forgot to), so the Dock/menu-bar paths
    /// behaved inconsistently for a background-but-not-minimized window.
    /// One implementation, every caller delegates to it, can't drift again.
    ///
    /// With "Hide Dock icon" on, the app is lifted to a regular one first (see
    /// `DockIconPolicy.showElevatedIfHidden`): an accessory app can't leave a
    /// full-screen browser's Space or take key focus, so none of the triggers
    /// above could work without it. With the icon shown, or already lifted,
    /// this goes straight to `presentMainWindow()`.
    func showMainWindow() {
        DockIconPolicy.showElevatedIfHidden { [self] in presentMainWindow() }
    }

    /// Orders the window front (deminiaturizing it, or opening a fresh one if
    /// it is gone) and activates the app. Private so nothing can reach it
    /// without going through `showMainWindow()`'s policy handling.
    private func presentMainWindow() {
        if let existing = mainWindow {
            // Checked separately from isVisible: a minimized window still
            // exists as a real object (isVisible is false for a
            // miniaturized window, so relying on that alone incorrectly
            // treats "merely minimized" as "gone"). deminiaturize handles
            // un-minimizing; makeKeyAndOrderFront handles bringing a
            // background (but not minimized/closed) window forward.
            if existing.isMiniaturized {
                existing.deminiaturize(nil)
            }
            // Order the window front before activating: the window must
            // already be positioned at the top before we raise the app,
            // otherwise macOS may bring forward a different window.
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "convoy://open") {
            // No live window at all — genuinely closed. .handlesExternalEvents
            // (matching: ["*"]) on the WindowGroup turns this URL open into a
            // fresh window.
            // Checked once the system has finished the open, because this
            // reopen path is where the Dock icon has come back. The window
            // and activation checks can both run before the open lands.
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                Task { @MainActor in
                    DockIconPolicy.restoreIfDrifted()
                }
            }
        }
        // Activate after the window is ordered front.
        //
        // activate(from:) rather than the bare NSApp.activate(): it names the
        // currently-frontmost app as the sender, which is who the person was
        // just using (the browser that triggered the capture). See
        // AppActivation for what has and hasn't been verified about it.
        AppActivation.activate(from: NSWorkspace.shared.frontmostApplication)
    }
}
