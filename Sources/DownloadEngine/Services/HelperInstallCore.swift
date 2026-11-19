import Foundation

/// The install steps every helper shares, lifted out of `YouTubeHelperInstaller`
/// so the next helper (the BitTorrent engine) does not need a copy of them.
///
/// Stateless on purpose: each step takes the manifest and a destination, so a
/// client decides what to install and where, and nothing here knows about
/// yt-dlp. What is *not* here is the per-helper unpacking (a zip, an
/// `_internal/` tree, an APFS-clone pass), which stays with the one helper that
/// needs it until a second one does.
enum HelperInstallCore {

    /// Downloads one artifact named by the signed manifest and hands back a
    /// temporary file, having confirmed its SHA-256 first.
    ///
    /// Everything that installs a helper goes through here. Keeping it a
    /// single choke point is deliberate: the previous shape had four separate
    /// download paths, and the one that pre-dated the others quietly lacked
    /// the quarantine handling the rest had. A check that has to be remembered
    /// in four places is a check that will eventually be missing from one.
    ///
    /// The caller gets a temp file rather than an installed one, so an
    /// artifact that fails verification is never written to the install
    /// directory and never handed to `unzip`.
    ///
    /// `configuration` exists so tests can put a stub host in front of the
    /// session; nothing else passes it.
    static func downloadVerified(
        helper: String,
        manifest: HelperManifest,
        configuration: URLSessionConfiguration = .cookieless,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (url: URL, artifact: HelperManifest.Artifact) {
        let artifact = try manifest.artifact(for: helper)
        guard let url = URL(string: artifact.url) else { throw URLError(.badURL) }

        let (tempURL, response) = try await ProgressDownload.run(url, configuration: configuration, onBytes: onBytes)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.badServerResponse)
        }

        do {
            try HelperManifestStore.shared.check(fileAt: tempURL, against: artifact, helper: helper)
        } catch {
            // Remove it immediately. Leaving a rejected artifact in the temp
            // directory invites some later code path from picking it up.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return (tempURL, artifact)
    }

    /// Moves a verified single-file helper into place, executable and cleared
    /// of the quarantine mark.
    static func installVerifiedBinary(from tempURL: URL, to destinationPath: String) throws {
        try? FileManager.default.removeItem(atPath: destinationPath)
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destinationPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationPath)

        // GitHub-downloaded
        // binaries can carry a com.apple.quarantine xattr that trips
        // Gatekeeper's "cannot be opened because the developer cannot be
        // verified" refusal the first time we try to exec it — confirmed as
        // a real, reported problem for this exact yt-dlp_macos binary
        // (yt-dlp/yt-dlp#2374), not a hypothetical. A dev machine that's
        // already run these binaries before won't show this; a fresh
        // install hitting it on someone's first-ever YouTube click would.
        stripQuarantine(atPath: destinationPath, recursive: false)
    }

    /// Removes `com.apple.quarantine` from a file, or from a whole tree.
    ///
    /// Best-effort: if this macOS configuration never set the xattr in the
    /// first place, `xattr -d` exits non-zero for "no such xattr", which is
    /// fine to ignore. `recursive` is for an unpacked tree, where the mark
    /// lands on every extracted file and a launcher loading a quarantined
    /// dylib fails just as hard as a quarantined launcher would.
    static func stripQuarantine(atPath path: String, recursive: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = [recursive ? "-dr" : "-d", "com.apple.quarantine", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Single-file helpers are installed byte for byte as downloaded, so the
    /// listed SHA-256 identifies the installed copy too.
    static func isInstalledFileCurrent(_ path: String, helper: String, manifest: HelperManifest) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let artifact = try? manifest.artifact(for: helper) else { return false }
        return (try? HelperManifestStore.shared.check(
            fileAt: URL(fileURLWithPath: path), against: artifact, helper: helper
        )) != nil
    }
}
