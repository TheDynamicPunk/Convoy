import Foundation

/// Download categories, as far as the manager is concerned: which categories
/// are in force, and routing for the add paths that already know the whole
/// destination when the task is created (YouTube and streams). Byte-range
/// downloads cannot know their real name until the probe's headers arrive, so
/// they are routed later, by `DownloadTask.applyCategoryIfNeeded`.
extension DownloadManager {

    /// The categories that apply right now: none unless the person turned
    /// the feature on. Read live, so a change in Settings applies to the next
    /// download without relaunching, and never to one already under way.
    var activeCategories: [DownloadCategory] {
        let settings = AppSettings.shared
        return settings.downloadCategoriesEnabled ? settings.downloadCategories : []
    }

    /// True when sorting is really in effect: switched on, with at least one
    /// category that could take a file. What the New Download window checks
    /// before offering "Automatic", so it only appears when it means something.
    public var sortingIsActive: Bool {
        CategoryRouting.hasAnyRoutableCategory(activeCategories)
    }

    /// The routing decision for a download whose name is known, with nothing
    /// prepared and nothing changed. The ONE place that turns "the categories
    /// in force" into a decision: the add paths call it to route, and the New
    /// Download window calls it to preview, so the two cannot drift apart.
    public func categoryRoute(
        filename: String,
        matchName: String? = nil,
        hosts: [String],
        folderIsExplicit: Bool
    ) -> CategoryRoute? {
        CategoryRouting.route(
            filename: filename,
            matchName: matchName,
            hosts: hosts,
            categories: activeCategories,
            folderIsExplicit: folderIsExplicit,
            alreadyRouted: false
        )
    }

    struct AddTimeRoute {
        /// Where the task should be created: the category's folder plus the
        /// name, or `destination` unchanged when nothing applied.
        var destination: URL
        var categoryID: UUID?
        /// Set when a category matched but its folder could not be used.
        var notice: String?
    }

    /// Routes a destination that is already complete, before the task exists.
    ///
    /// Deliberately called BEFORE the duplicate check in the add methods, and
    /// everything after it is synchronous. The folder preparation is the one
    /// suspension point (it runs off the main actor, see CategoryFolder), and
    /// putting it between the duplicate check and the append would let two
    /// near-simultaneous captures of the same link both pass the check.
    /// Duplicate detection compares names and URLs, never folders, so
    /// routing first does not change what counts as a duplicate.
    func routeAtAddTime(
        destination: URL,
        matchName: String? = nil,
        hosts: [String],
        folderIsExplicit: Bool
    ) async -> AddTimeRoute {
        guard let route = categoryRoute(
            filename: destination.lastPathComponent,
            matchName: matchName,
            hosts: hosts,
            folderIsExplicit: folderIsExplicit
        ) else {
            return AddTimeRoute(destination: destination, categoryID: nil, notice: nil)
        }

        let folder = route.category.folder
        let outcome = await Task.detached(priority: .userInitiated) {
            CategoryFolder.prepare(folder)
        }.value

        switch outcome {
        case .ready, .created:
            return AddTimeRoute(destination: route.destination, categoryID: route.category.id, notice: nil)
        case .unavailable(let reason):
            return AddTimeRoute(
                destination: destination,
                categoryID: nil,
                notice: CategoryRouting.fallbackNotice(
                    category: route.category,
                    reason: reason,
                    savedTo: destination.deletingLastPathComponent()
                )
            )
        }
    }
}
