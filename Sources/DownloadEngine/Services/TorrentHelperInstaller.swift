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
        let installed = FileManager.default.isExecutableFile(atPath: rqbitPath)
        var version: String?
        if installed {
            if let manifest = try? await HelperManifestStore.shared.manifest(),
               HelperInstallCore.isInstalledFileCurrent(rqbitPath, helper: "rqbit", manifest: manifest) {
                version = manifest.version(of: "rqbit")
            } else {
                version = try? await runVersionCheck()
            }
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

    private func runVersionCheck() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: rqbitPath)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let raw = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !raw.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                // `rqbit --version` prints e.g. "rqbit 9.1.0"; normalize to match
                // manifest format ("v9.1.0") and avoid "rqbit rqbit 9.1.0" in UI.
                let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
                let stripped = firstLine.lowercased().hasPrefix("rqbit ")
                    ? String(firstLine.dropFirst("rqbit ".count)).trimmingCharacters(in: .whitespaces)
                    : firstLine
                guard !stripped.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                let normalized = stripped.first?.isNumber == true ? "v\(stripped)" : stripped
                continuation.resume(returning: normalized)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
