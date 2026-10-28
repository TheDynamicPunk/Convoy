import Foundation

/// A named folder that finished downloads are routed into, chosen by file
/// type or by the site the download came from.
///
/// Modelled on IDM's categories: one idea that decides the folder, names the
/// group, and (later) filters the list. Deliberately NOT a general rule
/// engine; extension and site are the only criteria in this version.
///
/// Matching, in one place:
/// - `extensions` match the END of the filename, case-insensitively, and may
///   be multi-part ("tar.gz"). A leading dot, a leading "*" or surrounding
///   spaces are ignored, so ".MP3", "*.mp3" and " mp3 " all mean "mp3".
///   "song.mp3.part" is NOT an mp3: it is a suffix match, not a substring one.
/// - `sitePatterns` are host globs where `*` matches any run of characters.
///   A pattern with no `*` matches that host and every subdomain of it, so
///   "example.com" covers "cdn.example.com". "*.example.com" matches
///   subdomains only, not "example.com" itself.
/// - When both lists are non-empty a download must satisfy BOTH. This is
///   IDM's "only from these sites" restriction, and it is what lets "pdf from
///   work.example.com" be a different category from plain "pdf".
/// - A category with no criteria matches nothing. A catch-all has to be a
///   deliberate decision, never the accident of leaving a form blank. The
///   same goes for criteria that are present but all invalid (extensions of
///   just "."): that is "no match", never "silently ignore the restriction
///   and match everything from these sites".
public struct DownloadCategory: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Absolute folder path. A String rather than a URL so the stored JSON
    /// stays plain and survives a hand edit.
    public var folderPath: String
    public var extensions: [String]
    public var sitePatterns: [String]
    // There is deliberately no per-category on/off switch. A category that
    // exists routes; one that is not wanted is deleted, and Reset to Defaults
    // brings the original ones back. Lists saved by earlier builds carry an
    // "enabled" key; decoding ignores unknown keys, so every category in them
    // routes.

    public init(
        id: UUID = UUID(),
        name: String,
        folderPath: String,
        extensions: [String] = [],
        sitePatterns: [String] = []
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.extensions = extensions
        self.sitePatterns = sitePatterns
    }

    /// The folder, with a leading `~` expanded. Only meaningful when
    /// `hasUsableFolder` is true: an empty path would otherwise resolve to the
    /// process's current directory, which is the last place a download should
    /// be filed.
    public var folder: URL {
        URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// False for an empty or relative path (a hand-edited or half-filled
    /// category). Such a category is skipped by routing rather than guessed at.
    public var hasUsableFolder: Bool {
        (folderPath as NSString).expandingTildeInPath.hasPrefix("/")
    }

    /// Whether a download with this final filename, coming from any of
    /// `hosts`, belongs in this category. `hosts` is a list because the
    /// useful host depends on the category: "from github.com" means the
    /// address that was clicked, "from googlevideo.com" means the CDN it was
    /// redirected to. Pass both and a pattern matching either one counts.
    public func matches(filename: String, hosts: [String]) -> Bool {
        let hasExtensionCriteria = !extensions.isEmpty
        let hasSiteCriteria = !sitePatterns.isEmpty
        guard hasExtensionCriteria || hasSiteCriteria else { return false }

        if hasExtensionCriteria {
            let wanted = extensions.compactMap(Self.normalizedExtension)
            guard !wanted.isEmpty else { return false }
            let name = filename.lowercased()
            let hit = wanted.contains { ext in
                // The length check keeps a file that is nothing but the
                // extension (".mp3") from counting as an mp3.
                name.count > ext.count + 1 && name.hasSuffix("." + ext)
            }
            guard hit else { return false }
        }

        if hasSiteCriteria {
            let patterns = sitePatterns.compactMap(Self.normalizedSitePattern)
            guard !patterns.isEmpty else { return false }
            let lowered = hosts.map { $0.lowercased() }
            let hit = lowered.contains { host in
                patterns.contains { Self.host(host, matches: $0) }
            }
            guard hit else { return false }
        }

        return true
    }

    // MARK: - Normalisation (public so the tests and the settings editor
    // can show what a typed value will be treated as)

    /// "  .MP3 " -> "mp3", "*.tar.gz" -> "tar.gz". Nil when nothing usable is
    /// left, or when what remains still looks like a path or a glob.
    public static func normalizedExtension(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("*") { s.removeFirst() }
        while s.hasPrefix(".") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        guard !s.contains("*"), !s.contains("/"),
              s.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return s
    }

    /// "https://Example.com:8080/downloads" -> "example.com". Nil when empty.
    public static func normalizedSitePattern(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        return s.isEmpty ? nil : s
    }

    /// Splits a comma- or whitespace-separated list of extensions into clean,
    /// unique normalised values (" .MP3, *.tar.gz , mp3 " -> ["mp3", "tar.gz"]).
    public static func parseExtensions(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0.isNewline }) {
            guard let ext = normalizedExtension(String(token)),
                  seen.insert(ext).inserted else { continue }
            result.append(ext)
        }
        return result
    }

    /// Splits a comma- or whitespace-separated list of site patterns into
    /// clean, unique normalised patterns.
    public static func parseSitePatterns(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in raw.split(whereSeparator: { $0 == "," || $0.isWhitespace || $0.isNewline }) {
            guard let site = normalizedSitePattern(String(token)),
                  seen.insert(site).inserted else { continue }
            result.append(site)
        }
        return result
    }

    /// The original categories: Music, Video, Documents, Books, Archives,
    /// Programs and Images, each filing into a subfolder of `downloadsFolder`
    /// (for example `~/Downloads/Music`). This is what a fresh install shows
    /// and what "Reset to Defaults" restores. No extension appears in more
    /// than one category, and none is one that is mostly something else
    /// ("ts" is left out of Video on purpose: far more of those files are
    /// TypeScript source than video).
    ///
    /// The ids are FIXED, not generated. A downloads row finds its category
    /// by id, and the defaults can be re-created at any moment (every read of
    /// a never-edited list, every reset), so random ids would orphan every
    /// row that was already filed.
    public static func suggestedCategories(in downloadsFolder: String) -> [DownloadCategory] {
        let base: String = {
            let expanded = (downloadsFolder as NSString).expandingTildeInPath
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if expanded.hasPrefix("/") { return expanded }
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                ?? (NSHomeDirectory() + "/Downloads")
        }()
        func path(_ subfolder: String) -> String {
            URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(subfolder, isDirectory: true).path
        }
        return [
            DownloadCategory(
                id: starterID("Music"),
                name: "Music",
                folderPath: path("Music"),
                extensions: ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma", "aiff"]
            ),
            DownloadCategory(
                id: starterID("Video"),
                name: "Video",
                folderPath: path("Video"),
                extensions: ["mp4", "mkv", "mov", "webm", "avi", "m4v", "flv", "mpg", "mpeg"]
            ),
            DownloadCategory(
                id: starterID("Documents"),
                name: "Documents",
                folderPath: path("Documents"),
                extensions: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv", "pages", "numbers", "key", "odt", "ods", "odp"]
            ),
            DownloadCategory(
                id: starterID("Books"),
                name: "Books",
                folderPath: path("Books"),
                extensions: ["epub", "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "djvu"]
            ),
            DownloadCategory(
                id: starterID("Archives"),
                name: "Archives",
                folderPath: path("Archives"),
                extensions: ["zip", "tar.gz", "tgz", "tar.bz2", "tar.xz", "tar", "gz", "bz2", "xz", "7z", "rar", "zst"]
            ),
            DownloadCategory(
                id: starterID("Programs"),
                name: "Programs",
                folderPath: path("Programs"),
                extensions: ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "deb", "rpm", "apk", "ipa"]
            ),
            DownloadCategory(
                id: starterID("Images"),
                name: "Images",
                folderPath: path("Images"),
                extensions: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "svg", "tiff", "tif", "bmp", "ico", "avif"]
            ),
        ]
    }

    private static let starterIDs: [String: String] = [
        "Music": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F01",
        "Video": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F02",
        "Documents": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F03",
        "Books": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F04",
        "Archives": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F05",
        "Programs": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F06",
        "Images": "B6A1E2D4-7C31-4F58-9E0A-1D2C3B4A5F07"
    ]

    private static func starterID(_ name: String) -> UUID {
        starterIDs[name].flatMap(UUID.init(uuidString:)) ?? UUID()
    }

    static func host(_ host: String, matches pattern: String) -> Bool {
        if pattern.contains("*") { return globMatch(pattern, host) }
        return host == pattern || host.hasSuffix("." + pattern)
    }

    /// `*`-only glob. Iterative, so a hostile pattern cannot blow the stack
    /// or go exponential the way a naive recursive matcher can.
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if pi < p.count, p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Picks the category a download belongs to. Pure: no disk, no settings, no
/// task state, so it is testable on its own and callable from anywhere that
/// links DownloadEngine (the native messaging host included).
public enum CategoryRouter {

