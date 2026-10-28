import Foundation

/// Powers the "Try it" field in Settings: paste a filename or a link and see
/// which category would take it.
///
/// It answers by running the real routing decision (`CategoryRouting.route`)
/// rather than a lookalike, so the field cannot promise something real
/// downloads would not do: a category whose folder is empty or relative
/// takes nothing here exactly as it takes nothing there.
public enum CategoryPreview {

    /// The category that would take `input`, with the folder the file would
    /// land in, or nil when none would (or the field is empty).
    public static func route(
        for input: String,
        in categories: [DownloadCategory]
    ) -> CategoryRoute? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (filename, hosts) = parse(trimmed)
        if let hit = decide(filename: filename, hosts: hosts, in: categories) {
            return hit
        }
        // A bare hostname ("example.com") has no scheme or slash, so it looks
        // like a filename above. Offer it as a host too, so a site-only
        // category can be tried without typing "https://".
        if hosts.isEmpty, !trimmed.contains("/"),
           let host = DownloadCategory.normalizedSitePattern(trimmed),
           host.contains(".") {
            return decide(filename: "", hosts: [host], in: categories)
        }
        return nil
    }

    private static func decide(
        filename: String,
        hosts: [String],
        in categories: [DownloadCategory]
    ) -> CategoryRoute? {
        CategoryRouting.route(
            filename: filename,
            hosts: hosts,
            categories: categories,
            folderIsExplicit: false,
            alreadyRouted: false
        )
    }

    /// Splits what was typed into the file's name and the hosts it came from.
    /// Accepts a full link, a link without "https://", a path, or a bare name.
    static func parse(_ trimmed: String) -> (filename: String, hosts: [String]) {
        if trimmed.contains("://"), let url = URL(string: trimmed), url.host != nil {
            return (name(of: url), CategoryRouter.hosts(from: [url]))
        }
        if !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~"),
           let slash = trimmed.firstIndex(of: "/"),
           trimmed[..<slash].contains("."),
           !trimmed[..<slash].contains(" "),
           let url = URL(string: "https://" + trimmed), url.host != nil {
            return (name(of: url), CategoryRouter.hosts(from: [url]))
        }
        return ((trimmed as NSString).lastPathComponent, [])
    }

    private static func name(of url: URL) -> String {
        let last = url.path == "/" ? "" : url.lastPathComponent
        return last.removingPercentEncoding ?? last
    }
}
