import CryptoKit
import XCTest
@testable import DownloadEngine

final class BrowserIntegrationTests: XCTestCase {
    private var root: URL!
    private var appSupport: URL!
    private let chrome = BrowserIntegration.browsers.first { $0.id == "chrome" }!
    private let brave = BrowserIntegration.browsers.first { $0.id == "brave" }!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserIntegrationTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        appSupport = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHost(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).app/Contents/MacOS/NativeMessagingHost")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        return url
    }

    private func integration(host: URL?, stable: Bool = true, bundledExtension: URL? = nil,
                             installed: Set<String> = []) -> BrowserIntegration {
        BrowserIntegration(applicationSupport: appSupport, hostExecutable: host,
                           bundledExtension: bundledExtension, isLocationStable: stable,
                           applicationURL: { installed.contains($0) ? URL(fileURLWithPath: "/Applications/x.app") : nil })
    }

    private func manifest(_ integration: BrowserIntegration, _ browser: BrowserIntegration.Browser) throws -> [String: Any] {
        let data = try Data(contentsOf: integration.manifestURL(for: browser))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSetUpWritesTheBrowsersNativeMessagingFile() throws {
        let host = try makeHost("A")
        let subject = integration(host: host)
        XCTAssertEqual(subject.status(of: chrome), .notSetUp)

        try subject.setUp(chrome)

        XCTAssertEqual(subject.manifestURL(for: chrome).path,
                       appSupport.path + "/Google/Chrome/NativeMessagingHosts/io.github.thedynamicpunk.convoy.native.json")
        let written = try manifest(subject, chrome)
        XCTAssertEqual(written["name"] as? String, BrowserIntegration.hostName)
        XCTAssertEqual(written["path"] as? String, host.path)
        XCTAssertEqual(written["type"] as? String, "stdio")
        XCTAssertEqual(written["allowed_origins"] as? [String], ["chrome-extension://jfnchkplpoknchbbbnpgobnoolhdahmj/"])
        XCTAssertEqual(subject.status(of: chrome), .setUp)
    }

    func testLaunchRepairRepointsExistingFilesOnly() throws {
        try integration(host: try makeHost("Old")).setUp(chrome)
        let moved = integration(host: try makeHost("Moved"))
        XCTAssertEqual(moved.status(of: chrome), .needsRepair)

        XCTAssertEqual(moved.repairExisting().map(\.id), ["chrome"])

        XCTAssertEqual(moved.status(of: chrome), .setUp)
        XCTAssertEqual(try manifest(moved, chrome)["path"] as? String, root.path + "/Moved.app/Contents/MacOS/NativeMessagingHost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.manifestURL(for: brave).path))
    }

    func testAFileAllowingAnotherExtensionNeedsRepair() throws {
        let host = try makeHost("A")
        let subject = integration(host: host)
        try subject.setUp(chrome)
        var edited = try manifest(subject, chrome)
        edited["allowed_origins"] = ["chrome-extension://nkajnihamgfjemlndhbcifjmdnidohpj/"]
        try JSONSerialization.data(withJSONObject: edited).write(to: subject.manifestURL(for: chrome))

        XCTAssertEqual(subject.status(of: chrome), .needsRepair)
    }

    func testNothingIsWrittenFromAnUnstableLocation() throws {
        let host = try makeHost("A")
        try integration(host: host).setUp(chrome)
        let translocated = integration(host: try makeHost("Translocated"), stable: false)

        XCTAssertEqual(translocated.repairExisting().map(\.id), [])
        XCTAssertEqual(try manifest(translocated, chrome)["path"] as? String, host.path)
        XCTAssertThrowsError(try translocated.setUp(brave))
    }

    func testRemoveDeletesTheFileAndToleratesAMissingOne() throws {
        let subject = integration(host: try makeHost("A"))
        try subject.setUp(chrome)

        try subject.remove(chrome)
        try subject.remove(brave)

        XCTAssertEqual(subject.status(of: chrome), .notSetUp)
    }

    func testRelevantBrowsersAreInstalledOnesPlusAnyHoldingOurFile() throws {
        let host = try makeHost("A")
        try integration(host: host).setUp(brave)
        let subject = integration(host: host, installed: ["com.google.Chrome"])

        XCTAssertEqual(subject.relevantBrowsers().map(\.id), ["chrome", "brave"])
    }

    func testExtensionFolderIsCopiedOnlyWhenItChanges() throws {
        let bundled = root.appendingPathComponent("Bundle/Extension")
        try FileManager.default.createDirectory(at: bundled.appendingPathComponent("Popup"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        try Data("a".utf8).write(to: bundled.appendingPathComponent("Popup/popup.js"))
        let subject = integration(host: nil, bundledExtension: bundled)

        XCTAssertTrue(try subject.syncExtension())
        XCTAssertFalse(try subject.syncExtension())

        try Data("b".utf8).write(to: bundled.appendingPathComponent("Popup/popup.js"))
        try FileManager.default.removeItem(at: bundled.appendingPathComponent("manifest.json"))
        XCTAssertTrue(try subject.syncExtension())

        let installed = subject.extensionFolder
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Popup/popup.js"), encoding: .utf8), "b")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("manifest.json").path))
    }

    // MARK: - Constants shared with the extension

    private var extensionDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/Chromium")
    }

    func testExtensionIDMatchesTheKeyInManifestJSON() throws {
        let data = try Data(contentsOf: extensionDirectory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let key = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(manifest["key"] as? String)))
        let id = SHA256.hash(data: key).prefix(16)
            .flatMap { [$0 >> 4, $0 & 0xF] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }
            .joined()

        XCTAssertEqual(id, BrowserIntegration.extensionID)
    }

    func testHostNameMatchesTheExtension() throws {
        for file in ["Background/background.js", "Popup/popup.js"] {
            let source = try String(contentsOf: extensionDirectory.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("const NATIVE_HOST = '\(BrowserIntegration.hostName)';"), file)
        }
    }

    func testFirefoxExtensionIDMatchesTheFirefoxManifest() throws {
        let url = extensionDirectory.deletingLastPathComponent().appendingPathComponent("Firefox/manifest.json")
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let gecko = try XCTUnwrap((manifest["browser_specific_settings"] as? [String: Any])?["gecko"] as? [String: Any])

        XCTAssertEqual(gecko["id"] as? String, BrowserIntegration.firefoxExtensionID)
    }

    // MARK: - Firefox family

    private let firefox = BrowserIntegration.browsers.first { $0.id == "firefox" }!
    private let zen = BrowserIntegration.browsers.first { $0.id == "zen" }!
    private let floorp = BrowserIntegration.browsers.first { $0.id == "floorp" }!
    private let librewolf = BrowserIntegration.browsers.first { $0.id == "librewolf" }!
    private let waterfox = BrowserIntegration.browsers.first { $0.id == "waterfox" }!

    func testFirefoxFileAllowsTheExtensionByIDNotByOrigin() throws {
        let subject = integration(host: try makeHost("A"))

        try subject.setUp(firefox)

        XCTAssertEqual(subject.manifestURL(for: firefox).path,
                       appSupport.path + "/Mozilla/NativeMessagingHosts/io.github.thedynamicpunk.convoy.native.json")
        let written = try manifest(subject, firefox)
        XCTAssertEqual(written["allowed_extensions"] as? [String], [BrowserIntegration.firefoxExtensionID])
        XCTAssertNil(written["allowed_origins"])
        XCTAssertEqual(subject.status(of: firefox), .setUp)
    }

    func testZenFloorpLibreWolfAndWaterfoxShareFirefoxsFile() throws {
        let subject = integration(host: try makeHost("A"))

        try subject.setUp(firefox)

        for browser in [zen, floorp, librewolf, waterfox] {
            XCTAssertEqual(subject.manifestURL(for: browser), subject.manifestURL(for: firefox), browser.id)
            XCTAssertEqual(subject.status(of: browser), .setUp, browser.id)
        }
    }

    /// Identifiers read from real installs with mdls (kMDItemCFBundleIdentifier).
    /// LibreWolf and Floorp were wrong for a long time: a browser whose identifier
    /// doesn't match is invisible to Settings and gets no Add to button. Only
    /// browsers someone has actually checked belong in this list.
    func testVerifiedBundleIdentifiersMatchRealInstalls() {
        let verified = [
            "arc": "company.thebrowser.Browser",
            "brave": "com.brave.Browser",
            "chrome": "com.google.Chrome",
            "firefox": "org.mozilla.firefox",
            "floorp": "app.floorp.Floorp",
            "helium": "net.imput.helium",
            "librewolf": "net.librewolf.librewolf",
            "waterfox": "net.waterfox.waterfox",
        ]

        for (id, bundleIdentifier) in verified {
            XCTAssertEqual(BrowserIntegration.browsers.first { $0.id == id }?.bundleIdentifier, bundleIdentifier, id)
        }
    }

    func testFirefoxExtensionFolderIsSyncedBesideChromes() throws {
        let bundled = root.appendingPathComponent("Bundle/FirefoxExtension")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        let subject = BrowserIntegration(applicationSupport: appSupport, hostExecutable: nil, bundledExtension: nil,
                                         bundledFirefoxExtension: bundled, bundledFirefoxPackage: nil,
                                         isLocationStable: true, applicationURL: { _ in nil })

        XCTAssertTrue(try subject.syncExtension())
        XCTAssertFalse(try subject.syncExtension())

        XCTAssertTrue(FileManager.default.fileExists(atPath: subject.firefoxExtensionFolder.appendingPathComponent("manifest.json").path))
        XCTAssertNotEqual(subject.firefoxExtensionFolder, subject.extensionFolder)
        XCTAssertNil(subject.firefoxPackage)
    }

    // MARK: - Arc and Helium

    private let arc = BrowserIntegration.browsers.first { $0.id == "arc" }!
    private let helium = BrowserIntegration.browsers.first { $0.id == "helium" }!

    func testArcSharesChromesFile() throws {
        let subject = integration(host: try makeHost("A"))

        try subject.setUp(arc)

        XCTAssertEqual(subject.manifestURL(for: arc), subject.manifestURL(for: chrome))
        XCTAssertEqual(subject.manifestURL(for: arc).path,
                       appSupport.path + "/Google/Chrome/NativeMessagingHosts/io.github.thedynamicpunk.convoy.native.json")
        XCTAssertEqual(subject.status(of: chrome), .setUp)
    }

    func testHeliumHasItsOwnFileAndIsFoundByBundleIdentifier() throws {
        let subject = integration(host: try makeHost("A"), installed: ["net.imput.helium"])

        try subject.setUp(helium)

        XCTAssertEqual(helium.bundleIdentifier, "net.imput.helium")
        XCTAssertEqual(subject.manifestURL(for: helium).path,
                       appSupport.path + "/net.imput.helium/NativeMessagingHosts/io.github.thedynamicpunk.convoy.native.json")
        XCTAssertEqual(try manifest(subject, helium)["allowed_origins"] as? [String],
                       ["chrome-extension://jfnchkplpoknchbbbnpgobnoolhdahmj/"])
        XCTAssertEqual(subject.status(of: helium), .setUp)
        XCTAssertEqual(subject.status(of: chrome), .notSetUp)
        XCTAssertEqual(subject.relevantBrowsers().map(\.id), ["helium"])
    }

    func testRemovingChromeLeavesHeliumRegistered() throws {
        let subject = integration(host: try makeHost("A"))
        try subject.setUp(chrome)
        try subject.setUp(helium)

        try subject.remove(chrome)

        XCTAssertEqual(subject.status(of: chrome), .notSetUp)
        XCTAssertEqual(subject.status(of: helium), .setUp)
    }

    /// Browsers on one file are one row in Settings, and removing that row
    /// removes the file for all of them. Sharing must be deliberate.
    func testOnlyIntendedBrowsersShareAFile() {
        let subject = integration(host: nil)
        var groups: [String: [String]] = [:]
        for browser in BrowserIntegration.browsers {
            groups[subject.manifestURL(for: browser).path, default: []].append(browser.id)
        }

        let shared = groups.values.filter { $0.count > 1 }.map { $0.sorted() }.sorted { $0.joined() < $1.joined() }

        XCTAssertEqual(shared, [["arc", "chrome"], ["firefox", "firefox-developer", "firefox-nightly", "floorp", "librewolf", "waterfox", "zen"]])
    }

    // MARK: - Files from earlier versions

    private func writeLegacyArcFile(_ contents: [String: Any]) throws -> URL {
        let url = appSupport.appendingPathComponent("Arc/User Data/NativeMessagingHosts/\(BrowserIntegration.hostName).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: contents).write(to: url)
        return url
    }

    func testAnArcFileFromAnEarlierVersionMovesToChromesFolder() throws {
        let legacy = try writeLegacyArcFile(["name": BrowserIntegration.hostName, "path": "/old/NativeMessagingHost"])
        let subject = integration(host: try makeHost("A"))

        XCTAssertEqual(subject.migrateLegacyFiles().map(\.id), ["arc"])

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(subject.status(of: arc), .setUp)
        XCTAssertEqual(subject.migrateLegacyFiles().map(\.id), [])
    }

    func testMigrationLeavesOtherFilesAndUnstableLocationsAlone() throws {
        let foreign = try writeLegacyArcFile(["name": "com.someone.else", "path": "/x"])
        let subject = integration(host: try makeHost("A"))

        XCTAssertEqual(subject.migrateLegacyFiles().map(\.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
        XCTAssertEqual(subject.status(of: arc), .notSetUp)

        let ours = try writeLegacyArcFile(["name": BrowserIntegration.hostName, "path": "/old"])
        let translocated = integration(host: try makeHost("T"), stable: false)

        XCTAssertEqual(translocated.migrateLegacyFiles().map(\.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: ours.path))
        XCTAssertEqual(translocated.status(of: arc), .notSetUp)
    }

    func testMigrationKeepsTheOldFileIfRegisteringFails() throws {
        let legacy = try writeLegacyArcFile(["name": BrowserIntegration.hostName, "path": "/old"])
        let subject = integration(host: nil)

        XCTAssertEqual(subject.migrateLegacyFiles().map(\.id), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
}