    /// An extension claimed by more than one category, with the categories
    /// that claim it in priority (list) order.
    public struct DuplicateExtension: Equatable, Sendable, Identifiable {
        public let ext: String
        public let categoryNames: [String]
        public var id: String { ext }

        public init(ext: String, categoryNames: [String]) {
            self.ext = ext
            self.categoryNames = categoryNames
        }
    }

    /// The first matching category in list order. List order IS the priority
    /// order: put "tar.gz" above "gz" if both exist. A person changes the
    /// order with the arrows in Settings.
    public static func match(
        filename: String,
        hosts: [String],
        in categories: [DownloadCategory]
    ) -> DownloadCategory? {
        categories.first { $0.matches(filename: filename, hosts: hosts) }
    }

    /// Unique, lowercased hosts from whichever URLs are available, in the
    /// order given. Nil entries are skipped so callers can pass the original
    /// and resolved URLs without unwrapping either.
    public static func hosts(from urls: [URL?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case let url? in urls {
            guard let host = url.host?.lowercased(), seen.insert(host).inserted else { continue }
            result.append(host)
        }
        return result
    }

    /// Extensions that appear in two or more categories, in the order they are
    /// first seen. Normalised before comparing, so ".MP3" and "mp3" count as
    /// the same extension, while a category that lists "mp3" twice inside its
    /// own list does not warn against itself.
    public static func duplicateExtensions(in categories: [DownloadCategory]) -> [DuplicateExtension] {
        var order: [String] = []
        var claimants: [String: [String]] = [:]
        for category in categories {
            var seenInCategory = Set<String>()
            for raw in category.extensions {
                guard let ext = DownloadCategory.normalizedExtension(raw),
                      seenInCategory.insert(ext).inserted else { continue }
                if claimants[ext] == nil { order.append(ext) }
                claimants[ext, default: []].append(category.name)
            }
        }
        return order.compactMap { ext in
            guard let names = claimants[ext], names.count >= 2 else { return nil }
            return DuplicateExtension(ext: ext, categoryNames: names)
        }
    }
}
