import Foundation
import UserNotifications
import DownloadEngine

/// Bridges DownloadManager's `.downloadCompleted` event to the two General
/// settings that promise feedback when a download finishes: `showNotifications`
/// controls whether a banner is posted at all, and `playCompletionSound`
/// controls whether that banner asks for a sound. The sound itself is
/// `UNNotificationSound.default` — macOS's own notification sound — rather
/// than a file we pick and play ourselves, so it inherits the user's actual
/// notification-sound choice and gets silenced by Focus/Do Not Disturb like
/// any other app's notification would. That also means sound can't ring
/// without the banner: they're the same native object now, not two
/// independent effects we're triggering by hand.
@MainActor
final class DownloadCompletionAlertService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DownloadCompletionAlertService()

    private var started = false

    override private init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        NotificationCenter.default.addObserver(
            forName: .downloadCompleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let task = note.object as? DownloadTask else { return }
            Task { @MainActor in
                self?.handleCompletion(of: task)
            }
        }
    }

    private func handleCompletion(of task: DownloadTask) {
        let settings = AppSettings.shared
        guard settings.showNotifications else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = task.originalName
        content.sound = settings.playCompletionSound ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        )
    }

    // Without this, macOS suppresses the banner (and its sound) entirely
    // whenever Convoy is the frontmost app — exactly the common case
    // for a download someone is actively watching finish.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
