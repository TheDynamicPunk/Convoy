import Foundation
import CryptoKit
import DownloadEngine

// A maintainer-side tool. It never ships inside the app: build.sh copies only
// Convoy and NativeMessagingHost into the bundle.
//
// Its whole purpose is to move the expensive, fiddly verification off users'
// machines and onto the one machine where it can actually be done properly —
// the maintainer's, at release time, where gpg exists and a human is watching.
// Users' apps then do the one cheap thing that is left: compare a hash against
// the list bundled inside the app.
//
//   helper-manifest resolve
//   helper-manifest build --sources <file> --sequence N --out <dir>

// MARK: - Small utilities

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func note(_ message: String) { print(message) }
func warn(_ message: String) { print("WARNING: \(message)") }

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--\(name)"), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func flag(_ name: String) -> Bool { CommandLine.arguments.contains("--\(name)") }

func requiredArgument(_ name: String) -> String {
    guard let value = argument(name) else { fail("missing --\(name)") }
    return value
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fetch(_ urlString: String) throws -> Data {
    guard let url = URL(string: urlString) else { fail("not a URL: \(urlString)") }
    var result: Result<Data, Error>!
    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: url) { data, response, error in
        defer { semaphore.signal() }
        if let error { result = .failure(error); return }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            result = .failure(URLError(.badServerResponse)); return
        }
        result = .success(data ?? Data())
    }.resume()
    semaphore.wait()
    return try result.get()
}

/// Follows redirects without downloading the body, so a "latest" URL can be
/// turned into the immutable versioned URL it currently points at. Pinning
/// that, rather than "latest", is what makes a hash meaningful at all: a URL
/// whose bytes can change under you cannot be pinned by definition.
func resolveRedirect(_ urlString: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = ["-sSLI", "-o", "/dev/null", "-w", "%{url_effective}", urlString]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let resolved = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return resolved.isEmpty ? urlString : resolved
}

// MARK: - Sources file
//
// The maintainer-edited input: which exact version of each helper to pin, and
// the exact URL it lives at. Separate from the output manifest because this is
// the part a human decides (including "roll back to last week's yt-dlp") and
// the manifest is the part a machine derives from it.

struct Sources: Codable {
    struct Entry: Codable {
        let version: String
        /// Keyed the same way HelperManifest.Helper.artifacts is:
        /// "universal", "arm64", "x86_64".
        let urls: [String: String]
        /// Upstream's own published checksum list, when it has one. Used to
        /// cross-check what we downloaded before we vouch for it.
        let checksums: Checksums?
    }
    struct Checksums: Codable {
        /// URL of a `<hash>  <filename>` list, e.g. yt-dlp's SHA2-256SUMS.
        let listURL: String
        /// Detached GPG signature over that list, if upstream publishes one.
        let signatureURL: String?
        /// Filename to look for inside the list.
        let entryName: String
    }
    let helpers: [String: Entry]
}

// MARK: - Commands

struct Upstream {
    let name: String
    /// GitHub "owner/repo", or nil for a helper hosted elsewhere.
    let repo: String?
    /// arch key -> asset filename (GitHub), or full "latest" URL (otherwise).
    let assets: [String: String]
    /// Upstream's published checksum list, if it has one.
    let checksums: Sources.Checksums?
}

