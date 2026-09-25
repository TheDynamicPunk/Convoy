import Foundation

/// Telling a web page from a file, and following a page that forwards to its
/// file: "Thanks, your download will start" pages send the browser on with a
/// Refresh header or a meta refresh, and a download of the page's own link
/// would otherwise save the page under the file's name.
enum WebPageReply {
    /// How much of a page is read for a meta refresh, or to confirm it's HTML.
    static let inspectedLength = 64 * 1024
    /// Pages followed in a row before giving up, against a page that
    /// forwards to itself or to another page.
    static let maxForwards = 5

    /// HTML the server didn't offer as an attachment: a page to show, not a
    /// file to save.
    static func isPage(_ response: HTTPURLResponse) -> Bool {
        let type = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "text/html" else { return false }
        let disposition = response.value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return !disposition.hasPrefix("attachment")
    }

    /// A name someone saves a page under when the page is what they want.
    static func isPageName(_ name: String) -> Bool {
        ["html", "htm", "xhtml", "shtml"].contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether `data` begins as an HTML document does: the WHATWG MIME
    /// sniffing patterns, plus `<meta` and `<link`. A file served as
    /// text/html (PHP's default type) doesn't.
    static func looksLikeHTML(_ data: Data) -> Bool {
        var bytes = data.prefix(512)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        bytes = bytes.drop { [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains($0) }
        let head = bytes.prefix(16).map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }
        let tags = ["<!doctype html", "<html", "<head", "<script", "<iframe", "<h1", "<div", "<font",
                    "<table", "<a", "<style", "<title", "<b", "<body", "<br", "<p", "<!--", "<meta", "<link"]
        return tags.contains { tag in
            let pattern = Array(tag.utf8)
            guard head.starts(with: pattern), head.count > pattern.count else { return false }
            return [0x09, 0x0A, 0x0C, 0x0D, 0x20, 0x3E].contains(head[pattern.count])
        }
    }

    /// The URL in a Refresh value such as `5; url=https://…`, parsed as the
    /// HTML spec's declarative refresh is, resolved against `page`. Nil for a
    /// refresh of the page itself or a target that isn't http(s).
    static func refreshTarget(_ value: String, page: URL) -> URL? {
        var rest = Substring(value).drop(while: \.isWhitespace)
        let time = rest.prefix { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard !time.isEmpty else { return nil }
        rest = rest.dropFirst(time.count)
        guard let separator = rest.first, separator == ";" || separator == "," || separator.isWhitespace else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        if rest.first == ";" || rest.first == "," { rest = rest.dropFirst().drop(while: \.isWhitespace) }
        if rest.prefix(3).lowercased() == "url" {
            let afterName = rest.dropFirst(3).drop(while: \.isWhitespace)
            if afterName.first == "=" { rest = afterName.dropFirst().drop(while: \.isWhitespace) }
        }
        if let quote = rest.first, quote == "\"" || quote == "'" {
            rest = rest.dropFirst().prefix { $0 != quote }
        }
        let target = rest.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty,
              let url = URL(string: target, relativeTo: page)?.absoluteURL,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// The content of the first `<meta http-equiv="refresh">` in `body`.
    static func metaRefresh(in body: Data) -> String? {
        let html = String(decoding: body.prefix(inspectedLength), as: UTF8.self)
        let attribute = #/([^\s=/>]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/#
        for tag in html.matches(of: #/<meta\b[^>]*>/#.ignoresCase()) {
            var isRefresh = false
            var content: Substring?
            for match in tag.output.matches(of: attribute) {
                let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
                switch match.output.1.lowercased() {
                case "http-equiv": isRefresh = value.trimmingCharacters(in: .whitespaces).lowercased() == "refresh"
                case "content": content = value
                default: break
                }
            }
            if isRefresh, let content { return decodingEntities(String(content)) }
        }
        return nil
    }

    /// Attribute values carry `&amp;` and friends; a query string in one
    /// nearly always does.
    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text.replacing(#/&#([xX]?)([0-9a-fA-F]+);?/#) { match in
            let code = UInt32(match.output.2, radix: match.output.1.isEmpty ? 10 : 16)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? String(match.output.0)
        }
        for (entity, character) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return result
    }
}
