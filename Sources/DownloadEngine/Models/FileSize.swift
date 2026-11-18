import Foundation

/// A file's length in bytes, or nil if it can't be read. The caller picks the
/// fallback, since existing call sites disagree on it (0, nil, or the last
/// known value). This is the logical size; `TemporaryStorage` measures
/// allocated size, which answers a different question.
enum FileSize {
    static func bytes(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }
}