let upstreams: [Upstream] = [
    Upstream(
        name: "yt-dlp",
        repo: "yt-dlp/yt-dlp",
        // The .zip is PyInstaller's *onedir* build -- a small launcher plus a
        // pre-extracted _internal/ folder -- not merely a compressed copy of
        // the single-file binary.
        //
        // The single-file build unpacks 72MB of Python runtime into a temp
        // directory on EVERY invocation and deletes it on exit, which measured
        // at 7.4s per run. The onedir build costs that once (Gatekeeper's
        // first-exec scan) and then runs in 0.17s. Since this app shells out
        // to yt-dlp for every format listing and every download, that was a
        // 7.4-second tax on every YouTube operation in the app, not just on
        // the settings screen where it was first noticed.
        //
        // The cost is disk: ~124MB unpacked against ~35MB.
        assets: ["universal": "yt-dlp_macos.zip"],
        checksums: nil  // filled in per-release below, since the URL carries the tag
    ),
    Upstream(
        // The JS runtime yt-dlp runs its EJS challenge-solver scripts in.
        // yt-dlp accepts deno, node, bun or quickjs and treats them as
        // equivalent challenge providers, so this is the cheapest of the four
        // by a wide margin: 1.2 MB against Deno's 36 MB download / 77 MB
        // installed, which was the largest single item in the helper set.
        //
        // Bare Mach-O executables, not zips -- and thin per-architecture
        // ones, so both arches are pinned separately.
        name: "quickjs",
        repo: "quickjs-ng/quickjs",
        assets: [
            "arm64": "qjs-darwin-arm64",
            "x86_64": "qjs-darwin-x86_64",
        ],
        checksums: nil
    ),
    Upstream(
        name: "bgutil-pot",
        repo: "jim60105/bgutil-ytdlp-pot-provider-rs",
        assets: [
            "arm64": "bgutil-pot-macos-aarch64",
            "x86_64": "bgutil-pot-macos-x86_64",
        ],
        checksums: nil
    ),
    Upstream(
        name: "bgutil-pot-plugin",
        repo: "jim60105/bgutil-ytdlp-pot-provider-rs",
        assets: ["universal": "bgutil-ytdlp-pot-provider-rs.zip"],
        checksums: nil
    ),
]

/// Current release tag for a GitHub repo.
func latestTag(ofRepo repo: String) throws -> String {
    let data = try fetch("https://api.github.com/repos/\(repo)/releases/latest")
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tag = object["tag_name"] as? String else {
        fail("couldn't read a release tag for \(repo)")
    }
    return tag
}

/// Reads the `Location:` of a single redirect without following it. Used for
/// hosts that expose a "latest" pointer to an immutable versioned path --
/// deliberately not `-L`, because the final URL after following can be a
/// short-lived CDN address rather than the durable one.
func redirectTarget(_ urlString: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    // A ranged GET rather than HEAD: this host answers HEAD inconsistently
    // (404 for one architecture, 307 for another, varying by the hour), while
    // a GET reliably returns the redirect. The range keeps it to one byte, so
    // it stays as cheap as the HEAD was meant to be.
    process.arguments = ["-sS", "-r", "0-0", "-o", "/dev/null", "-D", "-", urlString]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()

    let lines = output.split(whereSeparator: { $0 == "\r\n" || $0 == "\n" || $0 == "\r" })
    for line in lines where line.lowercased().hasPrefix("location:") {
        let target = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
        if target.hasPrefix("http") { return target }
        if let base = URL(string: urlString), let absolute = URL(string: target, relativeTo: base) {
            return absolute.absoluteString
        }
    }
    return nil
}

