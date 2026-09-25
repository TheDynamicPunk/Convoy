import Foundation

/// A per-download scratch file written in the destination's folder until the
/// finished file takes its real name, named `<prefix><task id>[.<ext>]`.
///
/// In the destination's folder rather than the temp folder so taking the
/// final name is a rename on the same volume, not a second copy of a large
/// file onto an external drive. Hidden, so a download in progress never shows
/// up as a stray file, and keyed by task id, so it can never match a file the
/// person owns.
///
/// Every download path names its file here, and `removeAll` removes every
/// kind, so deleting a download leaves nothing beside its destination whatever
/// kind of download it was. The temp-folder counterpart is
/// `TaskScratchDirectory`.
enum DestinationScratchFile: CaseIterable, Sendable {
    /// yt-dlp's single-format output, plus the `.part` and `.ytdl` files it
    /// writes beside it while downloading.
    case youTube
    /// `MediaMuxer`'s export, for every merge of a video and an audio track.
    case mux
    /// The byte-range engine's segments, merged into one file.
    case segmentMerge
    /// A single-track HLS/DASH stream's segments, joined into one file.
    case streamAssembly

    var prefix: String {
        switch self {
        case .youTube: ".mdl-yt-"
        case .mux: ".mdl-mux-"
        case .segmentMerge: ".mdl-merge-"
        case .streamAssembly: ".mdl-track-"
        }
    }

    /// The scratch file for `taskID` beside `destination`, carrying `ext` —
    /// the destination's own extension unless the writer fixes one.
    func url(for taskID: UUID, beside destination: URL, extension ext: String? = nil) -> URL {
        let ext = ext ?? destination.pathExtension
        let name = prefix + taskID.uuidString + (ext.isEmpty ? "" : "." + ext)
        return destination.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Removes every scratch file of every kind that `taskID` left in
    /// `folder`, including the files a writer derives from its own name
    /// (yt-dlp's `.part` and `.ytdl`). A no-op when there are none.
    static func removeAll(for taskID: UUID, in folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let owned = allCases.map { $0.prefix + taskID.uuidString }
        for name in names where owned.contains(where: name.hasPrefix) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
