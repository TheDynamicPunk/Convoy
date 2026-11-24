import Foundation

extension URL {
    /// True only for `http` and `https` URLs that have a non-empty host.
    var isHTTPOrHTTPS: Bool {
        guard let scheme = scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host, !host.isEmpty else {
            return false
        }
        return true
    }

    /// Trims surrounding whitespace, resolves `raw` against `base` per RFC 3986,
    /// and accepts only `http` or `https` URLs with a non-empty host.
    static func resolveHTTP(_ raw: String, relativeTo base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              url.isHTTPOrHTTPS else {
            return nil
        }
        return url
    }
}

/// Central policy for stripping credentials and site-specific custom headers
/// whenever a request crosses to a different origin (scheme, host, or port),
/// or when persisting stream request headers to disk.
enum CrossHostHeaderPolicy {
    /// Non-authenticating browser/content headers safe to carry across origins
    /// or persist in `downloads.json`. Single source of truth for both paths.
    static let nonAuthenticatingHeaderNames: Set<String> = [
        "user-agent",
        "referer",
        "origin",
        "accept",
        "accept-language",
        "sec-fetch-mode",
        "sec-fetch-site",
        "sec-fetch-dest",
    ]

    /// Additional transport headers preserved across HTTP redirects.
    private static let redirectExtraAllowedHeaders: Set<String> = [
        "range",
        "if-range",
        "accept-encoding",
    ]

    /// True when both URLs share the same scheme, host, and effective port.
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              lhsScheme == rhsScheme,
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              lhsHost == rhsHost else {
            return false
        }
        return effectivePort(for: lhs, scheme: lhsScheme) == effectivePort(for: rhs, scheme: rhsScheme)
    }

    /// True when transitioning from HTTPS to cleartext HTTP (RFC 9110 §10.1.3).
    static func isHTTPSDowngrade(from source: URL, to target: URL) -> Bool {
        source.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http"
    }

    /// Returns only the non-authenticating allowlisted headers from `headers`.
    static func nonAuthenticating(_ headers: [String: String]) -> [String: String] {
        headers.filter { nonAuthenticatingHeaderNames.contains($0.key.lowercased()) }
    }

    /// Returns `headers` unchanged for same-origin targets, or filtered to
    /// `nonAuthenticatingHeaderNames` when `targetURL` is on a different origin.
    /// Also strips `Referer` on an HTTPS → HTTP downgrade.
    static func headers(
        _ headers: [String: String],
        from originURL: URL,
        to targetURL: URL
    ) -> [String: String] {
        guard !isSameOrigin(originURL, targetURL) else { return headers }
        let downgrade = isHTTPSDowngrade(from: originURL, to: targetURL)
        return headers.filter { key, _ in
            let lower = key.lowercased()
            if downgrade && lower == "referer" { return false }
            return nonAuthenticatingHeaderNames.contains(lower)
        }
    }

    /// Sanitizes a redirect's proposed `URLRequest`:
    /// - Rejects redirects to non-HTTP(S) schemes or hostless URLs.
    /// - Preserves all headers on same-origin redirects.
    /// - Strips credentials (`Cookie`, `Authorization`, etc.) and any custom
    ///   non-allowlisted headers when the redirect crosses origins.
    /// - Strips `Referer` on an HTTPS → HTTP downgrade.
    static func sanitizedRedirectRequest(
        from response: HTTPURLResponse,
        to proposed: URLRequest
    ) -> URLRequest? {
        guard let targetURL = proposed.url, targetURL.isHTTPOrHTTPS else {
            return nil
        }

        if let sourceURL = response.url, isSameOrigin(sourceURL, targetURL) {
            return proposed
        }

        let downgrade = response.url.map { isHTTPSDowngrade(from: $0, to: targetURL) } ?? false
        var sanitized = proposed
        if let existing = proposed.allHTTPHeaderFields {
            let allowed = nonAuthenticatingHeaderNames.union(redirectExtraAllowedHeaders)
            for key in existing.keys {
                let lower = key.lowercased()
                if (downgrade && lower == "referer") || !allowed.contains(lower) {
                    sanitized.setValue(nil, forHTTPHeaderField: key)
                }
            }
        }
        return sanitized
    }

    private static func effectivePort(for url: URL, scheme: String) -> Int? {
        if let port = url.port { return port }
        switch scheme {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

/// Base `URLSessionTaskDelegate` that enforces `CrossHostHeaderPolicy` on
/// every HTTP redirect. Subclass instead of duplicating `willPerformHTTPRedirection`.
class CrossHostURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let redirectOnly = CrossHostURLSessionDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(CrossHostHeaderPolicy.sanitizedRedirectRequest(from: response, to: request))
    }
}
