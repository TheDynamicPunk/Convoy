import Foundation

/// How much of a yt-dlp download is already on disk.
///
/// yt-dlp resumes from its `.part` files, so what is on disk is where the
/// download carries on from. A restored row reads that rather than a saved
/// counter, which a force-quit leaves behind the real figure (the row then
/// jumps up on resume). HTTP downloads follow the same rule: `DownloadSegment`
/// re-reads its temp file's size.
enum YouTubePartialProgress {

    /// The count a restored row opens with: for a YouTube row, what yt-dlp has
    /// on disk (capped at the total, like an HTTP row); for anything else
    /// (`formatSelector` nil), the saved count.
    static func restoredBytes(
        saved: Int64,
        total: Int64,
        taskID: UUID,
        formatSelector: String?,
        destination: URL,
        tempContainer: URL = FileManager.default.temporaryDirectory
    ) -> Int64 {
        guard let formatSelector else { return saved }
        let onDisk = bytesOnDisk(
            taskID: taskID, formatSelector: formatSelector,
            destination: destination, tempContainer: tempContainer
        )
        return total > 0 ? min(onDisk, total) : onDisk
    }

    /// Bytes yt-dlp has written for `taskID`, or 0 when nothing is there. For
    /// video + audio, both tracks added together, as `TwoFileProgress` reports
    /// them. `tempContainer` is a seam for tests.
    static func bytesOnDisk(
        taskID: UUID,
        formatSelector: String,
        destination: URL,
        tempContainer: URL = FileManager.default.temporaryDirectory
    ) -> Int64 {
        let selectors = YouTubeResolver.fileSelectors(in: formatSelector)
        if selectors.count > 1 {
            return twoFileBytes(taskID: taskID, selectors: selectors, tempContainer: tempContainer)
        }
        return singleFileBytes(taskID: taskID, destination: destination)
    }

    /// yt-dlp's `-o` for one format is this literal path: its `.part` while
    /// downloading, the path itself if it finished before the app went away.
    private static func singleFileBytes(taskID: UUID, destination: URL) -> Int64 {
        let scratch = DestinationScratchFile.youTube.url(for: taskID, beside: destination)
        return [scratch.appendingPathExtension("part"), scratch]
            .compactMap(FileSize.bytes(at:))
            .max() ?? 0
    }

    /// Here the names come from a `%(format_id)s.%(ext)s` template, so files
    /// are matched by selector. yt-dlp's `.ytdl` bookkeeping matches none.
    private static func twoFileBytes(taskID: UUID, selectors: [String], tempContainer: URL) -> Int64 {
        let directory = TaskScratchDirectory.youTubeMerge.url(for: taskID, in: tempContainer)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return selectors.reduce(0) { total, selector in
            guard let file = YouTubeResolver.newestFile(matching: selector, in: files) else { return total }
            return total + (FileSize.bytes(at: file) ?? 0)
        }
    }
}
