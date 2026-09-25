import Foundation

/// Installs/updates the yt-dlp and bgutil-pot helper binaries that
/// YouTubeResolver shells out to — the in-app equivalent of running
/// download-helpers.sh by hand. Same binaries, same install location
/// (~/Library/Application Support/Convoy/bin), just triggered from a
/// Settings button instead of a terminal, so keeping them current when
/// YouTube breaks something doesn't mean leaving the app.
public actor YouTubeHelperInstaller {
    public static let shared = YouTubeHelperInstaller()

    public struct Status: Sendable {
        public let ytdlpInstalled: Bool
        public let ytdlpVersion: String?
        public let potInstalled: Bool
        /// Whether the JS runtime this app installs is present. Only ours
        /// counts — nothing else is used, deliberately; see
        /// `HelperLocations.jsRuntimeArguments()`.
        public let jsRuntimeInstalled: Bool
        public let potPluginInstalled: Bool
    }

    private var binDir: URL { HelperLocations.binDirectory }
    private var ytdlpDirectory: URL { HelperLocations.ytdlpDirectory }
    private var ytdlpPath: String { HelperLocations.ytdlp }
    private var legacyYtdlpPath: String { HelperLocations.legacyYtdlp }
    private var potPath: String { HelperLocations.potProvider }
    /// yt-dlp runs its EJS challenge-solver scripts in a JavaScript runtime
    /// (https://github.com/yt-dlp/yt-dlp/wiki/EJS). Bundled rather than left
    /// as a prerequisite, since almost nobody has one of the four runtimes
    /// yt-dlp accepts installed by default — but bundled as QuickJS (1.2 MB)
    /// rather than Deno (77 MB); see `HelperLocations.quickjs`.
    private var quickjsPath: String { HelperLocations.quickjs }

    /// `bgutil-pot` (above) is only the *server half* of the PO-Token system
    /// — yt-dlp itself has no idea it exists until a separate Python plugin
    /// is dropped into one of yt-dlp's plugin directories. Without this,
    /// `--extractor-args youtubepot-bgutilhttp:...` is silently ignored (yt-dlp
    /// logs "PO Token Providers: none" even with the server running), YouTube
    /// hides its real DASH formats from the unauthenticated client, and yt-dlp
    /// falls back to legacy progressive formats like `18` — which are
    /// separately, aggressively throttled regardless of the `n` challenge.
    /// Installed at binDir/yt-dlp-plugins/, which yt-dlp checks automatically
    /// next to a portable/PyInstaller binary like yt-dlp_macos.
    private var pluginsDir: URL { HelperLocations.pluginsDirectory }
    private var potPluginMarkerPath: String { pluginsDir.appendingPathComponent("bgutil-ytdlp-pot-provider/yt_dlp_plugins").path }

    public func currentStatus() async -> Status {
        let ytdlpInstalled = FileManager.default.fileExists(atPath: ytdlpPath)
        let potInstalled = FileManager.default.fileExists(atPath: potPath)
        let jsRuntimeInstalled = HelperLocations.isJSRuntimeInstalled
        let potPluginInstalled = FileManager.default.fileExists(atPath: potPluginMarkerPath)
        var version: String?
        if ytdlpInstalled {
            version = try? await runVersionCheck()
        }
        return Status(
            ytdlpInstalled: ytdlpInstalled,
            ytdlpVersion: version,
            potInstalled: potInstalled,
            jsRuntimeInstalled: jsRuntimeInstalled,
            potPluginInstalled: potPluginInstalled
        )
    }

    /// Installs the PO-Token provider and its yt-dlp plugin, on demand.
    ///
    /// Both halves or neither: the 41 MB server binary does nothing on its
    /// own, because yt-dlp does not know the provider exists until the
    /// (6 KB) plugin is installed too. Shipping one without the other is the
    /// state this code was in for months — server running, tokens never
    /// requested.
    ///
    /// Throws rather than downgrading failures to progress lines, unlike the
    /// steps in `installOrUpdate`: someone asked for this specifically, so
    /// "finished, but not really" is not a useful answer.
    /// Skips the download when the installed server already matches the list;
    /// the plugin ships in the same release, so it goes with the server.
    @discardableResult
    public func installPOTokenProvider(
        progress: @escaping @Sendable (HelperInstallEvent) -> Void
    ) async throws -> HelperUpdateResult {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let manifest = try await listedHelpers(progress: progress)

        let serverCurrent = isInstalledFileCurrent(potPath, helper: "bgutil-pot", manifest: manifest)
        let pluginPresent = FileManager.default.fileExists(atPath: potPluginMarkerPath)
        if serverCurrent && pluginPresent {
            return HelperUpdateResult(updated: [])
        }

        let stepCount = serverCurrent ? 1 : 2
        if !serverCurrent {
            let server = HelperInstallStep(name: "bot-check helper", step: 1, stepCount: stepCount, emit: progress)
            server.downloading(0, of: nil)
            let pot = try await downloadVerified(helper: "bgutil-pot", manifest: manifest, onBytes: server.onBytes)
            server.installing()
            try installVerifiedBinary(from: pot.url, to: potPath)
        }
        let plugin = HelperInstallStep(name: "its yt-dlp plugin", step: stepCount, stepCount: stepCount, emit: progress)
        try await downloadAndInstallPotPlugin(manifest: manifest, step: plugin)
        return HelperUpdateResult(updated: ["the bot-check helper"])
    }

    /// Refreshes the signed list, showing an indeterminate "Checking" step.
    /// The list of what should be installed. No network: it ships with the
    /// app (see HelperManifestStore.feedEnabled).
    private func listedHelpers(
        progress: @escaping @Sendable (HelperInstallEvent) -> Void
    ) async throws -> HelperManifest {
        progress(.progress(HelperInstallProgress(title: "Checking what's installed", step: 0, stepCount: 0,
                                                 receivedBytes: 0, expectedBytes: nil)))
        return try await currentManifest()
    }

    /// yt-dlp is current when it runs and reports the listed version. Running
    /// it also catches a broken install, which then gets replaced.
    private func isYtDlpCurrent(manifest: HelperManifest) async -> Bool {
        guard FileManager.default.fileExists(atPath: ytdlpPath),
              let listed = manifest.version(of: "yt-dlp"),
              let installed = try? await runVersionCheck() else { return false }
        return installed == listed
    }

    /// Single-file helpers are installed byte for byte as downloaded, so the
    /// listed SHA-256 identifies the installed copy too.
    private func isInstalledFileCurrent(_ path: String, helper: String, manifest: HelperManifest) -> Bool {
        guard FileManager.default.fileExists(atPath: path),
              let artifact = try? manifest.artifact(for: helper) else { return false }
        return (try? HelperManifestStore.shared.check(
            fileAt: URL(fileURLWithPath: path), against: artifact, helper: helper
        )) != nil
    }

    /// The list of what to install, from inside the app bundle.
    ///
    /// Throwing when there is no list is the point: the behaviour before any
    /// of this existed was to ask a download host for "latest" and run
    /// whatever came back, so "we could not confirm what to install" has to
    /// mean "install nothing" rather than "install anything".
    private func currentManifest() async throws -> HelperManifest {
        try await HelperManifestStore.shared.manifest()
    }

    /// Downloads (or re-downloads, to update) the helper binaries named by the
    /// signed manifest, verifying each against the SHA-256 it records before
    /// anything is installed.
    ///
    /// Pinned versions rather than "latest" -- which is a security property
    /// (bytes behind a moving URL cannot be pinned) and, just as usefully in
    /// practice, an operational one: when an upstream release breaks YouTube
    /// downloads, publishing a manifest that points back at the previous
    /// version rolls every user back. Under "latest" there was no way back.
    @discardableResult
    public func installOrUpdate(
        progress: @escaping @Sendable (HelperInstallEvent) -> Void
    ) async throws -> HelperUpdateResult {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let manifest = try await listedHelpers(progress: progress)

        // Only what differs from the list is downloaded.
        let needsYtDlp = !(await isYtDlpCurrent(manifest: manifest))
        let needsQuickJS = !isInstalledFileCurrent(quickjsPath, helper: "quickjs", manifest: manifest)
        let stepCount = (needsYtDlp ? 1 : 0) + (needsQuickJS ? 1 : 0)
        var updated: [String] = []

        if needsYtDlp {
            try await downloadAndInstallYtDlp(
                manifest: manifest, step: HelperInstallStep(name: "yt-dlp", step: 1, stepCount: stepCount, emit: progress)
            )
            updated.append("yt-dlp")
            // Still under "Installing yt-dlp". Its first launch is slow: macOS
            // scans the ~100 native libraries it just unpacked (measured 4 s
            // from a local copy, about 20 s after a real download; 0.16 s
            // afterwards). Paying that here keeps it off the status check once
            // the bar has gone, and off the first YouTube download.
            _ = try? await runVersionCheck()
        }

        // The PO-Token provider is deliberately NOT installed here.
        //
        // It is 41 MB — a third of everything this used to fetch — and as of
        // Sep 2026 it buys nothing on the path the app actually takes. Wired
        // up correctly it does mint a token, but only for the `web` client,
        // and that client currently returns storyboard images and nothing
        // else regardless of whether a token is supplied (SABR is fully
        // enforced there). The clients that do serve media don't ask for one.
        // Verified by downloading 2160p end to end with the provider absent.
        //
        // That is a statement about today, not a permanent one: PO Tokens are
        // what YouTube reaches for when it starts refusing anonymous
        // downloads, so this is insurance worth being able to install in one
        // click — see `installPOTokenProvider` — rather than insurance worth
        // charging every user 41 MB for up front.

        // yt-dlp runs its EJS challenge-solver scripts in a JavaScript
        // runtime. Bundled here rather than left as a manual prerequisite,
        // since almost nobody has one of the four runtimes yt-dlp accepts
        // (deno, node, bun, quickjs) installed by default.
        guard needsQuickJS else { return HelperUpdateResult(updated: updated) }
        do {
            try await downloadAndInstallQuickJS(
                manifest: manifest,
                step: HelperInstallStep(name: "JavaScript runtime", step: stepCount, stepCount: stepCount, emit: progress)
            )
            updated.append("the JavaScript runtime")
        } catch {
            // Not silently swallowed like the PO-Token skip above — without
            // any runtime yt-dlp warns that extraction is deprecated and may
            // hide formats, so the user should see why.
            progress(.warning("Couldn't install the JavaScript runtime, so yt-dlp may not find every format (\(error.localizedDescription))."))
        }
        return HelperUpdateResult(updated: updated)
    }

    /// Downloads the yt-dlp plugin zip (a *separate* release asset from the
    /// bgutil-pot server binary above) and installs it into
    /// binDir/yt-dlp-plugins/, which yt-dlp checks automatically next to a
    /// portable/PyInstaller executable like yt-dlp_macos — no PYTHONPATH or
    /// config file needed. Handles either the zip already containing its
    /// package folder at the root (the common release convention) or just
    /// the bare yt_dlp_plugins/ folder, by locating whichever directory
    /// actually contains yt_dlp_plugins and wrapping it in a package folder
    /// if needed — the exact wrapper folder name doesn't matter to yt-dlp,
    /// only that a yt_dlp_plugins/ folder exists somewhere under it.
    /// Unpacks the onedir yt-dlp build into `yt-dlp-dist/`.
    ///
    /// Unlike the other helpers this one is a directory, not a file: a
    /// launcher plus an `_internal/` tree of the Python runtime it would
    /// otherwise unpack into a temp directory on every single run.
    ///
    /// Moving the binary out of `binDir` is safe for plugins because
    /// YouTubeResolver passes `--plugin-dirs` explicitly rather than relying
    /// on yt-dlp finding `yt-dlp-plugins/` adjacent to the executable. If that
    /// ever changes back to adjacency, this move silently disables the
    /// PO-Token provider.
    private func downloadAndInstallYtDlp(manifest: HelperManifest, step: HelperInstallStep) async throws {
        step.downloading(0, of: nil)
        let (tempZipURL, _) = try await downloadVerified(helper: "yt-dlp", manifest: manifest, onBytes: step.onBytes)
        step.installing()

        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("convoy-ytdlp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let zipPath = scratchDir.appendingPathComponent("yt-dlp.zip")
        try FileManager.default.moveItem(at: tempZipURL, to: zipPath)

        let unpacked = scratchDir.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipPath.path, "-d", unpacked.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw YouTubeResolverError.processFailed("unzip exited \(unzip.terminationStatus)")
        }

        let launcher = unpacked.appendingPathComponent("yt-dlp_macos")
        guard FileManager.default.fileExists(atPath: launcher.path) else {
            throw YouTubeResolverError.malformedOutput
        }

        // Swap the whole tree at once. A partially replaced directory would
        // leave a launcher beside the wrong _internal/, which fails in ways
        // far more confusing than a missing install.
        //
        // Installed with ditto --hfsCompression rather than a plain move, so
        // the tree lands APFS-transparently-compressed. The kernel decompresses
        // on read, so nothing above this has to know, and measured cost is
        // ~10ms on a 0.19s run -- noise. Measured saving is 125MB -> 55MB,
        // because a Python distribution is mostly bytecode and text.
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: ytdlpDirectory)

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--hfsCompression", unpacked.path, ytdlpDirectory.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              FileManager.default.fileExists(atPath: ytdlpDirectory.appendingPathComponent("yt-dlp_macos").path) else {
            // Fall back to a plain move rather than failing the install: a
            // filesystem that cannot do this (a non-APFS volume, say) should
            // cost disk space, not a working yt-dlp.
            try? FileManager.default.removeItem(at: ytdlpDirectory)
            try FileManager.default.moveItem(at: unpacked, to: ytdlpDirectory)
            return try finishYtDlpInstall()
        }

        deduplicateIdenticalFiles(under: ytdlpDirectory.appendingPathComponent("_internal", isDirectory: true))
        return try finishYtDlpInstall()
    }

    /// Replaces byte-identical files with APFS clones, which share storage
    /// until one of them is written to -- and nothing here is ever written to.
    ///
    /// Worth doing because upstream's archive contains **four** real copies of
    /// the same 14MB Python binary: a macOS framework normally makes
    /// `Versions/Current` and the top-level entry symlinks, and PyInstaller's
    /// zip flattens them into duplicates. Checked: they are stored as four
    /// separate 14,771,520-byte members in the zip, so this is upstream's
    /// packaging rather than something our extraction introduced, and neither
    /// unzip nor ditto can avoid it at extraction time.
    ///
    /// Combined with the compression above: 125MB -> 40MB measured, against
    /// 35MB for the single-file build that took 7.4 seconds per run. Nearly
    /// the footprint of the slow one, at the speed of the fast one.
    ///
    /// Deliberately generic rather than hardcoding the framework paths, so it
    /// keeps working if upstream rearranges, and quietly does nothing if they
    /// fix it. Only files over 1MB are considered: the saving below that is
    /// not worth the hashing.
    private func deduplicateIdenticalFiles(under directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var bySize: [Int: [URL]] = [:]
        while let next = enumerator.nextObject() {
            guard let url = next as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize, size > 1_000_000 else { continue }
            bySize[size, default: []].append(url)
        }

        for (_, candidates) in bySize where candidates.count > 1 {
            guard let first = candidates.first,
                  let reference = try? Data(contentsOf: first, options: .mappedIfSafe) else { continue }

            for duplicate in candidates.dropFirst() {
                guard let other = try? Data(contentsOf: duplicate, options: .mappedIfSafe),
                      other == reference else { continue }

                // cp -c asks for a clone specifically, and fails rather than
                // silently falling back to a full copy -- so if this does not
                // work we simply keep the duplicate rather than pretending.
                let clone = Process()
                clone.executableURL = URL(fileURLWithPath: "/bin/cp")
                clone.arguments = ["-c", first.path, duplicate.path]
                clone.standardOutput = FileHandle.nullDevice
                clone.standardError = FileHandle.nullDevice
                let permissions = (try? fm.attributesOfItem(atPath: duplicate.path)[.posixPermissions]) ?? nil
                try? fm.removeItem(at: duplicate)
                try? clone.run()
                clone.waitUntilExit()
                if clone.terminationStatus != 0 {
                    try? fm.copyItem(at: first, to: duplicate)
                }
                if let permissions {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: duplicate.path)
                }
            }
        }
    }

    /// The parts of the yt-dlp install that are the same however the tree got
    /// into place.
    private func finishYtDlpInstall() throws {

        let installedLauncher = ytdlpDirectory.appendingPathComponent("yt-dlp_macos").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedLauncher)


        // Recursive: quarantine lands on every extracted file, and the
        // launcher loading a quarantined dylib out of _internal/ fails just as
        // hard as a quarantined launcher would.
        let stripQuarantine = Process()
        stripQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        stripQuarantine.arguments = ["-dr", "com.apple.quarantine", ytdlpDirectory.path]
        stripQuarantine.standardOutput = FileHandle.nullDevice
        stripQuarantine.standardError = FileHandle.nullDevice
        try? stripQuarantine.run()
        stripQuarantine.waitUntilExit()

        // Retire the old single-file install so two copies do not drift, and
        // so ytdlpPath's fallback cannot resurrect a stale one.
        try? FileManager.default.removeItem(atPath: legacyYtdlpPath)
    }

    private func downloadAndInstallPotPlugin(manifest: HelperManifest, step: HelperInstallStep) async throws {
        step.downloading(0, of: nil)
        let (tempZipURL, _) = try await downloadVerified(
            helper: "bgutil-pot-plugin", manifest: manifest, onBytes: step.onBytes
        )
        step.installing()

        let scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("convoy-potplugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let zipPath = scratchDir.appendingPathComponent("plugin.zip")
        try FileManager.default.moveItem(at: tempZipURL, to: zipPath)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipPath.path, "-d", scratchDir.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw YouTubeResolverError.processFailed("unzip exited \(unzip.terminationStatus)")
        }

        // Find the directory that directly contains "yt_dlp_plugins" —
        // either the scratch root itself, or one level down inside a
        // package folder the zip already wrapped it in.
        func containsYtDlpPlugins(_ dir: URL) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("yt_dlp_plugins").path)
        }

        var packageSourceDir: URL?
        if containsYtDlpPlugins(scratchDir) {
            packageSourceDir = scratchDir
        } else if let entries = try? FileManager.default.contentsOfDirectory(at: scratchDir, includingPropertiesForKeys: nil) {
            packageSourceDir = entries.first { containsYtDlpPlugins($0) }
        }
        guard let packageSourceDir else {
            throw YouTubeResolverError.malformedOutput
        }

        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let destination = pluginsDir.appendingPathComponent("bgutil-ytdlp-pot-provider", isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: packageSourceDir, to: destination)

        guard FileManager.default.fileExists(atPath: potPluginMarkerPath) else {
            throw YouTubeResolverError.malformedOutput
        }
    }

    /// Installs QuickJS, the JavaScript runtime yt-dlp runs its EJS
    /// challenge-solver scripts in.
    ///
    /// The quickjs-ng release assets are bare Mach-O executables rather than
    /// zips, so this is the same shape as the bgutil-pot install: download,
    /// hash-check against the signed manifest, move into place.
    ///
    /// The SHA-256 that `downloadVerified` has already checked is the
    /// integrity guarantee — these binaries are ad-hoc (linker-signed) and
    /// carry no publisher identity to pin, and a byte-exact hash is the
    /// stronger check regardless.
    private func downloadAndInstallQuickJS(manifest: HelperManifest, step: HelperInstallStep) async throws {
        step.downloading(0, of: nil)
        let (tempURL, _) = try await downloadVerified(helper: "quickjs", manifest: manifest, onBytes: step.onBytes)
        step.installing()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try installVerifiedBinary(from: tempURL, to: quickjsPath)
    }

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
    private func downloadVerified(
        helper: String,
        manifest: HelperManifest,
        onBytes: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> (url: URL, artifact: HelperManifest.Artifact) {
        let artifact = try manifest.artifact(for: helper)
        guard let url = URL(string: artifact.url) else { throw URLError(.badURL) }

        let (tempURL, response) = try await ProgressDownload.run(url, onBytes: onBytes)
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

    private func installVerifiedBinary(from tempURL: URL, to destinationPath: String) throws {
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
        // Best-effort — if this macOS configuration never set the xattr in
        // the first place, `xattr -d` exits non-zero for "no such xattr",
        // which is fine to ignore.
        let stripQuarantine = Process()
        stripQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        stripQuarantine.arguments = ["-d", "com.apple.quarantine", destinationPath]
        stripQuarantine.standardOutput = FileHandle.nullDevice
        stripQuarantine.standardError = FileHandle.nullDevice
        try? stripQuarantine.run()
        stripQuarantine.waitUntilExit()
    }

    private func runVersionCheck() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ytdlpPath)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: str ?? "unknown")
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
