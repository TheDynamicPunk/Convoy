import Foundation

/// Installs and updates the BitTorrent helper binary (`rqbit`) into
/// `~/Library/Application Support/Convoy/bin/rqbit`, verified against the
/// SHA-256 pinned in `helpers.json`.
public actor TorrentHelperInstaller {
    public static let shared = TorrentHelperInstaller()

    public struct Status: Sendable {
        public let installed: Bool
        public let version: String?
    }

    private var binDir: URL { HelperLocations.binDirectory }
    private var rqbitPath: String { HelperLocations.rqbit }

    public func currentStatus() async -> Status {
        let installed = FileManager.default.fileExists(atPath: rqbitPath)
        var version: String?
        if installed {
            version = (try? await HelperManifestStore.shared.manifest().version(of: "rqbit"))
        }
        return Status(installed: installed, version: version)
    }

    /// Downloads (or reinstalls/updates) the pinned `rqbit` binary, verifying
    /// its SHA-256 before moving it into place and clearing quarantine.
    @discardableResult
    public func installOrUpdate(
        progress: @escaping @Sendable (HelperInstallEvent) -> Void
    ) async throws -> HelperUpdateResult {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        progress(.progress(HelperInstallProgress(
            title: "Checking what's installed",
            step: 0,
            stepCount: 0,
            receivedBytes: 0,
            expectedBytes: nil
        )))

        let manifest = try await HelperManifestStore.shared.manifest()
        if HelperInstallCore.isInstalledFileCurrent(rqbitPath, helper: "rqbit", manifest: manifest) {
            return HelperUpdateResult(updated: [])
        }

        let step = HelperInstallStep(name: "BitTorrent helper", step: 1, stepCount: 1, emit: progress)
        step.downloading(0, of: nil)
        let downloaded = try await HelperInstallCore.downloadVerified(
            helper: "rqbit",
            manifest: manifest,
            onBytes: step.onBytes
        )
        step.installing()
        try HelperInstallCore.installVerifiedBinary(from: downloaded.url, to: rqbitPath)
        return HelperUpdateResult(updated: ["the BitTorrent helper"])
    }
}
