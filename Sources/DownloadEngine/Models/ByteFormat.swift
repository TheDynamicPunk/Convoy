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
    /// "1.07 GB", "512 bytes", "0 bytes".
    ///
    /// Zero reads as a figure, never the words "Zero KB", which the system
    /// otherwise uses (and which also ignores `units`). A value that changes
    /// should read as a number at every value, including nothing.
    ///
    /// `units` limits which units may be chosen; the storage figures in
    /// Settings and the sidebar only ever want GB or MB. `locale` exists so
    /// tests do not depend on the machine's.
    public static func size(
        _ bytes: Int64,
        in units: ByteCountFormatStyle.Units = .all,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        ByteCountFormatStyle(
            style: .file,
            allowedUnits: units,
            spellsOutZero: false,
            includesActualByteCount: false,
            locale: locale
        ).format(bytes)
    }

    /// "1.5 MB/s".
    public static func speed(_ bytesPerSecond: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        size(bytesPerSecond, locale: locale) + "/s"
    }
}
