import Foundation

/// Says which helper binaries this app should install, where to get them, and
/// what they must hash to.
///
/// ## Why this exists
///
/// The installer used to ask GitHub for "the latest" of each helper and run
/// whatever came back, with no idea what it was supposed to receive. Every
/// helper it installs — yt-dlp, qjs, bgutil-pot and its plugin — is ad-hoc
/// signed, with no publisher identity to pin, so the only thing that can tell
/// the real one from a substitute is knowing its hash in advance.
///
/// (There was briefly a second mechanism pinning Developer ID signatures, for
/// deno and then ffmpeg. Both helpers are gone, and with them the last signed
/// publisher, so that code went too rather than sitting unused.)
///
/// Knowing the hash in advance is the whole problem. Asking the download host
/// what the download should hash to is circular: a compromised host answers
/// with the hash of whatever it is serving. So the expected hashes are decided
/// somewhere else — on the maintainer's machine, where upstream's own
/// GPG-signed checksums can actually be checked — and shipped inside the app.
///
/// The file carries no signature of its own. It used to, because it was also
/// served from a network feed where nothing else vouched for it. That feed is
/// gone: this now ships only inside the app bundle, which macOS seals, so the
/// app's own code signature is what protects it.
public struct HelperManifest: Codable, Sendable, Equatable {

    /// Bumped only for a breaking change in this structure. An app that does
    /// not recognise the value refuses the manifest rather than guessing at
    /// fields it may not understand.
    public static let supportedFormatVersion = 1

    public let formatVersion: Int

    /// Monotonic counter, the defence against being fed an old-but-genuine
    /// manifest. A hostile or merely stale host can withhold updates, but it
    /// cannot walk a client backwards onto a helper version that was pulled
    /// for being broken or compromised: the app remembers the highest
    /// sequence it has accepted and refuses anything lower.
    public let sequence: Int

    /// When this was generated. Informational — shown in the UI so a user
    /// can see how current their pinning is. Deliberately NOT an expiry:
    /// refusing to work because the maintainer has not cut a manifest
    /// recently would turn a quiet maintenance lapse into a broken app for
    /// everyone, which is a worse failure than slightly stale pins.
    public let generated: Date

    /// Keyed by helper name: "yt-dlp", "quickjs", "bgutil-pot",
    /// "bgutil-pot-plugin".
    public let helpers: [String: Helper]

    public struct Helper: Codable, Sendable, Equatable {
        /// Upstream version, for display and for release notes. Not used in
        /// any trust decision — the hash is what is actually checked.
        public let version: String

        /// Keyed by `Architecture.key`. A helper published as one universal
        /// binary has a single "universal" entry.
        public let artifacts: [String: Artifact]

        public init(version: String, artifacts: [String: Artifact]) {
            self.version = version
            self.artifacts = artifacts
        }
    }

    public struct Artifact: Codable, Sendable, Equatable {
        /// Exact release URL. Deliberately a pinned version rather than a
        /// "latest" redirect: "latest" means the bytes can change under a
        /// fixed URL, which is precisely what makes a hash useless.
        public let url: String

        /// Lowercase hex SHA-256 of the bytes served at `url` — the
        /// downloaded artifact itself, checked before it is unpacked, so
        /// nothing untrusted is ever handed to `unzip`.
        public let sha256: String

        public init(url: String, sha256: String) {
            self.url = url
            self.sha256 = sha256
        }
    }

    public enum Architecture: Sendable {
        case arm64
        case x86_64

        public var key: String {
            switch self {
            case .arm64: return "arm64"
            case .x86_64: return "x86_64"
            }
        }

        public static var current: Architecture {
            #if arch(arm64)
            return .arm64
            #else
            return .x86_64
            #endif
        }
    }

    public init(formatVersion: Int, sequence: Int, generated: Date, helpers: [String: Helper]) {
        self.formatVersion = formatVersion
        self.sequence = sequence
        self.generated = generated
        self.helpers = helpers
    }

    /// The artifact to install for `helper` on this machine: the
    /// architecture-specific entry if one exists, otherwise the universal
    /// one. Throws rather than returning nil so the caller cannot quietly
    /// fall through to an unpinned download.
    public func artifact(
        for helper: String,
        architecture: Architecture = .current
    ) throws -> Artifact {
        guard let entry = helpers[helper] else {
            throw HelperManifestError.unknownHelper(helper)
        }
        if let specific = entry.artifacts[architecture.key] {
            return specific
        }
        if let universal = entry.artifacts["universal"] {
            return universal
        }
        throw HelperManifestError.noArtifact(helper: helper, architecture: architecture.key)
    }

    public func version(of helper: String) -> String? {
        helpers[helper]?.version
    }

    // MARK: - Coding

    /// Dates as ISO 8601, so the file stays readable and diffable in a repo
    /// rather than carrying a float nobody can eyeball.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

public enum HelperManifestError: LocalizedError, Equatable {
    case unsupportedFormat(found: Int, supported: Int)
    case badSignature
    case rolledBack(offered: Int, alreadyAccepted: Int)
    case unknownHelper(String)
    case noArtifact(helper: String, architecture: String)
    case hashMismatch(helper: String, expected: String, actual: String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let found, let supported):
            return "The helper list is format version \(found); this version of Convoy understands version \(supported). Update the app."
        case .badSignature:
            return "The helper list isn't correctly signed, so it was ignored. Nothing was downloaded or installed."
        case .rolledBack(let offered, let alreadyAccepted):
            return "The helper list offered (#\(offered)) is older than one already accepted (#\(alreadyAccepted)), so it was ignored."
        case .unknownHelper(let name):
            return "The helper list has no entry for \(name)."
        case .noArtifact(let helper, let architecture):
            return "The helper list has no \(helper) build for this Mac's architecture (\(architecture))."
        case .hashMismatch(let helper, let expected, let actual):
            return """
            The downloaded \(helper) doesn't match what the signed helper list expects, so it was not installed. \
            Expected \(expected.prefix(16))…, got \(actual.prefix(16))….
            """
        case .unavailable:
            return "No verified helper list is available, so nothing was installed. Check your internet connection and try again."
        }
    }
}
