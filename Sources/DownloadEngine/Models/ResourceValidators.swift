import Foundation

/// The `ETag`/`Last-Modified` pair naming the version of a file a download
/// started from. Used by the resume HEAD check and by every part response.
struct ResourceValidators: Sendable, Equatable {
    let etag: String?
    let lastModified: String?

    var isEmpty: Bool { etag == nil && lastModified == nil }

    init(etag: String?, lastModified: String?) {
        self.etag = etag
        self.lastModified = lastModified
    }

    init(_ response: HTTPURLResponse) {
        self.init(etag: response.value(forHTTPHeaderField: "ETag"),
                  lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
    }

    /// The `If-Range` value, or nil. A strong ETag, else Last-Modified — but
    /// no date when a weak ETag exists: RFC 9110 forbids it, and a date that
    /// changes per response would make every range come back as the whole
    /// file.
    var ifRange: String? {
        if let etag, !etag.isEmpty {
            return etag.hasPrefix("W/") ? nil : etag
        }
        return lastModified
    }

    /// True when `response` names a different version. The ETag decides when
    /// both sides have one; Last-Modified is often just when the response
    /// was generated. A validator missing on either side proves nothing.
    func differ(from response: HTTPURLResponse) -> Bool {
        let current = ResourceValidators(response)
        if let etag, let currentETag = current.etag { return etag != currentETag }
        if let lastModified, let currentLastModified = current.lastModified {
            return lastModified != currentLastModified
        }
        return false
    }
}
