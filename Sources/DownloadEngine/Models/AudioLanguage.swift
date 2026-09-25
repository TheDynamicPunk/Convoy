import Foundation

/// The one rule for whether a track's language satisfies the Settings
/// preference, shared by DASH, HLS and YouTube so the choice means the same
/// thing on every download path.
public enum AudioLanguage {

    /// Loose on region in both directions: "en" accepts "en-GB", "en-GB"
    /// accepts "en", and "zh" accepts YouTube's "zh-Hans".
    ///
    /// Does not bridge ISO 639-1 to 639-2: a manifest declaring "eng" (the
    /// BBC does) will not match "en". An unmatched preference falls back to
    /// the track's default rather than failing.
    public static func matches(_ language: String?, preferred: String) -> Bool {
        guard let lang = language?.lowercased(), !preferred.isEmpty else { return false }
        let want = preferred.lowercased()
        return lang == want || lang.hasPrefix(want + "-") || want.hasPrefix(lang + "-")
    }
}
