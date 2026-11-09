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
        /// Three significant digits, trailing zeros dropped: "1.05 MB",
        /// "12.3 MB", "304 MB". The length varies with the value.
        case natural
        /// One decimal, always: "304.0 MB", "512.0 B". The length stays
        /// constant, for figures redrawn live.
        case fixed
    }

    /// "1.07 GB", "512 bytes", "0 bytes".
    ///
    /// Zero reads as a figure, never the words "Zero KB". A value that changes
    /// should read as a number at every value, including nothing.
    ///
    /// Both forms are worked out here, from one ladder of units, not by the
    /// system's formatter, so the text is ours and the same on every macOS
    /// Convoy runs on. (When this was checked, the system's formatter printed
    /// "kB" and rounded 1.05 MB to "1 MB".)
    ///
    /// `units` limits which units may be chosen; the storage figures in
    /// Settings and the sidebar only ever want GB or MB. A set that names none
    /// of the ladder's units (bytes to TB) is treated as all of them. `digits`
    /// picks the form. `locale` exists so tests do not depend on the machine's.
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

    /// The units, smallest first, each with its symbol and its size in bytes.
    private static let ladder: [(unit: ByteCountFormatStyle.Units, symbol: String, scale: Double)] = [
        (.bytes, "B", 1),
        (.kb, "KB", 1e3),
        (.mb, "MB", 1e6),
        (.gb, "GB", 1e9),
        (.tb, "TB", 1e12),
    ]

    /// The smallest allowed unit whose figure, once `rounder` has rounded it,
    /// is under 1000, so 999,950 bytes reads "1.0 MB", not "1000.0 KB". The
    /// largest allowed unit takes whatever is left.
    private static func pick(
        _ bytes: Int64,
        in units: ByteCountFormatStyle.Units,
        rounder: (Double) -> Double
    ) -> (unit: ByteCountFormatStyle.Units, symbol: String, figure: Double) {
        let named = ladder.filter { units.contains($0.unit) }
        let allowed = named.isEmpty ? ladder : named
        let value = Double(max(bytes, 0))
        let step = allowed.first { rounder(value / $0.scale) < 1_000 } ?? allowed[allowed.count - 1]
        return (step.unit, step.symbol, value / step.scale)
    }

    /// Three significant digits: two decimals under 10, one under 100, none
    /// from 100 up.
    private static func threeDigits(_ figure: Double) -> Double {
        let scale: Double = figure < 10 ? 100 : figure < 100 ? 10 : 1
        return (figure * scale).rounded() / scale
    }

    private static func naturalSize(_ bytes: Int64, in units: ByteCountFormatStyle.Units, locale: Locale) -> String {
        let step = pick(bytes, in: units, rounder: threeDigits)
        let figure = threeDigits(step.figure)
        let number = figure.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
        let label = step.unit == .bytes ? (figure == 1 ? "byte" : "bytes") : step.symbol
        return number + " " + label
    }

    private static func fixedSize(_ bytes: Int64, in units: ByteCountFormatStyle.Units, locale: Locale) -> String {
        let step = pick(bytes, in: units) { ($0 * 10).rounded() / 10 }
        return String(format: "%.1f", locale: locale, step.figure) + " " + step.symbol
    }
}
