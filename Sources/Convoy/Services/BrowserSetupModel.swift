import AppKit
import DownloadEngine

/// State behind the first-launch browser sheet and Settings → Browser.
@MainActor
final class BrowserSetupModel: ObservableObject {
    static let shared = BrowserSetupModel()

    struct Row: Identifiable {
        let browser: BrowserIntegration.Browser
        let status: BrowserIntegration.Status
        let icon: NSImage?
        var id: String { browser.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published var isShowingFirstRunSheet = false
    /// The last Set Up / Remove failure, for an alert.
    @Published var errorMessage: String?

    private let integration = BrowserIntegration()

    /// Not an AppSettings key: restoring defaults shouldn't offer setup again.
    private static let offeredKey = "browserSetupOffered"

    var isLocationStable: Bool { integration.isLocationStable }
    var extensionFolder: URL { integration.extensionFolder }

    /// Syncs the extension folder and repoints existing files off the main
    /// thread, then offers first-run setup once there's a browser to set up.
    func launch() {
        let integration = integration
        Task {
            await Task.detached(priority: .utility) {
                do { try integration.syncExtension() } catch {
                    appLogger.error("Extension folder sync failed: \(error.localizedDescription)")
                }
                let repaired = integration.repairExisting()
                if !repaired.isEmpty {
                    appLogger.notice("Repointed browser files: \(repaired.map(\.name).joined(separator: ", "), privacy: .public)")
                }
            }.value
            refresh()
            if !UserDefaults.standard.bool(forKey: Self.offeredKey), !rows.isEmpty {
                isShowingFirstRunSheet = true
            }
        }
    }

    func refresh() {
        rows = integration.relevantBrowsers().map { browser in
            Row(browser: browser,
                status: integration.status(of: browser),
                icon: integration.applicationURL(for: browser).map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
    }

    /// Called when the sheet closes. From an unstable location the offer is
    /// kept, so it comes back once the app has been moved.
    func finishFirstRun() {
        if isLocationStable { UserDefaults.standard.set(true, forKey: Self.offeredKey) }
        isShowingFirstRunSheet = false
    }

    @discardableResult
    func setUp(_ browsers: [BrowserIntegration.Browser]) -> Bool {
        perform { for browser in browsers { try integration.setUp(browser) } }
    }

    func remove(_ browser: BrowserIntegration.Browser) {
        perform { try integration.remove(browser) }
    }

    func removeAll() {
        perform { for browser in BrowserIntegration.browsers { try integration.remove(browser) } }
    }

    func revealExtensionFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }

    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        defer { refresh() }
        do {
            try action()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
