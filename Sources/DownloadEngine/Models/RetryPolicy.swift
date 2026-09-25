import Foundation

/// Whether a failed request is worth making again, and how long to wait.
///
/// One policy for every request that fetches a file's bytes — the probe, the
/// parts of a ranged download, a whole-file download, stream segments and
/// their playlists — so a site behaves the same whichever path serves it. It
/// retries what is momentary: a connection that dropped or timed out, a
/// network that went away, a server that said it was busy. What asking again
/// would only repeat — a missing file, a refused request, a bad certificate,
/// a full disk — fails at once.
enum RetryPolicy {
    /// Failures in a row, with nothing gained between them, before giving up.
    /// With `delay`, about three and a half minutes of trying.
    static let maxConsecutiveFailures = 10

    /// 1, 2, 4, 8, 16, then 30 seconds; or what the server asked for with
    /// Retry-After, up to a minute. Up to a fifth longer at random, so parts
    /// that failed together don't all come back in the same instant.
    static func delay(beforeRetry attempt: Int, serverAsked: TimeInterval? = nil) -> TimeInterval {
        if let serverAsked { return min(max(serverAsked, 1), 60) }
        let base = min(pow(2, Double(max(attempt, 1) - 1)), 30)
        return base * Double.random(in: 1...1.2)
    }

    /// True for a failure of the moment.
    ///
    /// `serverReached` is false for a download's first request: a host that
    /// DNS can't find then is most likely a mistyped or dead address, not a
    /// network in the middle of changing.
    static func isTransient(_ error: Error, serverReached: Bool = true) -> Bool {
        if let error = error as? DownloadError {
            if case .httpError(let status) = error { return isTransient(status: status) }
            return false
        }
        let error = error as NSError
        switch error.domain {
        case NSURLErrorDomain:
            if dnsFailures.contains(error.code) { return serverReached }
            return transientURLErrors.contains(error.code)
        case NSPOSIXErrorDomain:
            return transientPOSIXErrors.contains(Int32(error.code))
        default:
            return false
        }
    }

    /// 408 Request Timeout, 429 Too Many Requests, and the 5xx replies of an
    /// overloaded server or the proxy in front of it.
    static func isTransient(status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
    }

    private static let transientURLErrors: Set<Int> = [
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
    ]

    private static let dnsFailures: Set<Int> = [
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
    ]

    private static let transientPOSIXErrors: Set<Int32> = [
        ENETDOWN, ENETUNREACH, ENETRESET, ECONNABORTED, ECONNRESET,
        ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH,
    ]

    /// Retry-After as seconds from now: either a number of seconds or an
    /// HTTP date. Nil when absent or unreadable.
    static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(date.timeIntervalSince(now), 0)
    }

    /// Sleeps `seconds`, checking `stillWanted` four times a second so a
    /// pause ends the wait at once rather than when it runs out. Throws
    /// `DownloadError.cancelled` once the retry is no longer wanted.
    static func wait(
        _ seconds: TimeInterval,
        isolation: isolated (any Actor)? = #isolation,
        while stillWanted: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            guard stillWanted() else { throw DownloadError.cancelled }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(min(left, 0.25) * 1_000_000_000))
            } catch {
                throw DownloadError.cancelled
            }
        }
    }
}

/// Every request for a file's bytes asks for them uncompressed.
///
/// A server may otherwise send a compressed version of the file, and a byte
/// range of that is a slice of the compressed stream: it can't be decoded on
/// its own, and its offsets aren't the file's. Such a server also tends to
/// give each version its own ETag, so validators only mean something when
/// every request asks for the same one.
enum ContentCoding {
    static let identity = "identity"

    /// Call after copying any captured headers, so a browser's own
    /// Accept-Encoding can't override it.
    static func requestUncompressed(_ request: inout URLRequest) {
        request.setValue(identity, forHTTPHeaderField: "Accept-Encoding")
    }

    /// True when the server compressed the reply anyway.
    static func isEncoded(_ response: HTTPURLResponse) -> Bool {
        guard let coding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased(), !coding.isEmpty else { return false }
        return coding != identity
    }
}
