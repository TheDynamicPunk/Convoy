import Foundation

/// A per-download scratch directory in the system temp folder, named
/// `<prefix><task id>`.
///
/// Putting the owning task's id *in the directory name* is the whole point:
/// a leftover directory can always be matched back to the download it belongs
/// to, or shown to belong to no download at all. That is what lets cleanup be
/// driven by identity — "does a row still exist for this?" — rather than by
/// age. An earlier `mdl-yt-` sweep deleted anything untouched for 24 hours,
/// which meant a download paused overnight silently lost every partial byte
/// the next time any other YouTube download started.
///
/// Both kinds are declared together so that adding a third cannot repeat the
/// drift this type was extracted to end: each name used to be spelled out by
/// hand in the service that creates the directory *and* again in
/// `DownloadTask.cleanupTempFiles()` that removes it, with nothing tying the
/// two sites together — so `mdl-stream-` was removed when a row was deleted
/// and `mdl-yt-` was not.
enum TaskScratchDirectory: CaseIterable, Sendable {
    /// yt-dlp's two output files for a video-only + audio-only pick, held
    /// until `MediaMuxer` has merged them. Deliberately left in place on
    /// pause or failure: it is exactly what `--continue` resumes from.
    case youTubeMerge
    /// One subdirectory per track of fetched HLS/DASH segments, written by
    /// `StreamDownloader`.
    case streamSegments

    var prefix: String {
        switch self {
        case .youTubeMerge: "mdl-yt-"
        case .streamSegments: "mdl-stream-"
        }
    }

    /// Where this kind of scratch space lives for `taskID`.
    ///
    /// `container` exists so tests can work in a directory of their own
    /// instead of the real temp folder; production callers take the default.
    func url(
        for taskID: UUID,
        in container: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        container.appendingPathComponent(prefix + taskID.uuidString, isDirectory: true)
    }

    /// The task id encoded in `name`, or nil when `name` is not one of this
    /// kind's directories or carries something that is not a UUID.
    func taskID(fromDirectoryName name: String) -> UUID? {
        guard name.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))
    }

    /// Removes `taskID`'s directory, whether or not it exists.
    ///
    /// Called when a download row goes away — which is what makes "delete the
    /// download and its temp files go with it" true, and what keeps these
    /// directories from needing an expiry rule at all.
    func remove(
        for taskID: UUID,
        in container: URL = FileManager.default.temporaryDirectory
    ) {
        try? FileManager.default.removeItem(at: url(for: taskID, in: container))
    }
}
