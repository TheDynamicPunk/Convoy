import Foundation

/// A download request that arrived from the browser — the extension's button,
/// the context menu, an intercepted native download, or a captured HLS/DASH
/// stream — and has not become a task yet.
///
/// Exists so that "what did the browser ask for" is one value that can wait
/// for a person's answer (the capture review window) and then be added by the
/// same code whether or not anyone was asked. Before this, IPCServer built the
/// add calls inline, so there was no way to hold a request.
public struct CapturedDownload: Identifiable {
    public let id = UUID()
    /// The URL to fetch (already adjusted for CDN throttling by the caller).
    public let url: URL
    /// Headers for the real outgoing request. Never contains Content-Length.
    public let headers: [String: String]
    /// The headers exactly as the extension sent them, Content-Length
    /// included. Only for `DownloadManager.matchFreshURL`, which uses that
    /// size to decide whether a capture is a re-link of an expired download.
    public let matchHeaders: [String: String]
    public let referrerURL: URL?
    /// The name the capture arrived with: the browser's suggested name, a
    /// page title, or for a stream the one derived from its manifest. Nil when
    /// nothing is known yet and the engine will resolve one from the response.
    public let suggestedFilename: String?
    /// Where `suggestedFilename` came from. Nil exactly when it is nil.
    public let filenameSource: FilenameSource?
    /// The file's size in bytes if the browser measured it.
    public let expectedSize: Int64?
    public let segmentCount: Int?
    /// Non-nil for an HLS/DASH capture, which goes through the stream engine.
    public let stream: DuplicateDownloadConflict.StreamInfo?

    public init(
        url: URL,
        headers: [String: String],
        matchHeaders: [String: String],
        referrerURL: URL?,
        suggestedFilename: String?,
        filenameSource: FilenameSource?,
        expectedSize: Int64?,
        segmentCount: Int?,
        stream: DuplicateDownloadConflict.StreamInfo?
    ) {
        self.url = url
        self.headers = headers
        self.matchHeaders = matchHeaders
        self.referrerURL = referrerURL
        self.suggestedFilename = suggestedFilename
        self.filenameSource = filenameSource
        self.expectedSize = expectedSize
        self.segmentCount = segmentCount
        self.stream = stream
    }

    /// A name to show for it before the engine has resolved a real one.
    public var displayName: String {
        if let suggestedFilename, !suggestedFilename.isEmpty { return suggestedFilename }
        let leaf = url.lastPathComponent
        if !leaf.isEmpty, leaf != "/" { return leaf }
        return url.host ?? String(url.absoluteString.prefix(80))
    }
}

/// What a person decided in the capture review window. Every field is
/// optional: nil means "leave it as the capture arrived".
public struct CaptureChoices {
    /// A name the person typed. Nil if they left the suggested one alone —
    /// which matters, because a typed name is final (`.userProvided`) while an
    /// untouched one may still be improved by Content-Disposition later.
    public var filename: String?
    /// A folder the person picked. Nil means automatic: the default folder,
    /// or whichever download category claims the file.
    public var folder: URL?
    /// Start now (true) or add without starting (false). Nil leaves it to the
    /// "Start downloads automatically" setting.
    public var startsAutomatically: Bool?

    public init(filename: String? = nil, folder: URL? = nil, startsAutomatically: Bool? = nil) {
        self.filename = filename
        self.folder = folder
        self.startsAutomatically = startsAutomatically
    }
}

extension DownloadManager {
    /// Adds a captured download, applying whatever the person chose for it.
    ///
    /// With default `choices` this does exactly what IPCServer used to do
    /// inline for a capture, so the review window being switched off changes
    /// nothing. Re-link matching (`matchFreshURL`) is NOT done here: the
    /// caller does it first, because a capture that re-links an expired row
    /// is not a new download and must not be shown to anyone as one.
    ///
    /// A `DownloadConflictError` (the request went to the duplicate sheet) is
    /// swallowed: that is a normal outcome, resolved through the sheet.
    public func addCaptured(_ capture: CapturedDownload, choices: CaptureChoices = CaptureChoices()) async {
        let baseFolder = choices.folder
            ?? URL(fileURLWithPath: AppSettings.shared.downloadDirectory, isDirectory: true)
        let folderIsExplicit = choices.folder != nil

        // Work out the destination and, with it, how much the name is trusted.
        // A destination file URL is what marks a name as given rather than
        // guessed, so the cases below are deliberate:
        //  - typed by the person: final.
        //  - arrived with the capture: as the capture said (mediaTitle etc.).
        //  - nothing known but a folder was picked: a placeholder from the URL
        //    that Content-Disposition may still replace (.originalURL).
        //  - nothing known, no folder: no destination at all, as before.
        let destination: URL?
        let source: FilenameSource?
        if let typed = choices.filename.flatMap({ FilenameResolver.sanitize($0) }) {
            destination = baseFolder.appendingPathComponent(typed)
            source = .userProvided
        } else if let suggested = capture.suggestedFilename, !suggested.isEmpty {
            destination = baseFolder.appendingPathComponent(suggested)
            source = capture.filenameSource ?? .mediaTitle
        } else if folderIsExplicit {
            destination = baseFolder.appendingPathComponent(FilenameResolver.provisionalFilename(for: capture.url))
            source = .originalURL
        } else {
            destination = nil
            source = nil
        }

        if let stream = capture.stream {
            _ = try? await addStreamDownload(
                url: capture.url,
                streamType: stream.streamType,
                destination: destination,
                filenameSource: source,
                customHeaders: capture.headers,
                referrerURL: capture.referrerURL,
                representationId: stream.representationId,
                bandwidth: stream.bandwidth,
                hlsAudioTracks: stream.hlsAudioTracks,
                folderIsExplicit: folderIsExplicit,
                startAutomatically: choices.startsAutomatically
            )
        } else {
            _ = try? await addDownload(
                url: capture.url,
                destination: destination,
                filenameSource: source,
                segmentCount: capture.segmentCount,
                customHeaders: capture.headers,
                referrerURL: capture.referrerURL,
                folderIsExplicit: folderIsExplicit,
                expectedSize: capture.expectedSize,
                startAutomatically: choices.startsAutomatically
            )
        }
    }
}
