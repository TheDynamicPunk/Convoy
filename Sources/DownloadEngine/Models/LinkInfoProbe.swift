import Foundation

/// What a server says about a link, gathered for the capture review window
/// before the download exists. Every field is best-effort: a server that
/// refuses, times out or answers oddly just leaves them empty, and the window
/// shows "Unknown" rather than an error.
public struct LinkInfo: Equatable {
    /// The file's whole size in bytes, when the server states it.
    public var size: Int64?
    /// A name from Content-Disposition, or from the final URL when that has an
    /// extension. Nil when neither says anything usable.
    public var suggestedFilename: String?
    public var mimeType: String?
    /// The link opens a web page rather than a file.
    public var isWebPage: Bool

    public init(
        size: Int64? = nil,
        suggestedFilename: String? = nil,
        mimeType: String? = nil,
        isWebPage: Bool = false
    ) {
        self.size = size
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.isWebPage = isWebPage
    }
}

public enum LinkInfoProbe {
    /// Asks the server about `url` with a one-byte ranged GET and stops as
    /// soon as the headers arrive, so no part of the file is downloaded.
    ///
    /// A ranged GET rather than HEAD: plenty of servers and CDNs answer HEAD
    /// differently or not at all, and the engine's own probe already relies on
    /// the ranged form (see ProbeConnection). The captured headers (cookies,
    /// Referer, User-Agent) ride along, since a link that needs them would
    /// otherwise answer with a login page.
    ///
    /// Cancelling the calling task cancels the request.
    public static func fetch(url: URL, headers: [String: String], timeout: TimeInterval = 8) async -> LinkInfo? {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers where name.caseInsensitiveCompare("Range") != .orderedSame {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        ContentCoding.requestUncompressed(&request)

        do {
            let (bytes, response) = try await URLSession.cookieless.bytes(for: request)
            // Headers are all that was wanted. A server that ignored the
            // Range header is already sending the whole file; stop it.
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return nil }
            return interpret(http)
        } catch {
            return nil
        }
    }

    /// Reads a response's headers into a `LinkInfo`. Separate from `fetch` so
    /// it can be tested without a network.
    static func interpret(_ http: HTTPURLResponse) -> LinkInfo {
        let compressed = ContentCoding.isEncoded(http)

        // A compressed reply counts compressed bytes, not the file's.
        var size: Int64?
        if !compressed {
            if http.statusCode == 206,
               let range = http.value(forHTTPHeaderField: "Content-Range"),
               let slash = range.lastIndex(of: "/"),
               let total = Int64(range[range.index(after: slash)...].trimmingCharacters(in: .whitespaces)),
               total > 0 {
                size = total
            } else if http.statusCode == 200,
                      let length = http.value(forHTTPHeaderField: "Content-Length").flatMap({ Int64($0) }),
                      length > 0 {
                size = length
            }
        }

        var name = http.value(forHTTPHeaderField: "Content-Disposition")
            .flatMap { FilenameResolver.filename(fromContentDisposition: $0) }
        if name == nil, let resolved = http.url,
           let candidate = FilenameResolver.sanitize(resolved.lastPathComponent),
           !(candidate as NSString).pathExtension.isEmpty {
            name = candidate
        }

        let mime = http.value(forHTTPHeaderField: "Content-Type")
            .flatMap { $0.split(separator: ";").first }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        return LinkInfo(
            size: size,
            suggestedFilename: name,
            mimeType: mime,
            isWebPage: WebPageReply.isPage(http)
        )
    }
}
