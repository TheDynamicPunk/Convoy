import DownloadEngine

/// What Pause All, Resume All and Delete All Completed have to work with.
///
/// Defined once because two menus offer the same three commands -- the app's
/// File menu and the menu bar item -- and a menu that greys an item out on a
/// different rule than the one the action actually follows is worse than one
/// that never greys it at all.
extension DownloadManager {
    /// Mirrors `pauseAll()`, which stops queued tasks as well as transferring
    /// ones: a `.waiting` task left alone would start the moment a slot freed.
    var hasPausableTasks: Bool {
        tasks.contains { $0.status == .downloading || $0.status == .starting || $0.status == .waiting }
    }

    var hasResumableTasks: Bool {
        tasks.contains { $0.status == .paused }
    }

    /// `.deleteAllCompleted` deletes exactly this list.
    var hasCompletedTasks: Bool {
        !completedTasks.isEmpty
    }
}
