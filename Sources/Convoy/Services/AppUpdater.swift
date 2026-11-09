import Combine
import Sparkle
import DownloadEngine

/// The app's one Sparkle updater. The app menu, the menu bar item and
/// Settings all act on this instance.
///
/// Updates are accepted on the EdDSA signature alone: the app is ad-hoc
/// signed, so a new version never matches the old one's code signature.
/// Without SUPublicEDKey in Info.plist, Sparkle still starts but rejects
/// every update, which is why verify-bundle.sh refuses a release without it.
///
/// Checks happen at every launch (see init) and then every
/// SUScheduledCheckInterval seconds (Info.plist) while the app stays running.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    /// False while a check or an install is already running.
    @Published private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Whether updates are downloaded and installed without asking. This is
    /// the same setting as the checkbox in Sparkle's update dialog. Persisted
    /// by Sparkle in the app's user defaults.
    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// False while automatic checks are off: Sparkle only offers automatic
    /// installs together with automatic checks.
    var allowsAutomaticUpdates: Bool { controller.updater.allowsAutomaticUpdates }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)

        // One silent check per launch, so someone who opens the app sees a new
        // version straight away instead of waiting for the interval. Sparkle's
        // header says to call this only right after starting the updater, and
        // only when automatic checks are on; calling it later (on app
        // activation, say) can interfere with its own scheduler. It shows
        // nothing unless an update exists.
        //
        // A second copy of the app quits at launch in favour of the one that
        // owns the download list (see AppDelegate), so it skips the check.
        if DownloadManager.shared.ownsDownloadList,
           controller.updater.automaticallyChecksForUpdates {
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
