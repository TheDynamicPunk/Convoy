import Foundation
import UniformTypeIdentifiers

/// What kind of file something is, for showing it: the icon and colour beside
/// its name. One answer for every screen that draws a file, so the downloads
/// list and the capture dialog cannot disagree about what a PNG or a JSON
/// file is.
///
/// This is not a download category. Categories are the person's own folders
/// and rules (see `DownloadCategory`) and can be renamed, reordered or
/// deleted. A kind is fixed, and a file has one whether or not any category
/// claims it.
///
/// The file's last extension decides ("backup.tar.gz" is judged by "gz"), so
/// the table below is the whole story for the common cases. An extension the
/// table does not list is put to the system's type database before giving up,
/// which keeps rarer media, documents and source files from landing in
/// `.other` just because nobody wrote them down here.
public enum FileKind: String, CaseIterable, Sendable {
    case video
    case audio
    case image
    case document
    case book
    case archive
    /// Installers and disk images: things you open to install or run.
    case program
    /// Source, markup and data files a developer handles: json, yaml, swift...
    case code
    case other

    public init(filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let known = Self.byExtension[ext] {
            self = known
        } else {
            self = Self.fromTypeSystem(extension: ext) ?? .other
        }
    }

    /// Every extension each kind claims, lowercased and without a dot. An
    /// extension belongs to one kind only (a test pins this).
    ///
    /// "ts" is under `.code` on purpose: far more of those files are
    /// TypeScript than MPEG transport streams, the same call the default
    /// download categories make.
    public static let extensions: [FileKind: [String]] = [
        .video: ["mp4", "mkv", "mov", "webm", "avi", "m4v", "flv", "mpg", "mpeg"],
        .audio: ["mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "wma", "aiff"],
        .image: ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "svg", "tiff", "tif", "bmp", "ico", "avif"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "csv",
                    "pages", "numbers", "key", "odt", "ods", "odp"],
        .book: ["epub", "mobi", "azw", "azw3", "fb2", "cbz", "cbr", "djvu"],
        .archive: ["zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar", "zst"],
        .program: ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "deb", "rpm", "apk", "ipa"],
        .code: [
            // Data and configuration
            "json", "jsonc", "json5", "jsonl", "ndjson", "ipynb", "xml", "yaml", "yml", "toml",
            "ini", "plist", "sql", "graphql", "proto",
            // Web
            "html", "htm", "css", "scss", "sass", "less", "js", "mjs", "cjs", "ts", "tsx", "jsx", "vue",
            // Languages
            "swift", "py", "rb", "go", "rs", "java", "kt", "kts", "scala", "dart", "lua", "pl", "php",
            "c", "h", "cpp", "hpp", "cc", "cs", "m", "mm",
            // Shell
            "sh", "bash", "zsh",
        ],
    ]

    private static let byExtension: [String: FileKind] = {
        var table: [String: FileKind] = [:]
        for (kind, list) in extensions {
            for ext in list { table[ext] = kind }
        }
        return table
    }()

    /// The system's answer for an extension the table does not list. Source
    /// code is asked before plain text because it is a kind of text; disk
    /// images are programs (like dmg and iso above), not archives.
    private static func fromTypeSystem(extension ext: String) -> FileKind? {
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .diskImage) { return .program }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .text)
            || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return .document
        }
        return nil
    }
}
