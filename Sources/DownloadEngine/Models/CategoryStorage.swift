import Foundation

/// How the category list is stored and read back. Pure functions over the
/// stored string so the three cases that matter can be tested without
/// touching anyone's real settings.
public enum CategoryStorage {

    /// - Nothing stored yet (an empty string): the original categories. A
    ///   fresh install shows them and, once routing is switched on, uses
    ///   them, without anyone having to press a button first.
    /// - A stored list, even an empty one (`[]`): exactly that list. Deleting
    ///   every category is a choice and must not quietly bring them back.
    /// - Stored text that cannot be read: no categories, never a guess.
    public static func load(json: String, downloadsFolder: String) -> [DownloadCategory] {
        guard !json.isEmpty else {
            return DownloadCategory.suggestedCategories(in: downloadsFolder)
        }
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([DownloadCategory].self, from: data)
        else { return [] }
        return list
    }

    /// Nil only if encoding fails, in which case the caller should keep what
    /// is already stored. An empty string must never be written here: it
    /// reads back as "never edited", which would restore the defaults over
    /// the person's list.
    public static func encode(_ categories: [DownloadCategory]) -> String? {
        guard let data = try? JSONEncoder().encode(categories) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
