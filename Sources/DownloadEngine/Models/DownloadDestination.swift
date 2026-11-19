import Foundation

/// Names a finished download's file, and takes that name without ever
/// destroying what is already there.
///
/// Two questions get asked about a download's filename, at different times,
/// and they are not the same question:
///
/// 1. **"Is this the same download?"** — identity, asked when the request
///    arrives, answered by `DownloadIdentity` and settled by a person through
///    the duplicate sheet.
/// 2. **"Is this path free right now?"** — asked at the moment of writing,
///    answered by the filesystem, and no business of a person's: a download
///    can finish an hour later while nobody is at the machine, so the only
///    sensible outcome is to save beside the other file rather than block on a
///    dialog or destroy it.
///
/// This type is only ever the second question.
///
/// It exists because every write path answered it by *deleting the file at the
/// destination first* — `removeItem(at: destinationURL)` before `moveItem`, on
/// three paths, and `FileManager.createFile` (which silently replaces) on the
/// fourth. The deletion was there to stop `moveItem` throwing
/// `NSFileWriteFileExistsError`, which is to say: the one guarantee the system
/// offers was switched off on purpose. A file the person saved into that
/// folder during the hour the download was running was simply gone.
///
/// So nothing here checks and then writes. Check-then-write cannot be correct
/// across that window no matter how carefully it is done — the answer is stale
/// the instant it is given. Instead the write *is* the check: the filesystem
/// either gives us the name or refuses it, atomically, and a refusal means try
/// the next one.
enum DownloadDestination {

    /// Refused to find a free name. Only reachable with `limit` files already
    /// holding every candidate — which is not a real situation, and is thrown
    /// rather than papered over precisely because the alternative every
    /// previous implementation reached for was to overwrite something.
    struct NoFreeNameError: Error {
        let requested: URL
        let attempts: Int
    }

    /// How many names to try before giving up.
    private static let limit = 10_000

    /// The `n`th name for `url`: 0 is the name itself, then "stem (1).ext",
    /// "stem (2).ext", and so on.
    ///
    /// The one definition of what a " (n)" suffix looks like, shared with
    /// `DownloadManager.deduplicatedDestination` so the name a person is
    /// promised in the duplicate sheet is the name they get on disk.
    ///
    /// A folder has no extension, so with `isDirectory` the whole name comes
    /// before the suffix: "Ubuntu 24.04.1" becomes "Ubuntu 24.04.1 (1)", where
    /// reading ".1" as an extension would give "Ubuntu 24.04 (1).1".
    static func candidate(for url: URL, suffix n: Int, isDirectory: Bool = false) -> URL {
        guard n > 0 else { return url }
        let parent = url.deletingLastPathComponent()
        if isDirectory {
            return parent.appendingPathComponent("\(url.lastPathComponent) (\(n))", isDirectory: true)
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
        return parent.appendingPathComponent(name)
    }

    /// Offers `attempt` the name itself, then each " (n)" name, until one takes
    /// it, and returns the name taken.
    ///
    /// The loop every claim here shares. `attempt` does the one atomic thing
    /// that both checks and takes a name (an `O_EXCL` create, a `mkdir`, a
    /// `moveItem`) and answers `true` if it took it, `false` if the name was
    /// already in use. Anything else it throws: a failure that is not "taken"
    /// is a real error and is never retried under another name.
    private static func firstFree(
        for url: URL,
        isDirectory: Bool = false,
        attempt: (URL) throws -> Bool
    ) throws -> URL {
        for n in 0..<limit {
            let target = candidate(for: url, suffix: n, isDirectory: isDirectory)
            if try attempt(target) { return target }
        }
        throw NoFreeNameError(requested: url, attempts: limit)
    }

    private static func posixError(_ code: Int32, at target: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: target.path,
            NSLocalizedDescriptionKey: String(cString: strerror(code)),
        ])
    }

    /// Creates an empty file at `url`, or at the next free name after it, and
    /// returns the name actually taken.
    ///
    /// `O_EXCL` is the whole point: the file is created only if creating it
    /// does not replace anything, decided inside one syscall with no window
    /// for a file to appear in. For writing a download in place — the caller
    /// opens a handle on the returned URL and streams into it.
    static func createFile(at url: URL) throws -> URL {
        try firstFree(for: url) { target in
            let fd = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return true
            }
            let code = errno
            if code == EEXIST { return false }
            throw posixError(code, at: target)
        }
    }

    /// Creates an empty folder at `url`, or at the next free name after it, and
    /// returns the name actually taken.
    ///
    /// For a payload that is many files, such as a multi-file torrent: the
    /// folder is claimed first and the writer fills it. `mkdir` is the same
    /// one-syscall check-and-take as `O_EXCL`, and refuses a name held by a
    /// file as readily as one held by a folder. Only the folder itself is
    /// created, never its parents: a vanished destination is the caller's to
    /// report, not something to rebuild.
    static func createDirectory(at url: URL) throws -> URL {
        try firstFree(for: url, isDirectory: true) { target in
            if mkdir(target.path, 0o755) == 0 { return true }
            let code = errno
            if code == EEXIST { return false }
            throw posixError(code, at: target)
        }
    }

    /// Moves `source` to `url`, or to the next free name after it, and returns
    /// the name actually taken.
    ///
    /// `FileManager.moveItem` refuses rather than replaces when something is
    /// already there (`NSFileWriteFileExistsError`), which is exactly the
    /// behaviour wanted and exactly what every call site used to defeat by
    /// deleting first. Any other failure — no permission, no space, a vanished
    /// source — is a real error and is thrown, not retried under a new name.
    static func move(_ source: URL, to url: URL) throws -> URL {
        try firstFree(for: url) { target in
            do {
                try FileManager.default.moveItem(at: source, to: target)
                return true
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                   && error.code == NSFileWriteFileExistsError {
                return false
            }
        }
    }
}