func commandResolve() {
    let outPath = argument("out")
    var entries: [String: Sources.Entry] = [:]

    for upstream in upstreams {
        var urls: [String: String] = [:]
        var version = "unknown"
        var checksums: Sources.Checksums?

        if let repo = upstream.repo {
            guard let tag = try? latestTag(ofRepo: repo) else {
                fail("couldn't reach the GitHub API for \(repo)")
            }
            version = tag
            for (archKey, asset) in upstream.assets {
                urls[archKey] = "https://github.com/\(repo)/releases/download/\(tag)/\(asset)"
            }
            // yt-dlp publishes GPG-signed checksums with every release. Wiring
            // them in here is the point of doing this at release time: the
            // tool can authenticate what it is about to vouch for.
            if upstream.name == "yt-dlp" {
                checksums = Sources.Checksums(
                    listURL: "https://github.com/\(repo)/releases/download/\(tag)/SHA2-256SUMS",
                    signatureURL: "https://github.com/\(repo)/releases/download/\(tag)/SHA2-256SUMS.sig",
                    entryName: "yt-dlp_macos.zip"
                )
            }
        } else {
            for (archKey, latestURL) in upstream.assets {
                guard let pinned = redirectTarget(latestURL) else {
                    fail("""
                    \(upstream.name) [\(archKey)]: \(latestURL) did not redirect to a versioned URL, \
                    so there is nothing stable to pin. Check the host by hand.
                    """)
                }
                urls[archKey] = pinned
                // e.g. .../download/macos/arm64/1787073674_9.0.1/ffmpeg.zip
                let components = pinned.split(separator: "/")
                if components.count >= 2 { version = String(components[components.count - 2]) }
            }
        }

        entries[upstream.name] = Sources.Entry(version: version, urls: urls, checksums: checksums)
        note("\(upstream.name) \(version)")
        for (archKey, url) in urls.sorted(by: { $0.key < $1.key }) {
            note("  \(archKey): \(url)")
        }
    }

    let sources = Sources(helpers: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(sources) else { fail("couldn't encode sources") }

    if let outPath {
        do { try data.write(to: URL(fileURLWithPath: outPath)) }
        catch { fail("couldn't write \(outPath): \(error)") }
        note("\nWrote \(outPath). Review it, adjust any version you want to hold back, then run `build`.")
    } else {
        note("\n" + (String(data: data, encoding: .utf8) ?? ""))
        note("Pass --out <file> to write this to disk.")
    }
}

/// Cross-checks a download against whatever the upstream project publishes,
/// which is the entire point of doing this at release time rather than in the
/// app: here there is a human, a shell, and gpg.
func crossCheck(
    helper: String,
    actualHash: String,
    checksums: Sources.Checksums,
    allowUnverified: Bool
) {
    guard let listData = try? fetch(checksums.listURL) else {
        fail("\(helper): couldn't fetch \(checksums.listURL) to cross-check the download against.")
    }

    if let signatureURL = checksums.signatureURL {
        let gpgAvailable = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gpg")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gpg")
        if gpgAvailable {
            guard let signature = try? fetch(signatureURL) else {
                fail("\(helper): couldn't fetch the checksum signature at \(signatureURL).")
            }
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("hm-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let listPath = scratch.appendingPathComponent("SUMS")
            let sigPath = scratch.appendingPathComponent("SUMS.sig")
            try? listData.write(to: listPath)
            try? signature.write(to: sigPath)

            let gpg = Process()
            gpg.executableURL = URL(fileURLWithPath: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gpg") ? "/opt/homebrew/bin/gpg" : "/usr/local/bin/gpg")
            gpg.arguments = ["--verify", sigPath.path, listPath.path]
            let errPipe = Pipe()
            gpg.standardError = errPipe
            gpg.standardOutput = FileHandle.nullDevice
            try? gpg.run()
            gpg.waitUntilExit()
            let gpgOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if gpg.terminationStatus == 0 {
                note("    checksum list GPG signature: VERIFIED")
            } else if allowUnverified {
                warn("gpg could not verify \(helper)'s checksum list — continuing because --allow-unverified-checksums was passed.\n\(gpgOutput)")
            } else {
                fail("""
                gpg could not verify \(helper)'s checksum list, so the hash it \
                contains cannot be trusted and this manifest was not written.

                \(gpgOutput)
                If you have not imported the upstream key yet:
                  curl -L https://github.com/yt-dlp/yt-dlp/raw/master/public.key | gpg --import

                Pass --allow-unverified-checksums only if you have decided to \
                accept an unauthenticated list.
                """)
            }
        } else if allowUnverified {
            warn("gpg is not installed — \(helper)'s checksum list was fetched but not authenticated. Continuing because --allow-unverified-checksums was passed.")
        } else {
            fail("""
            gpg is not installed, so \(helper)'s published checksum list cannot be \
            authenticated, and signing a manifest on the strength of an \
            unauthenticated list would defeat the point of having one.

              brew install gnupg
              curl -L https://github.com/yt-dlp/yt-dlp/raw/master/public.key | gpg --import

            Or pass --allow-unverified-checksums to proceed anyway.
            """)
        }
    }

    // The list is `<hash>  <filename>` per line.
    let text = String(data: listData, encoding: .utf8) ?? ""
    var published: String?
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts.last.map(String.init) == checksums.entryName {
            published = String(parts[0]).lowercased()
            break
        }
    }
    guard let published else {
        fail("\(helper): no entry named '\(checksums.entryName)' in \(checksums.listURL)")
    }
    guard published == actualHash else {
        fail("""
        \(helper): what was downloaded does not match upstream's own published checksum.
          downloaded: \(actualHash)
          published:  \(published)
        Not writing a manifest. Investigate before continuing.
        """)
    }
    note("    matches upstream's published checksum")
}

func commandBuild() {
    let sourcesPath = requiredArgument("sources")
    let outDir = requiredArgument("out")
    guard let sequence = Int(requiredArgument("sequence")) else { fail("--sequence must be a whole number") }
    let allowUnverified = flag("allow-unverified-checksums")

    guard let sourcesData = FileManager.default.contents(atPath: sourcesPath) else {
        fail("couldn't read \(sourcesPath)")
    }
    let sources: Sources
    do { sources = try JSONDecoder().decode(Sources.self, from: sourcesData) }
    catch { fail("couldn't parse \(sourcesPath): \(error)") }

    var helpers: [String: HelperManifest.Helper] = [:]
    var crossChecked: Set<String> = []

    for (name, entry) in sources.helpers.sorted(by: { $0.key < $1.key }) {
        note("\(name) \(entry.version)")
        var artifacts: [String: HelperManifest.Artifact] = [:]

        for (archKey, urlString) in entry.urls.sorted(by: { $0.key < $1.key }) {
            if urlString.contains("/latest/") {
                fail("""
                \(name) [\(archKey)] is pinned to a 'latest' URL:
                  \(urlString)
                The bytes behind such a URL change without warning, so a hash of them \
                means nothing. Run `helper-manifest resolve` and pin the versioned URL \
                it prints.
                """)
            }
            note("  \(archKey): downloading…")
            let data: Data
            do { data = try fetch(urlString) } catch { fail("\(name) [\(archKey)]: \(error)") }
            let hash = sha256Hex(data)
            note("    \(data.count) bytes, sha256 \(hash)")

            if let checksums = entry.checksums, urlString.hasSuffix("/" + checksums.entryName) {
                crossCheck(
                    helper: name, actualHash: hash,
                    checksums: checksums, allowUnverified: allowUnverified
                )
                crossChecked.insert(name)
            }
            artifacts[archKey] = HelperManifest.Artifact(url: urlString, sha256: hash)
        }
        helpers[name] = HelperManifest.Helper(version: entry.version, artifacts: artifacts)
    }

    let manifest = HelperManifest(
        formatVersion: HelperManifest.supportedFormatVersion,
        sequence: sequence,
        generated: Date(),
        helpers: helpers
    )

    let manifestData: Data
    do { manifestData = try HelperManifest.encoder().encode(manifest) }
    catch { fail("couldn't encode manifest: \(error)") }

    // Not signed: this file ships inside the app bundle, which macOS seals.
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let manifestURL = URL(fileURLWithPath: outDir).appendingPathComponent("helpers.json")
    do { try manifestData.write(to: manifestURL) }
    catch { fail("couldn't write output: \(error)") }

    let unchecked = sources.helpers.keys.filter { !crossChecked.contains($0) }.sorted()
    if !unchecked.isEmpty {
        note("""

        Note: no upstream checksum list exists for \(unchecked.joined(separator: ", ")), \
        so their hashes are only as trustworthy as this machine's connection at the moment \
        they were fetched. That is still a large improvement on the app trusting whatever \
        arrives at run time, but it is not the same as yt-dlp's GPG-signed list -- worth \
        knowing which is which.
        """)
    }

    note("""

    Wrote \(manifestURL.path), sequence \(sequence).

    Bump the sequence whenever a helper version changes: an installed copy
    compares it against the last one it reconciled, and that is what tells it
    to fetch the new binaries after the app update lands.
    """)
}

let subcommand = CommandLine.arguments.dropFirst().first
switch subcommand {
case "resolve":      commandResolve()
case "build":        commandBuild()
default:
    note("""
    helper-manifest — builds the helper list Convoy checks downloads against.

    The list is not signed: it ships inside the app bundle, which macOS already
    seals. What matters is that every hash in it is right, which is what the
    cross-check below is for.

      resolve
          Turn each helper's 'latest' URL into the immutable versioned URL it
          currently points at, ready to paste into a sources file.

      build --sources <file> --sequence <n> --out <dir>
          Download every pinned artifact, cross-check it against upstream's own
          published checksums where those exist, and write helpers.json.
          Bump --sequence whenever a helper version changes: that is how an
          updated app knows to bring installed helpers into line.
    """)
    exit(subcommand == nil ? 0 : 1)
}
