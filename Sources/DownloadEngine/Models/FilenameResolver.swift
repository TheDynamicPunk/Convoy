import Foundation

/// Where a download name came from. The source is retained with the task so a
/// later, more authoritative response can replace a provisional name without
/// ever overriding a name the person explicitly chose.
public enum FilenameSource: String, Codable, Sendable {
    case fallback
    case originalURL
    case resolvedURL
    case pageMetadata
    case extractorMetadata
    case contentDisposition
    case mediaTitle
    case userProvided

    fileprivate var priority: Int {
        switch self {
        case .fallback: 0
        case .originalURL: 10
        case .resolvedURL: 20
        case .pageMetadata: 30
        case .extractorMetadata: 40
        case .contentDisposition: 50
        // Above contentDisposition deliberately. A CDN answering
        //   Content-Disposition: inline; filename="k3variol8mqz71bn.mp4"
        // is authoritative about a file download and useless about a video:
        // the browser extension already resolved this video's real title from
        // the page it was embedded in, and a server header must not overwrite
        // it. Ordinary downloads never carry this source and still let
        // Content-Disposition win, which is right for them.
        case .mediaTitle: 60
        case .userProvided: 100
        }
    }
}

/// One policy for turning remote metadata into a safe local filename.
///
/// Generic HTTP downloads begin with a URL-derived provisional name and may
/// later adopt `Content-Disposition`; media downloads can instead begin with
/// page/extractor metadata. Every path uses the same sanitization and source
/// precedence rules.
public enum FilenameResolver {
    public static func provisionalFilename(for url: URL) -> String {
        if let name = sanitize(url.lastPathComponent) { return name }
        if let host = url.host, let safe = sanitize(host) { return safe }
        return "download"
    }

    public static func sanitize(_ raw: String, maxLength: Int = 180) -> String? {
        // A filename is a leaf, never a path. Drop any supplied directory
        // components before removing macOS-reserved characters.
        let leaf = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? raw
        let decoded = leaf.removingPercentEncoding ?? leaf
        let forbidden = CharacterSet(charactersIn: ":/\\?*<>|\"")
            .union(.controlCharacters)
        let replaced = decoded.components(separatedBy: forbidden).joined(separator: "-")
        let collapsed = replaced.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !collapsed.isEmpty, collapsed != ".", collapsed != ".." else { return nil }
        return String(collapsed.prefix(maxLength))
    }

    public static func shouldReplace(current: FilenameSource, with candidate: FilenameSource) -> Bool {
        candidate.priority > current.priority
    }

    /// Parses an RFC 6266 response header. `filename*` wins over `filename`
    /// and supports the UTF-8/ISO-8859-1 percent-encoded form used for Unicode
    /// names. Invalid headers simply yield nil; callers then keep their safe
    /// provisional name.
    public static func filename(fromContentDisposition header: String) -> String? {
        let parameters = splitParameters(header)
        var plain: String?
        var extended: String?
        for parameter in parameters {
            guard let equal = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<equal].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(parameter[parameter.index(after: equal)...])
            if key == "filename*", extended == nil {
                extended = decodeExtended(value)
            } else if key == "filename", plain == nil {
                plain = unquote(value)
            }
        }
        return sanitize(extended ?? plain ?? "")
    }

    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in header {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" && quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if character == ";" && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.dropFirst().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaping = false
        for character in value.dropFirst().dropLast() {
            if escaping { result.append(character); escaping = false }
            else if character == "\\" { escaping = true }
            else { result.append(character) }
        }
        return result
    }

    private static func decodeExtended(_ raw: String) -> String? {
        let value = unquote(raw)
        let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        let encoded = fields.count == 3 ? String(fields[2]) : value
        guard let data = percentDecodedData(encoded) else { return encoded.removingPercentEncoding ?? encoded }
        let charset = fields.first?.lowercased()
        if charset == "iso-8859-1" || charset == "latin1" {
            return String(data: data, encoding: .isoLatin1)
        }
        return String(data: data, encoding: .utf8) ?? encoded.removingPercentEncoding ?? encoded
    }

    private static func percentDecodedData(_ value: String) -> Data? {
        var bytes: [UInt8] = []
        let chars = Array(value.utf8)
        var index = 0
        while index < chars.count {
            if chars[index] == 37, index + 2 < chars.count,
               let high = hex(chars[index + 1]), let low = hex(chars[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(chars[index])
                index += 1
            }
        }
        return Data(bytes)
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
