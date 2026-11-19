import XCTest
import CryptoKit
@testable import DownloadEngine

/// Tests for the install steps every helper shares: a verified download, a
/// verified single-file install, and the "is what's on disk what the list
/// says" check. Nothing here touches the network or the real helper folder.
final class HelperInstallCoreTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubHelperProtocol.reset()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubHelperProtocol.reset()
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func manifest(listing payload: Data, helper: String = "fake-helper") -> HelperManifest {
        HelperManifest(
            formatVersion: HelperManifest.supportedFormatVersion,
            sequence: 1,
            generated: Date(timeIntervalSince1970: 1_700_000_000),
            helpers: [
                helper: .init(version: "v1", artifacts: [
                    "universal": .init(url: "https://example.test/\(helper)", sha256: SHA256.hash(data: payload).hexString),
                ]),
            ]
        )
    }

    private var stubbedConfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubHelperProtocol.self]
        return config
    }

    /// ProgressDownload names its temporary files `convoy-helper-<uuid>`.
    private func leftoverDownloads() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("convoy-helper-") })
    }

    private func quarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    private func setQuarantine(_ path: String) {
        let value = Array("0081;00000000;Safari;".utf8)
        XCTAssertEqual(setxattr(path, "com.apple.quarantine", value, value.count, 0, 0), 0)
    }

    private func write(_ name: String, _ bytes: Data, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? scratch).appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: - downloadVerified

    func testDownloadVerifiedReturnsTheFileWhenTheHashMatches() async throws {
        let payload = Data((0..<(256 << 10)).map { UInt8($0 % 241) })
        StubHelperProtocol.body = payload

        let (file, artifact) = try await HelperInstallCore.downloadVerified(
            helper: "fake-helper", manifest: manifest(listing: payload),
            configuration: stubbedConfiguration, onBytes: { _, _ in }
        )
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(artifact.url, "https://example.test/fake-helper")
    }

    /// The point of the choke point: bytes that are not the listed bytes are
    /// deleted on the spot and never handed to anything.
    func testDownloadVerifiedRefusesWrongBytesAndLeavesNothingBehind() async {
        StubHelperProtocol.body = Data("substituted".utf8)
        let before = leftoverDownloads()

        do {
            _ = try await HelperInstallCore.downloadVerified(
                helper: "fake-helper", manifest: manifest(listing: Data("the real helper".utf8)),
                configuration: stubbedConfiguration, onBytes: { _, _ in }
            )
            XCTFail("a mismatched download must not be returned")
        } catch {
            guard case .hashMismatch(let helper, _, _) = error as? HelperManifestError else {
                return XCTFail("expected .hashMismatch, got \(error)")
            }
            XCTAssertEqual(helper, "fake-helper")
        }
        XCTAssertEqual(leftoverDownloads(), before, "the rejected download must be deleted")
    }

    func testDownloadVerifiedTreatsARefusalAsAFailureAndLeavesNothingBehind() async {
        let payload = Data("an error page".utf8)
        StubHelperProtocol.body = payload
        StubHelperProtocol.statusCode = 404
        let before = leftoverDownloads()

        do {
            // The error page even hashes to the listed value, so only the
            // status check can reject it.
            _ = try await HelperInstallCore.downloadVerified(
                helper: "fake-helper", manifest: manifest(listing: payload),
                configuration: stubbedConfiguration, onBytes: { _, _ in }
            )
            XCTFail("a 404 must not be returned as a download")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
        XCTAssertEqual(leftoverDownloads(), before)
    }

    func testDownloadVerifiedFailsForAHelperTheListDoesNotName() async {
        StubHelperProtocol.body = Data("x".utf8)
        do {
            _ = try await HelperInstallCore.downloadVerified(
                helper: "not-listed", manifest: manifest(listing: Data("x".utf8)),
                configuration: stubbedConfiguration, onBytes: { _, _ in }
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? HelperManifestError, .unknownHelper("not-listed"))
        }
    }

    // MARK: - installVerifiedBinary

    func testInstallMovesTheFileMakesItExecutableAndClearsQuarantine() throws {
        let source = try write("download.tmp", Data("new build".utf8))
        setQuarantine(source.path)
        let destination = scratch.appendingPathComponent("qjs").path
        XCTAssertTrue(quarantine(source.path), "test setup: the quarantine mark must be there to begin with")

        try HelperInstallCore.installVerifiedBinary(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), Data("new build".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied")
        let permissions = try FileManager.default.attributesOfItem(atPath: destination)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o755)
        XCTAssertFalse(quarantine(destination), "Gatekeeper would refuse to launch a quarantined helper")
    }

    func testInstallReplacesWhatWasThere() throws {
        let destination = try write("qjs", Data("old build".utf8))
        let source = try write("download.tmp", Data("new build".utf8))

        try HelperInstallCore.installVerifiedBinary(from: source, to: destination.path)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new build".utf8))
    }

    // MARK: - stripQuarantine

    func testStripQuarantineRecursiveReachesNestedFiles() throws {
        let tree = scratch.appendingPathComponent("tree", isDirectory: true)
        let nested = tree.appendingPathComponent("_internal/lib", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let launcher = try write("launcher", Data("a".utf8), in: tree)
        let dylib = try write("libpython.dylib", Data("b".utf8), in: nested)
        setQuarantine(launcher.path)
        setQuarantine(dylib.path)

        HelperInstallCore.stripQuarantine(atPath: tree.path, recursive: true)

        XCTAssertFalse(quarantine(launcher.path))
        XCTAssertFalse(quarantine(dylib.path), "a quarantined dylib fails to load just as hard as a launcher")
    }

    func testStripQuarantineOnAFileWithNoMarkIsHarmless() throws {
        let file = try write("clean", Data("c".utf8))
        HelperInstallCore.stripQuarantine(atPath: file.path, recursive: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - isInstalledFileCurrent

    func testAnInstalledFileMatchingTheListIsCurrent() throws {
        let payload = Data("pinned bytes".utf8)
        let installed = try write("qjs", payload)
        XCTAssertTrue(HelperInstallCore.isInstalledFileCurrent(
            installed.path, helper: "fake-helper", manifest: manifest(listing: payload)))
    }

    func testAnInstalledFileThatDiffersFromTheListIsNotCurrent() throws {
        let installed = try write("qjs", Data("older bytes".utf8))
        XCTAssertFalse(HelperInstallCore.isInstalledFileCurrent(
            installed.path, helper: "fake-helper", manifest: manifest(listing: Data("pinned bytes".utf8))))
    }

    func testAMissingFileIsNotCurrent() {
        XCTAssertFalse(HelperInstallCore.isInstalledFileCurrent(
            scratch.appendingPathComponent("absent").path, helper: "fake-helper",
            manifest: manifest(listing: Data("x".utf8))))
    }

    func testAHelperTheListDoesNotNameIsNotCurrent() throws {
        let payload = Data("x".utf8)
        let installed = try write("qjs", payload)
        XCTAssertFalse(HelperInstallCore.isInstalledFileCurrent(
            installed.path, helper: "not-listed", manifest: manifest(listing: payload)))
    }
}
