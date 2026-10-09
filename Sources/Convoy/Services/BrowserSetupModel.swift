import AppKit
import DownloadEngine

/// State behind the first-launch browser sheet and Settings → Browser.
@MainActor
final class BrowserSetupModel: ObservableObject {
    static let shared = BrowserSetupModel()

    struct Row: Identifiable {
        let browser: BrowserIntegration.Browser
        /// Browsers sharing one registration file appear as one row.
        let displayName: String
        let status: BrowserIntegration.Status
        let icon: NSImage?
        var id: String { browser.id }
    }

    struct FirefoxTarget: Identifiable {
        let id: String
        let name: String
        let appURL: URL
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
    var firefoxExtensionFolder: URL { integration.firefoxExtensionFolder }
    var hasSignedFirefoxPackage: Bool { integration.firefoxPackage != nil }

    var showsFirefoxSteps: Bool { rows.contains { $0.browser.family == .gecko } }
    var showsChromiumSteps: Bool { rows.isEmpty || rows.contains { $0.browser.family == .chromium } }

    /// Installed Firefox-family browsers, for the Add to Firefox buttons.
    var firefoxTargets: [FirefoxTarget] {
        integration.relevantBrowsers().compactMap { browser in
            guard browser.family == .gecko, let url = integration.applicationURL(for: browser) else { return nil }
            return FirefoxTarget(id: browser.id, name: browser.name, appURL: url)
        }
    }

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
        var groups: [(path: String, browsers: [BrowserIntegration.Browser])] = []
        for browser in integration.relevantBrowsers() {
            let path = integration.manifestURL(for: browser).path
            if let index = groups.firstIndex(where: { $0.path == path }) {
                groups[index].browsers.append(browser)
            } else {
                groups.append((path, [browser]))
            }
        }
        rows = groups.map { group in
            let installed = group.browsers.filter { integration.applicationURL(for: $0) != nil }
            let representative = installed.first ?? group.browsers[0]
            let names = (installed.isEmpty ? [representative] : installed).map(\.name)
            return Row(browser: representative,
                       displayName: names.joined(separator: ", "),
                       status: integration.status(of: representative),
                       icon: integration.applicationURL(for: representative).map { NSWorkspace.shared.icon(forFile: $0.path) })
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

    func revealFirefoxExtensionFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([firefoxExtensionFolder])
    }

    /// Opens the signed package in the browser; Firefox shows its install prompt.
    func installFirefoxExtension(in target: FirefoxTarget) {
        guard let package = integration.firefoxPackage else { return }
        NSWorkspace.shared.open([package], withApplicationAt: target.appURL,
                                configuration: NSWorkspace.OpenConfiguration())
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
