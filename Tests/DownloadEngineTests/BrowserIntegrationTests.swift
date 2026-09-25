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
}
