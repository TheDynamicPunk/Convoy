import AppKit

/// Tracks the real `NSWindow` hosting SwiftUI's `Settings { }` scene so it can
/// be ordered to the front above a browser window after a URL-scheme deep-link.
@MainActor
final class SettingsWindowTracker {
    static let shared = SettingsWindowTracker()

    private init() {}

    private(set) weak var settingsWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func register(_ window: NSWindow) {
        guard window !== settingsWindow else { return }

        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }

        settingsWindow = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsWindow = nil }
        }
    }

    /// Orders the Settings window to the front and gives it key focus.
    /// Re-asserts at +0.1 s and +0.25 s to beat focus-hand-off races from the browser.
    func bringToFront() {
        activateAndOrder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in self?.activateAndOrder() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.activateAndOrder() }
    }

    private func activateAndOrder() {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)

        let target = settingsWindow ?? NSApp.windows.first {
            $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" || $0.title.contains("Settings")
        }
        guard let window = target else { return }
        if settingsWindow == nil { register(window) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}
