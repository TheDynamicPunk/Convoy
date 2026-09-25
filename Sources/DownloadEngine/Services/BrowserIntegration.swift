import AppKit
import Foundation
import OSLog

/// Registers the native messaging host with Chromium browsers, and keeps a
/// copy of the unpacked extension in a fixed folder for the user to load.
///
/// A browser finds the host through a small JSON file in its own
/// `NativeMessagingHosts` folder, naming the host binary's absolute path and
/// the extension IDs allowed to launch it. The user picks which browsers get
/// one (the first-launch sheet, Settings → Browser). After that, a launch only
/// repoints files that already exist: a moved app keeps working, and a browser
/// the user didn't pick is never written to.
public struct BrowserIntegration: Sendable {
    /// Must match `NATIVE_HOST` in the extension's background.js and popup.js.
    public static let hostName = "io.github.thedynamicpunk.convoy.native"
    /// Fixed by the public `key` in the extension's manifest.json.
    public static let extensionID = "jfnchkplpoknchbbbnpgobnoolhdahmj"

    public struct Browser: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let bundleIdentifier: String
        /// The browser's user-data folder, relative to Application Support.
        /// Chromium reads `NativeMessagingHosts/` inside it.
        let dataFolder: String
    }

    public static let browsers: [Browser] = [
        Browser(id: "chrome", name: "Google Chrome", bundleIdentifier: "com.google.Chrome",
                dataFolder: "Google/Chrome"),
        Browser(id: "chrome-beta", name: "Google Chrome Beta", bundleIdentifier: "com.google.Chrome.beta",
                dataFolder: "Google/Chrome Beta"),
        Browser(id: "chromium", name: "Chromium", bundleIdentifier: "org.chromium.Chromium",
                dataFolder: "Chromium"),
        Browser(id: "brave", name: "Brave", bundleIdentifier: "com.brave.Browser",
                dataFolder: "BraveSoftware/Brave-Browser"),
        Browser(id: "edge", name: "Microsoft Edge", bundleIdentifier: "com.microsoft.edgemac",
                dataFolder: "Microsoft Edge"),
        Browser(id: "vivaldi", name: "Vivaldi", bundleIdentifier: "com.vivaldi.Vivaldi",
                dataFolder: "Vivaldi"),
        Browser(id: "opera", name: "Opera", bundleIdentifier: "com.operasoftware.Opera",
                dataFolder: "com.operasoftware.Opera"),
        Browser(id: "arc", name: "Arc", bundleIdentifier: "company.thebrowser.Browser",
                dataFolder: "Arc/User Data"),
    ]

    public enum Status: Equatable, Sendable {
        case notSetUp
        case setUp
        /// Our file exists but points somewhere else, or allows other IDs.
        case needsRepair
    }

    public enum SetupError: LocalizedError {
        case noHostExecutable
        case unstableLocation

        public var errorDescription: String? {
            switch self {
            case .noHostExecutable: return "NativeMessagingHost is missing from the app."
            case .unstableLocation: return "Convoy is running from a temporary location."
            }
        }
    }

    private let applicationSupport: URL
    private let hostExecutable: URL?
    private let bundledExtension: URL?
    private let applicationURL: @Sendable (String) -> URL?
    /// False when the app runs from a read-only volume: a mounted disk image,
    /// or the randomized copy macOS makes of a quarantined app (App
    /// Translocation). A file pointing there breaks when it goes away.
    public let isLocationStable: Bool

    private static let logger = Logger(subsystem: "Convoy", category: "BrowserIntegration")

    public init(
        applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        hostExecutable: URL? = Bundle.main.url(forAuxiliaryExecutable: "NativeMessagingHost"),
        bundledExtension: URL? = Bundle.main.resourceURL?.appendingPathComponent("Extension", isDirectory: true),
        isLocationStable: Bool = BrowserIntegration.isWritableLocation(Bundle.main.bundleURL),
        applicationURL: @escaping @Sendable (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.applicationSupport = applicationSupport
        self.hostExecutable = hostExecutable
        self.bundledExtension = bundledExtension
        self.isLocationStable = isLocationStable
        self.applicationURL = applicationURL
    }

    public static func isWritableLocation(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly != true
    }

    // MARK: - Browsers

    public func manifestURL(for browser: Browser) -> URL {
        applicationSupport
            .appendingPathComponent(browser.dataFolder, isDirectory: true)
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(Self.hostName).json")
    }

    public func applicationURL(for browser: Browser) -> URL? {
        applicationURL(browser.bundleIdentifier)
    }

    /// Installed browsers, plus any that still hold our file.
    public func relevantBrowsers() -> [Browser] {
        Self.browsers.filter { browser in
            applicationURL(browser.bundleIdentifier) != nil
                || FileManager.default.fileExists(atPath: manifestURL(for: browser).path)
        }
    }

    public func status(of browser: Browser) -> Status {
        guard let data = try? Data(contentsOf: manifestURL(for: browser)) else { return .notSetUp }
        guard let desired = desiredManifest(),
              let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              NSDictionary(dictionary: existing).isEqual(to: desired),
              let hostExecutable,
              FileManager.default.isExecutableFile(atPath: hostExecutable.path) else { return .needsRepair }
        return .setUp
    }

    public func setUp(_ browser: Browser) throws {
        guard isLocationStable else { throw SetupError.unstableLocation }
        guard let desired = desiredManifest() else { throw SetupError.noHostExecutable }
        let url = manifestURL(for: browser)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: desired, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
        Self.logger.notice("Registered host for \(browser.name, privacy: .public)")
    }

    public func remove(_ browser: Browser) throws {
        do {
            try FileManager.default.removeItem(at: manifestURL(for: browser))
        } catch CocoaError.fileNoSuchFile {
            return
        }
        Self.logger.notice("Unregistered host for \(browser.name, privacy: .public)")
    }

    /// Launch step: rewrites our files that exist but are out of date. Never
    /// creates one. Skipped from an unstable location, which would repoint a
    /// working setup at a path about to disappear.
    @discardableResult
    public func repairExisting() -> [Browser] {
        guard isLocationStable else { return [] }
        return Self.browsers.filter { browser in
            guard status(of: browser) == .needsRepair else { return false }
            do {
                try setUp(browser)
                return true
            } catch {
                Self.logger.error("Repair failed for \(browser.name, privacy: .public): \(error.localizedDescription)")
                return false
            }
        }
    }

    private func desiredManifest() -> [String: Any]? {
        guard let hostExecutable else { return nil }
        return [
            "name": Self.hostName,
            "description": "Convoy Native Messaging Host",
            "path": hostExecutable.resolvingSymlinksInPath().path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(Self.extensionID)/"],
        ]
    }

    // MARK: - Extension folder

    /// Where the user loads the unpacked extension from. Outside the app
    /// bundle, so moving or updating the app doesn't pull it away from under
    /// the browser.
    public var extensionFolder: URL {
        applicationSupport.appendingPathComponent("Convoy/Extension", isDirectory: true)
    }

    /// Copies the bundled extension to `extensionFolder` when they differ.
    /// Browsers pick up the new files the next time they start.
    @discardableResult
    public func syncExtension() throws -> Bool {
        guard let bundledExtension,
              FileManager.default.fileExists(atPath: bundledExtension.path) else { return false }
        if Self.contents(of: bundledExtension) == Self.contents(of: extensionFolder) { return false }

        let parent = extensionFolder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent("Extension.incoming", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.copyItem(at: bundledExtension, to: staging)
        if FileManager.default.fileExists(atPath: extensionFolder.path) {
            _ = try FileManager.default.replaceItemAt(extensionFolder, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: extensionFolder)
        }
        Self.logger.notice("Updated the extension folder")
        return true
    }

    /// Relative path → bytes for every visible file under `folder`.
    private static func contents(of folder: URL) -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        let base = folder.resolvingSymlinksInPath().path
        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: file) else { continue }
            let path = file.resolvingSymlinksInPath().path
            result[String(path.dropFirst(base.count))] = data
        }
        return result
    }
}
