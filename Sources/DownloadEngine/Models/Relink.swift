import Foundation

/// How a capture taken while a Re-link is waiting compares with the download
/// being re-linked.
///
/// The question is "is this the same file?", asked before a fresh link is
/// spliced onto the partial bytes already on disk. Size is the only evidence
/// the browser reliably gives (the extension sends `Content-Length` for video
/// captures and Chrome-intercepted downloads), so it is the test: equal sizes
/// mean the same file, and anything else is put to the person rather than
/// guessed at.
public enum RelinkVerdict: Equatable {
    /// Same size as the download being re-linked: safe to resume in place.
    case sameFile
    /// Both sizes are known and they differ: a different file, or a different
    /// quality of the same one.
    case differentSize(expected: Int64, offered: Int64)
    /// One side's size is unknown (the right-click capture path sends none, and
    /// a download that never got its first response has no size either), so
    /// sameness cannot be shown. Treated like a mismatch rather than trusted:
    /// the cost of being wrong is splicing two different files together.
    case cannotVerify

    /// `expected` is the download's own `totalBytes` (0 when never known);
    /// `offered` is what the new capture says.
    public static func judge(expected: Int64, offered: Int64?) -> RelinkVerdict {
        guard expected > 0, let offered, offered > 0 else { return .cannotVerify }
        return offered == expected ? .sameFile : .differentSize(expected: expected, offered: offered)
    }
}

/// Whether a capture's name matches the download being re-linked.
///
/// Shown beside the size in the mismatch prompt, because a different name is
/// often the first thing a person recognises (another episode, another
/// quality, another version). It does not decide whether a link is accepted;
/// `RelinkVerdict` still does that, from the size.
public enum RelinkNameVerdict: Equatable {
    case same
    case different
    /// The browser sent no name; the capture only has one guessed from its
    /// link (`CapturedDownload.displayName`). Comparing that would flag
    /// `download?id=7` against `app.dmg` every time, so nothing is claimed.
    case unknown

    /// `known` is every name the download has gone by (its current file name
    /// and the name it was created with); a match with any of them is a match.
    /// Case and surrounding whitespace do not count as a difference.
    public static func judge(known: [String], offered: String?) -> RelinkNameVerdict {
        guard let offered = normalized(offered) else { return .unknown }
        return known.contains { normalized($0) == offered } ? .same : .different
    }

    private static func normalized(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

extension CapturedDownload {
    /// The file size this capture claims, if it claims one.
    ///
    /// Read from the extension's `Content-Length` (kept in `matchHeaders`
    /// precisely for this) and otherwise from `expectedSize`.
    public var offeredSize: Int64? {
        let header = matchHeaders.first {
            $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame
        }?.value
        if let header, let bytes = Int64(header.trimmingCharacters(in: .whitespaces)), bytes > 0 {
            return bytes
        }
        if let expectedSize, expectedSize > 0 { return expectedSize }
        return nil
    }
}

extension DownloadManager {
    /// Swaps a fresh link onto an expired download and starts it again.
    ///
    /// `restart: false` keeps the partial data and continues from where the
    /// old link stopped; the caller has already established it is the same
    /// file. `restart: true` throws the partial data away first, so the
    /// download begins again from byte 0 against the new link (the person
    /// accepted that the file is not the one they had). Either way the row,
    /// its id and its destination are the same ones.
    ///
    /// `headers` must be the capture's real outgoing headers
    /// (`CapturedDownload.headers`), never `matchHeaders`, which carries
    /// `Content-Length`.
    ///
    /// Returns false, changing nothing, if the task is no longer `.urlExpired`.
    @discardableResult
    public func relink(
        _ task: DownloadTask,
        to url: URL,
        headers: [String: String],
        restart: Bool,
        rename: (name: String, source: FilenameSource)? = nil
    ) -> Bool {
        guard case .urlExpired = task.status else { return false }
        // relinkURL only accepts .urlExpired and leaves the task .paused.
        task.relinkURL(url, headers: headers)
        // Discarding resets totalBytes to 0, which also makes the resume-time
        // validator skip itself and the fresh probe record the new file's own
        // validators (see DownloadTask.validateResourceUnchangedIfNeeded).
        if restart {
            task.discardProgressForFreshRestart()
            // After the discard, which cleans up beside the old destination.
            // Only on a restart: a resume keeps the file it was already
            // writing, so it keeps that file's name too.
            if let rename { task.adoptNameAfterRestart(rename.name, source: rename.source) }
        }
        Task { try? await resumeDownload(task) }
        return true
    }

    /// Re-links with a capture the browser just made.
    ///
    /// On a restart, a name the browser supplied that differs from the
    /// download's own is adopted, so the row stops carrying the name of a file
    /// it no longer is. Nothing is renamed when the browser sent no name (the
    /// one `displayName` guesses from the link is not evidence of anything),
    /// when the names already match, or on a resume.
    @discardableResult
    public func relink(_ task: DownloadTask, with capture: CapturedDownload, restart: Bool) -> Bool {
        var rename: (name: String, source: FilenameSource)?
        if restart,
           let offered = capture.suggestedFilename,
           RelinkNameVerdict.judge(known: [task.filename, task.originalName], offered: offered) == .different {
            rename = (offered, capture.filenameSource ?? .mediaTitle)
        }
        return relink(task, to: capture.url, headers: capture.headers, restart: restart, rename: rename)
    }
}
