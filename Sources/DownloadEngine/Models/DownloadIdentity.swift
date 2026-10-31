import Foundation

/// What makes two downloads "the same download" for duplicate detection.
///
/// Pulled out of `DownloadManager.existingTask` and given a name because the
/// rule is subtler than it looks and is the thing every add path must agree
/// on. It is deliberately the *only* definition: a path that answers this
/// question its own way is how the app ends up telling one person "already in
/// your list" and silently overwriting someone else's file.
///
/// Two arms, and both are needed:
///
/// - **Same URL and the same YouTube format.** For everything except YouTube
///   the format is `nil` on both sides, so this reads as plain URL equality.
///   YouTube is the one source where a single URL legitimately produces many
///   different files — the watch page is the task's URL for every quality of
///   the video — so without the format term, asking for 4K when 1080p is
///   already in the list would be called a duplicate and offer to "resume" a
///   file that is not the same file.
/// - **Same destination name.** The backstop, unconditional. Two requests that
///   would write to the same path collide whatever they are, and it is what
///   still catches the same quality with a different dubbed audio track: a
///   different selector, so the first arm lets it through, but the same
///   filename on disk.
///
/// One veto comes before both arms: **two files of known, different sizes are
/// not the same download**, whatever their names or URLs. Like the format
/// selector, it keeps different renditions of one title apart. It is evidence
/// of difference only, so it never merges downloads that would otherwise be
/// separate, and a missing size on either side says nothing.
struct DownloadIdentity: Equatable {
    /// The task's source URL. For a YouTube task this is the watch page, which
    /// is why the selector below exists.
    let url: URL
    /// The name the download would be saved under, before any " (n)"
    /// deduplication — `DownloadTask.originalName`.
    let name: String
    /// The yt-dlp format selector a YouTube request would download with
    /// (`"137,140"`), or nil for every other kind of download.
    let youTubeFormatSelector: String?
    /// The whole file's size in bytes when exactly known, otherwise nil. Never
    /// known for streams or YouTube, whose totals are estimates.
    let size: Int64?

    init(url: URL, name: String, youTubeFormatSelector: String? = nil, size: Int64? = nil) {
        self.url = url
        self.name = name
        self.youTubeFormatSelector = youTubeFormatSelector
        // Zero or negative means "unknown", not "empty".
        self.size = (size ?? 0) > 0 ? size : nil
    }

    func isSameDownload(as other: DownloadIdentity) -> Bool {
        if let size = size, let otherSize = other.size, size != otherSize {
            return false
        }
        if url == other.url, youTubeFormatSelector == other.youTubeFormatSelector {
            return true
        }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }
}

extension DownloadTask {
    /// This task's identity for duplicate detection. `originalName` rather
    /// than the current destination's name on purpose: a task already renamed
    /// to "video (1).mp4" must still be recognised as the download it is.
    var identity: DownloadIdentity {
        DownloadIdentity(
            url: url, name: originalName, youTubeFormatSelector: ytFormatSelector,
            // Stream and yt-dlp totals are estimates; only direct downloads
            // have an exact size to compare.
            size: (streamURL == nil && ytFormatSelector == nil) ? totalBytes : nil
        )
    }
}
