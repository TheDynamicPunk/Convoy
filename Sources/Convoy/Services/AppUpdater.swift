import Combine
import Sparkle

/// The app's one Sparkle updater. The app menu, the menu bar item and
/// Settings all act on this instance.
///
/// Updates are accepted on the EdDSA signature alone: the app is ad-hoc
/// signed, so a new version never matches the old one's code signature.
/// Without SUPublicEDKey in Info.plist, Sparkle still starts but rejects
/// every update, which is why verify-bundle.sh refuses a release without it.
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

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
