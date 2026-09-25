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
    
    /// The single, shared implementation of "bring the main window to the
    /// front, creating it fresh if it doesn't exist yet." Every reopen
    /// trigger (menu bar button, Dock icon, `open Convoy.app`, future
    /// ones) should call this and nothing else — it used to be written out
    /// separately in StatusItemManager.openMainWindow() and
    /// AppDelegate.applicationShouldHandleReopen(), which is exactly how a
    /// real bug happened: the two copies drifted out of sync (one called
    /// NSApp.activate, the other forgot to), so the Dock/menu-bar paths
    /// behaved inconsistently for a background-but-not-minimized window.
    /// One implementation, both callers delegate to it, can't drift again.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        
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
            existing.makeKeyAndOrderFront(nil)
        } else if let url = URL(string: "convoy://open") {
            // No live window at all — genuinely closed. .handlesExternalEvents
            // (matching: ["*"]) on the WindowGroup turns this URL open into a
            // fresh window.
            NSWorkspace.shared.open(url)
        }
    }
}
