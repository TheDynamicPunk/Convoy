import Foundation

/// The one place that knows where the helper binaries live.
///
/// This exists because they were previously defined three times -- in
/// YouTubeHelperInstaller, YouTubeResolver and YouTubeDownloader -- and the
/// copies disagreed the moment one of them changed. Moving yt-dlp to its
/// onedir layout updated the installer's copy, the other two kept looking for
/// the old single-file path, the installer deleted that file, and the app
/// reported "yt-dlp isn't installed yet" immediately after installing it
/// successfully.
///
/// A fact duplicated in three places will eventually disagree in at least
/// one. Everything that needs to locate a helper reads it from here.
public enum HelperLocations {

    public static var binDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Convoy/bin", isDirectory: true)
    }

    /// yt-dlp's onedir tree: a launcher plus the `_internal/` runtime it would
    /// otherwise unpack to a temp directory on every single run.
    public static var ytdlpDirectory: URL {
        binDirectory.appendingPathComponent("yt-dlp-dist", isDirectory: true)
    }

    /// The yt-dlp to run.
    ///
    /// Prefers the onedir launcher and falls back to the single-file binary
    /// older versions installed, so an existing install keeps working until
    /// the user next updates their helpers rather than breaking the moment
    /// they take an app update.
    public static var ytdlp: String {
        let onedir = ytdlpDirectory.appendingPathComponent("yt-dlp_macos").path
        if FileManager.default.isExecutableFile(atPath: onedir) { return onedir }
        return legacyYtdlp
    }

    /// The pre-onedir location: a single PyInstaller onefile binary.
    public static var legacyYtdlp: String {
        binDirectory.appendingPathComponent("yt-dlp").path
    }

    public static var potProvider: String {
        binDirectory.appendingPathComponent("bgutil-pot").path
    }

    /// The bundled JavaScript interpreter yt-dlp runs its EJS
    /// challenge-solver scripts in.
    ///
    /// QuickJS rather than Deno, which this used to be. yt-dlp accepts
    /// `deno`, `node`, `bun` or `quickjs` and treats them as equivalent
    /// challenge providers; QuickJS is a 1.2 MB interpreter against Deno's
    /// 77 MB installed, which was a third of everything the app asked a user
    /// to download. Verified against live YouTube on a video that does
    /// exercise the solver: both runtimes solved it and both reached 2160p.
    ///
    /// The quickjs-ng release binaries are ad-hoc (linker-signed), so like
    /// every other helper here they are verified by the SHA-256 in the
    /// bundled manifest rather than by publisher — the stronger check of the
    /// two, since it pins the exact bytes. The manifest carries no signature
    /// of its own; it ships inside the app bundle, which macOS seals.
    public static var quickjs: String {
        binDirectory.appendingPathComponent("qjs").path
    }

    /// yt-dlp arguments pinning it to the runtime this app installed.
    ///
    /// `--no-js-runtimes` first, and that is the load-bearing half. yt-dlp
    /// enables `deno` by default and discovers it on PATH, and when several
    /// runtimes are available it picks deno over the one named here —
    /// verified: passing only `--js-runtimes quickjs:<path>` on a machine
    /// with Homebrew Deno installed logs
    /// `JS runtimes: deno-2.9.6, quickjs-ng-0.16.2` and then
    /// `Solving JS challenges using deno`. So without clearing the defaults
    /// first, "the runtime we ship" is whatever the user happens to have,
    /// and a bug report means asking them what is on their PATH.
    ///
    /// There is deliberately no fallback to a system Deno or Node. This
    /// used to search `~/.deno/bin`, Homebrew, `/usr/bin/node` and nvm, and
    /// the search was wrong in a way nobody would have noticed until it
    /// mattered: it sorted nvm's version directories by *string* descending,
    /// so `v9.0.0` beat `v24.18.0`, and it checked no version at all
    /// against yt-dlp's Node >= 22 requirement for EJS. A runtime we pin,
    /// hash-check and can name in a bug report is worth more than one that
    /// might be any build of anything.
    ///
    /// `--no-js-runtimes` is returned even when our runtime is missing, so
    /// yt-dlp runs with no runtime rather than quietly picking up whatever
    /// the machine has. That is the strict reading on purpose: a missing
    /// runtime is a broken install with a known repair — Settings reports it
    /// and the fix is a 1.2 MB download — whereas a download that silently
    /// succeeded through someone's Homebrew Deno is a machine-specific
    /// behaviour nobody can reproduce, and the report it eventually produces
    /// costs far more than the repair does.
    public static func jsRuntimeArguments() -> [String] {
        guard FileManager.default.isExecutableFile(atPath: quickjs) else {
            return ["--no-js-runtimes"]
        }
        return ["--no-js-runtimes", "--js-runtimes", "quickjs:\(quickjs)"]
    }

    /// Whether the JS runtime this app installs is present and runnable.
    public static var isJSRuntimeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: quickjs)
    }

    /// yt-dlp arguments enabling the PO-Token plugin, or empty when it is
    /// not installed.
    ///
    /// The path is the *package* directory — the one directly containing a
    /// `yt_dlp_plugins/` folder — not `binDir`, and not the `yt-dlp-plugins/`
    /// folder above it.
    ///
    /// This was wrong for the plugin's entire life here, and silently: the
    /// old code checked that `binDir/yt-dlp-plugins/` existed and then passed
    /// `binDir`. yt-dlp answered `Plugin directories: none` and
    /// `PO Token Providers: none`, so the provider server was launched, the
    /// `--extractor-args` were passed, and none of it did anything. The
    /// confusion is understandable — yt-dlp *does* scan for folders named
    /// `yt-dlp-plugins` inside its config locations, but `--plugin-dirs`
    /// takes the package directory directly. Verified: pointing it here
    /// yields `PO Token Providers: bgutil:cli-0.8.1 (external, unavailable),
    /// bgutil:http-0.8.1 (external)` and a token is minted.
    public static func pluginArguments() -> [String] {
        let package = pluginsDirectory.appendingPathComponent(
            "bgutil-ytdlp-pot-provider", isDirectory: true
        )
        guard FileManager.default.fileExists(
            atPath: package.appendingPathComponent("yt_dlp_plugins").path
        ) else { return [] }
        return ["--plugin-dirs", package.path]
    }

    /// Pins YouTube extraction to one player client.
    ///
    /// Unpinned, yt-dlp lands on `visionos` anyway, but on some videos first
    /// mints a PO-Token and solves a JS challenge for the `web` client:
    /// 4.1-4.7s against 2.1-2.3s, measured on dQw4w9WgXcQ. All that buys is
    /// itag 18 (360p combined), which this drops on purpose.
    ///
    /// One client, not a list: yt-dlp fetches every client named and merges
    /// the results, so a second name doubles the cost. The others are worse —
    /// web/android cap at 360p, web_safari at 1080p, tv/ios fail a bot check.
    ///
    /// `YouTubeResolver.resolve` omits this deliberately; see the note there.
    public static func youtubePlayerClientArguments() -> [String] {
        ["--extractor-args", "youtube:player_client=visionos"]
    }

    public static var pluginsDirectory: URL {
        binDirectory.appendingPathComponent("yt-dlp-plugins", isDirectory: true)
    }
}
