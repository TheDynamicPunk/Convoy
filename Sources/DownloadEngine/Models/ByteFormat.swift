import Foundation

/// The one place byte counts become text.
///
/// Decimal, the way Finder counts (1 KB is 1000 bytes), so the size Convoy shows
/// for a download is the size Finder shows for the finished file. Every screen
/// that shows a size or a speed goes through here. Before this, the app had a
/// dozen private copies in two conventions, so the capture dialog could call a
/// file "1.07 GB" while its row called the same bytes "1.0 GB". A new size or
/// speed on screen means calling this, not writing another formatter.
public enum ByteFormat {
    public enum Digits: Sendable {
        /// Finder's form: "304 MB", "1.07 GB". Trailing zeros are dropped, so
        /// the length varies with the value.
        case natural
        /// One decimal, always: "304.0 MB", "512.0 B". The length stays
        /// constant, for figures redrawn live.
        case fixed
    }

    /// "1.07 GB", "512 bytes", "0 bytes".
    ///
    /// Zero reads as a figure, never the words "Zero KB", which the system
    /// otherwise uses (and which also ignores `units`). A value that changes
    /// should read as a number at every value, including nothing.
    ///
    /// `units` limits which units may be chosen; the storage figures in
    /// Settings and the sidebar only ever want GB or MB. `digits` picks the
    /// form. `locale` exists so tests do not depend on the machine's.
    public static func size(
        _ bytes: Int64,
        in units: ByteCountFormatStyle.Units = .all,
        digits: Digits = .natural,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        switch digits {
        case .natural: return naturalSize(bytes, in: units, locale: locale)
        case .fixed: return fixedSize(bytes, in: units, locale: locale)
        }
    }

    /// "1.5 MB/s".
    public static func speed(
        _ bytesPerSecond: Int64,
        digits: Digits = .natural,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        size(bytesPerSecond, digits: digits, locale: locale) + "/s"
    }

    private static func naturalSize(_ bytes: Int64, in units: ByteCountFormatStyle.Units, locale: Locale) -> String {
        ByteCountFormatStyle(
            style: .file,
            allowedUnits: units,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        ).format(bytes)
    }

    private static let fixedLadder: [(unit: ByteCountFormatStyle.Units, symbol: String, scale: Double)] = [
        (.bytes, "B", 1),
        (.kb, "KB", 1e3),
        (.mb, "MB", 1e6),
        (.gb, "GB", 1e9),
        (.tb, "TB", 1e12),
    ]

    /// The smallest allowed unit whose rounded figure is under 1000, so
    /// 999,950 bytes reads "1.0 MB", not "1000.0 KB".
    private static func fixedSize(_ bytes: Int64, in units: ByteCountFormatStyle.Units, locale: Locale) -> String {
        let allowed = fixedLadder.filter { units.contains($0.unit) }
        guard let largest = allowed.last else { return naturalSize(bytes, in: units, locale: locale) }
        let value = Double(max(bytes, 0))
        let step = allowed.first { (value / $0.scale * 10).rounded() / 10 < 1_000 } ?? largest
        return String(format: "%.1f", locale: locale, value / step.scale) + " " + step.symbol
    }
}
