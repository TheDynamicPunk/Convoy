import XCTest
import CryptoKit
@testable import DownloadEngine

/// Tests for the helper list: picking the right artifact for this machine, and
/// refusing a download whose bytes do not match the recorded hash.
///
/// The list itself carries no signature. It ships inside the app bundle, which
/// macOS seals, so the app's own code signature is what vouches for it --
/// see HelperManifestStore. Nothing here touches the network.
final class HelperManifestTests: XCTestCase {

    private func sampleManifest(sequence: Int = 1) -> HelperManifest {
        HelperManifest(
            formatVersion: HelperManifest.supportedFormatVersion,
            sequence: sequence,
            generated: Date(timeIntervalSince1970: 1_700_000_000),
            helpers: [
                "yt-dlp": .init(
                    version: "2026.08.19",
                    artifacts: ["universal": .init(url: "https://example.com/yt-dlp", sha256: String(repeating: "a", count: 64))]
                ),
                "quickjs": .init(
                    version: "v2.9.6",
                    artifacts: [
                        "arm64": .init(url: "https://example.com/qjs-arm64", sha256: String(repeating: "b", count: 64)),
                        "x86_64": .init(url: "https://example.com/qjs-x64", sha256: String(repeating: "c", count: 64)),
                    ]
                ),
            ]
        )
    }

    // MARK: - Artifact selection

    func testPrefersTheArchitectureSpecificArtifact() throws {
        let manifest = sampleManifest()
        XCTAssertEqual(try manifest.artifact(for: "quickjs", architecture: .arm64).url, "https://example.com/qjs-arm64")
        XCTAssertEqual(try manifest.artifact(for: "quickjs", architecture: .x86_64).url, "https://example.com/qjs-x64")
    }

    func testFallsBackToUniversalWhenThereIsNoArchitectureSpecificBuild() throws {
        let manifest = sampleManifest()
        for architecture in [HelperManifest.Architecture.arm64, .x86_64] {
            XCTAssertEqual(try manifest.artifact(for: "yt-dlp", architecture: architecture).url, "https://example.com/yt-dlp")
        }
    }

    /// Throwing rather than returning nil is deliberate — a nil would invite a
    /// caller to fall through to an unpinned download, which is the behaviour
    /// being removed.
    func testThrowsForAHelperTheManifestDoesNotList() {
        XCTAssertThrowsError(try sampleManifest().artifact(for: "definitely-not-a-helper")) { error in
            XCTAssertEqual(error as? HelperManifestError, .unknownHelper("definitely-not-a-helper"))
        }
    }

    // MARK: - Download checking

    func testAcceptsADownloadMatchingItsRecordedHash() throws {
        let payload = Data("pretend this is yt-dlp".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifact = HelperManifest.Artifact(url: "https://example.com/x", sha256: hash)

        XCTAssertNoThrow(
            try HelperManifestStore.shared.check(downloaded: payload, against: artifact, helper: "yt-dlp")
        )
    }

    func testRejectsADownloadThatDoesNotMatchItsRecordedHash() {
        let artifact = HelperManifest.Artifact(url: "https://example.com/x", sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(
            try HelperManifestStore.shared.check(
                downloaded: Data("substituted payload".utf8), against: artifact, helper: "yt-dlp"
            )
        ) { error in
            guard case .hashMismatch(let helper, _, _) = error as? HelperManifestError else {
                return XCTFail("expected .hashMismatch, got \(error)")
            }
            XCTAssertEqual(helper, "yt-dlp")
        }
    }

    /// Hashing a file must agree with hashing the same bytes in memory —
    /// otherwise the streaming path would reject perfectly good downloads, or
    /// worse, accept bad ones.
    func testTheFileAndInMemoryChecksAgree() throws {
        let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifact = HelperManifest.Artifact(url: "https://example.com/x", sha256: hash)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-check-\(UUID().uuidString)")
        try payload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertNoThrow(try HelperManifestStore.shared.check(fileAt: fileURL, against: artifact, helper: "quickjs"))
        XCTAssertNoThrow(try HelperManifestStore.shared.check(downloaded: payload, against: artifact, helper: "quickjs"))
    }

    // MARK: - The shipped manifest

    /// The committed manifest has to name every helper the installer asks for,
    /// and pin each one to fixed bytes.
    ///
    /// Unsigned on purpose: it ships inside the app bundle, which macOS seals.
    /// If a network-delivered list is ever reintroduced, that one has to be
    /// signature-checked, and these hashes cannot substitute — whoever served
    /// a forged list would have written them too.
    func testTheCommittedManifestNamesEveryHelperAndPinsExactBytes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DownloadEngineTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let directory = repoRoot.appendingPathComponent("Resources/HelperManifest")
        let manifestURL = directory.appendingPathComponent("helpers.json")

        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("no committed manifest at \(manifestURL.path)")
        }

        let manifest = try HelperManifest.decoder().decode(
            HelperManifest.self, from: Data(contentsOf: manifestURL)
        )

        // Every helper the installer asks for by name must actually be there,
        // or installation fails at run time on a user's machine instead of here.
        // Not ffmpeg or deno: both were dropped when muxing moved to
        // AVFoundation, and this list kept asking for ffmpeg long after.
        for helper in ["yt-dlp", "bgutil-pot", "bgutil-pot-plugin", "quickjs"] {
            XCTAssertNoThrow(try manifest.artifact(for: helper), "manifest is missing \(helper)")
        }

        // A "latest" URL cannot be pinned by a hash, since the bytes behind it
        // change without the URL changing.
        for (name, helper) in manifest.helpers {
            for (arch, artifact) in helper.artifacts {
                XCTAssertFalse(
                    artifact.url.contains("/latest/"),
                    "\(name) [\(arch)] is pinned to a moving 'latest' URL: \(artifact.url)"
                )
                XCTAssertEqual(artifact.sha256.count, 64, "\(name) [\(arch)] has a malformed SHA-256")
                // With no signature over the list, the hash and the transport
                // are the whole of the protection.
                XCTAssertTrue(
                    artifact.url.hasPrefix("https://"),
                    "\(name) [\(arch)] is not fetched over https: \(artifact.url)"
                )
            }
        }
    }
}
