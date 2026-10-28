import Foundation

/// Where a category would put a download.
public struct CategoryRoute: Equatable, Sendable {
    public let category: DownloadCategory
    /// The category's folder plus the download's filename. Not yet checked
    /// against files already in that folder; the caller de-duplicates.
    public let destination: URL
}

/// The decision of whether a download is filed into a category, kept apart
/// from everything that acts on it so the rules for it can be tested alone.
public enum CategoryRouting {

    /// Native HLS/DASH downloads are added with a name that has no extension
    /// (the extension supplies a title or a manifest stem) and are assembled
    /// into `.mp4` or `.ts` at the end, so there is nothing to match an
    /// extension rule against when the destination is chosen. They are
    /// matched as if named `.mp4`: a stream is video, and a person who files
    /// "mp4" into a Video category means these too. Only the name used for
    /// MATCHING changes; the file keeps whatever extension assembly gives it.
    public static let assumedStreamExtension = "mp4"

    public static func streamMatchName(for filename: String) -> String {
        filename + "." + assumedStreamExtension
    }

    /// Whether any category could take a file at all: at least one with a
    /// usable folder. The one definition of "sorting is
    /// really in effect", so the New Download window and the add paths cannot
    /// disagree about whether there is anything to be automatic about.
    public static func hasAnyRoutableCategory(_ categories: [DownloadCategory]) -> Bool {
        categories.contains { $0.hasUsableFolder }
    }

    /// The category this download should be filed into, or nil to leave it
    /// exactly where it is.
    ///
    /// Nil whenever any of these hold, in this order of importance:
    /// - `folderIsExplicit`: a folder a person picked beats every category.
    /// - `alreadyRouted`: where a download goes is decided once. Editing the
    ///   categories later must not move a download already under way, and a
    ///   restart after a changed remote file must land where it did before.
    /// - nothing matches, or no category is turned on.
    ///
    /// `filename` is what the file is called; `matchName` is what to test
    /// the extension rules against when that differs (see
    /// `assumedStreamExtension`). Categories whose folder is empty or
    /// relative are skipped, so a half-filled category cannot file anything
    /// into the app's working directory.
    public static func route(
        filename: String,
        matchName: String? = nil,
        hosts: [String],
        categories: [DownloadCategory],
        folderIsExplicit: Bool,
        alreadyRouted: Bool
    ) -> CategoryRoute? {
        guard !folderIsExplicit, !alreadyRouted else { return nil }
        let usable = categories.filter(\.hasUsableFolder)
        guard let category = CategoryRouter.match(
            filename: matchName ?? filename, hosts: hosts, in: usable
        ) else { return nil }
        return CategoryRoute(
            category: category,
            destination: category.folder.appendingPathComponent(filename)
        )
    }

    /// What to tell the person when a category matched but its folder could
    /// not be used and the file was saved where it already was instead.
    public static func fallbackNotice(
        category: DownloadCategory,
        reason: CategoryFolder.Reason,
        savedTo folder: URL
    ) -> String {
        "Couldn't use the \(category.name) folder (\(reason.phrase)). Saved to \(folder.lastPathComponent) instead."
    }
}

/// Getting a category's folder ready to receive a file.
///
/// Free of any task or settings state and safe to call off the main actor,
/// which matters: the first time the app touches a protected location (the
/// Documents or Desktop folder, an external or network volume) macOS can put
/// up a permission prompt, and the file call that triggers it does not
/// return until it is answered. Run on the main actor, that freezes the
/// window.
public enum CategoryFolder {

    public enum Reason: Equatable, Sendable {
        case volumeNotMounted
        case notAFolder
        case notWritable
        case cannotCreate

        /// Reads after "Couldn't use the Music folder (...)".
        public var phrase: String {
            switch self {
            case .volumeNotMounted: return "the drive isn't connected"
            case .notAFolder: return "a file with that name is in the way"
            case .notWritable: return "it isn't writable"
            case .cannotCreate: return "it couldn't be created"
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case ready
        case created
        case unavailable(Reason)
    }

    /// Makes sure `folder` exists and can be written to, creating it (and any
    /// missing parents) when it does not exist. The person asked for this
    /// folder by naming it in a category, so creating it is the expected
    /// result rather than a surprise.
    ///
    /// The one thing never created is a folder inside a disappeared volume.
    /// If `/Volumes/Backup` is not there, `/Volumes/Backup/Music` must read
    /// as "the drive isn't connected", not be built as an ordinary directory
    /// (or fail with an unhelpful permissions error) that then looks like a
    /// real destination.
    public static func prepare(_ folder: URL, fileManager: FileManager = .default) -> Outcome {
        let standardized = folder.standardizedFileURL
        let parts = standardized.pathComponents
        if parts.count >= 3, parts[1] == "Volumes" {
            let volumeRoot = "/Volumes/" + parts[2]
            if !fileManager.fileExists(atPath: volumeRoot) {
                return .unavailable(.volumeNotMounted)
            }
        }

        let path = standardized.path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return .unavailable(.notAFolder) }
            return fileManager.isWritableFile(atPath: path) ? .ready : .unavailable(.notWritable)
        }

        do {
            try fileManager.createDirectory(at: standardized, withIntermediateDirectories: true)
            return .created
        } catch {
            return .unavailable(.cannotCreate)
        }
    }
}
