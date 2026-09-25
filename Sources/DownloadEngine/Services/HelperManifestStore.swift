import Foundation
import CryptoKit
import os

/// Reads the list of helper binaries this app installs, and checks downloads
/// against it.
///
/// One source: the copy inside the app bundle. There is no feed and no cache,
/// so there is nothing to choose between and nothing to verify a signature
/// over — macOS seals every file in the bundle, and editing this one
/// invalidates the app's own code signature.
///
/// What the list is *for* is unchanged and is the whole point. Every helper it
/// installs -- yt-dlp, qjs, bgutil-pot and its plugin -- is ad-hoc signed, with
/// no publisher identity to pin, so knowing the expected SHA-256 in advance is
/// the only thing that can tell the real binary from a substitute. Asking the
/// download host what the download should hash to would be circular: a
/// compromised host answers with the hash of whatever it is serving. The
/// hashes are decided instead on the maintainer's machine, where upstream's
/// own published checksums can be cross-checked (see HelperManifestTool), and
/// shipped inside the app.
///
/// Helper updates therefore arrive with app updates; `HelperAutoUpdate`
/// reconciles what is installed after one lands.
public actor HelperManifestStore {

    public static let shared = HelperManifestStore()

    private static let logger = Logger(subsystem: "Convoy", category: "HelperManifest")

    private var loaded: HelperManifest?

    private nonisolated var bundledManifestURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("helpers.json")
    }

    // MARK: - Reading

    /// The best verified list available without touching the network.
    public func manifest() throws -> HelperManifest {
        if let loaded { return loaded }
        guard let best = bundledManifest() else { throw HelperManifestError.unavailable }
        loaded = best
        return best
    }

    // MARK: - Download checking

    /// Confirms downloaded bytes are what the signed list says they should be.
    ///
    /// Takes the bytes rather than a path on purpose: it is meant to be called
    /// on what came off the network, before anything is written to the install
    /// location or handed to `unzip`. Verifying after unpacking would mean
    /// already having run an archive tool over untrusted input.
    public nonisolated func check(
        downloaded: Data,
        against artifact: HelperManifest.Artifact,
        helper: String
    ) throws {
        let actual = SHA256.hash(data: downloaded).map { String(format: "%02x", $0) }.joined()
        guard actual == artifact.sha256.lowercased() else {
            throw HelperManifestError.hashMismatch(
                helper: helper,
                expected: artifact.sha256.lowercased(),
                actual: actual
            )
        }
    }

    /// File-based form of `check(downloaded:against:helper:)`, hashing
    /// incrementally rather than reading the whole artifact into memory —
    /// these are 30-80MB downloads and there is no reason to hold one twice.
    public nonisolated func check(
        fileAt url: URL,
        against artifact: HelperManifest.Artifact,
        helper: String
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        guard actual == artifact.sha256.lowercased() else {
            throw HelperManifestError.hashMismatch(
                helper: helper,
                expected: artifact.sha256.lowercased(),
                actual: actual
            )
        }
    }

    // MARK: - Internals

    /// The list shipped inside the app bundle.
    ///
    /// Read without a signature check, deliberately: macOS seals every file in
    /// the bundle, so editing this one invalidates the app's own code
    /// signature (measured — `codesign --verify` then reports "a sealed
    /// resource is missing or invalid"). Signing it again with a project key
    /// would re-prove that at the cost of a private key to guard for the life
    /// of the product.
    ///
    /// If a network-delivered list is ever reintroduced, that one must be
    /// signature-checked: the per-artifact SHA-256s cannot stand in, because
    /// whoever served a forged list would have written those too.
    private func bundledManifest() -> HelperManifest? {
        guard let url = bundledManifestURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? HelperManifest.decoder().decode(HelperManifest.self, from: data)
    }
}
