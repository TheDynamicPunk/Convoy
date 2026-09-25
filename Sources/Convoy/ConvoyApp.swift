import SwiftUI
import SwiftData
import DownloadEngine
import AppKit
import os

/// Follow the extension → app hand-off with:
///   log stream --predicate 'subsystem == "Convoy"' --level info
let appLogger = Logger(subsystem: "Convoy", category: "AppLaunch")

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A second running copy switches to the one that owns the download list
    /// and quits, before any window or menu bar item exists.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !DownloadManager.shared.ownsDownloadList else { return }
        appLogger.notice("another copy owns the download list; switching to it and quitting")
        let owner = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0 != .current }
        owner?.activate(from: .current, options: .activateAllWindows)
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No runtime icon override here — CFBundleIconFile in Info.plist
        // (already correctly set to "AppIcon") plus a correctly-placed
        // AppIcon.icns at Contents/Resources/ is the actual production
        // mechanism. LaunchServices reads that at launch (and even before
        // launch, for Finder/Spotlight/Get Info), so there's nothing left
        // for app code to do. The removed NSApp.applicationIconImage
        // override only patched the Dock icon, only after the process was
        // already running (a visible flash of the default icon first), and
        // did nothing for Finder/Spotlight/Get Info — partial coverage of a
        // problem that shouldn't exist if the bundle is assembled correctly.
        StatusItemManager.shared.setup()
        DownloadCompletionAlertService.shared.start()
        BrowserSetupModel.shared.launch()
        _ = AppUpdater.shared
        // Helper versions travel in app updates now, so an update can leave
        // newer ones listed than are installed. Returns immediately unless
        // this launch is the one after such an update.
        HelperAutoUpdate.shared.runAtLaunch()
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Delegates entirely to MainWindowTracker.showMainWindow() — the
        // single shared implementation both this and the menu bar's "Open
        // Convoy" button use, so they can't drift out of sync again
        // (that's exactly how the "works from menu bar, not from Dock" bug
        // happened). Returning false suppresses AppKit's own default reopen
        // window creation for the WindowGroup — without it, a Dock click on
        // a closed window created a second, duplicate window alongside the
        // one showMainWindow() opens via the convoy:// URL.
        MainWindowTracker.shared.showMainWindow()
        return false
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        DownloadManager.shared.saveBeforeTermination()
    }
}

/// Holds a convoy://add?url= hand-off until a ContentView is ready to
/// act on it.
///
/// The notification alone isn't enough. When the app is *closed* and the
/// browser extension's latch launches it, the URL event and ContentView's
/// NotificationCenter subscription race: `NotificationCenter.post` is
/// fire-and-forget, so a post that lands before `.onReceive` is wired up is
/// dropped silently and the user gets a window with no dialog — exactly the
/// case the latch is for. Parking the URL here as well makes delivery
/// order-independent: whichever happens first, ContentView finds the URL.
@MainActor
final class PendingOpenIntent: ObservableObject {
    static let shared = PendingOpenIntent()

    private var youtubeURL: String?

    func store(youtubeURL url: String) {
        self.youtubeURL = url
    }

    /// Returns the parked URL, if any, and clears it — so a later window
    /// appearing (or the same one re-appearing) doesn't re-trigger a stale
    /// download dialog.
    func takeYouTubeURL() -> String? {
        defer { youtubeURL = nil }
        return youtubeURL
    }
}

@main
struct ConvoyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Not observed here: the views that show downloads observe it themselves.
    // As a @StateObject, every change it published (progress included)
    // re-evaluated the whole scene.
    private let downloadManager = DownloadManager.shared
    @StateObject private var settings = AppSettings.shared
    
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(downloadManager)
                .environmentObject(settings)
                .preferredColorScheme(settings.theme.colorScheme)
                .background(WindowAccessor { window in
                    // Registers the real NSWindow with MainWindowTracker so
                    // the menu bar's "Open Convoy" can reliably find
                    // and refocus it instead of spawning a duplicate — see
                    // MainWindowTracker.swift for why this replaced two
                    // earlier, both-fragile string-matching approaches.
                    MainWindowTracker.shared.register(window)
                })
                .task {
                    IPCServer.shared.start()
                }
                // Content-level companion to the Scene-level
                // .handlesExternalEvents(matching:) below. Scene-level =
                // "this window type can open for such event, if none open
                // yet." This = "prefer THIS existing window for such event
                // instead of a new one." Without both, every
                // convoy://add open spawns a brand-new window +
                // ContentView (with its own empty @State) instead of
                // reusing the one already running.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { url in
                    // convoy://add?url=<encoded watch-page URL> —
                    // sent by NativeMessagingHost's openAppWithYouTubeURL
                    // when the browser extension's download button is
                    // clicked on a YouTube page. Any other convoy://
                    // URL (e.g. convoy://open, used by
                    // MainWindowTracker to focus the window) just activates
                    // — that path is already an explicit "bring the window
                    // forward" request in its own right (menu bar/Dock),
                    // not a capture notification, so it's unconditional and
                    // not gated by bringWindowToFrontOnCapture below.
                    appLogger.info("onOpenURL pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) url=\(url.absoluteString)")
                    guard url.host == "add",
                          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let downloadURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
                          !downloadURL.isEmpty else {
                        NSApp.activate(ignoringOtherApps: true)
                        appLogger.info("onOpenURL: not an add-with-url request, activating only")
                        return
                    }
                    appLogger.info("onOpenURL: parked+posted \(downloadURL)")
                    // Park it *and* post: see PendingOpenIntent for why the
                    // notification alone loses cold-launch hand-offs.
                    PendingOpenIntent.shared.store(youtubeURL: downloadURL)
                    NotificationCenter.default.post(name: .openYouTubeDownload, object: nil, userInfo: ["url": downloadURL])
                    // This IS a capture that needs a decision (pick a
                    // quality/format before anything downloads) — gated by
                    // alwaysFocusForRequiredInput, not bringWindowToFrontOnCapture:
                    // that setting is for silent captures with nothing to
                    // decide, this one blocks until someone picks a format.
                    // showMainWindow() rather than a bare NSApp.activate: the
                    // shared, already-correct implementation (deminiaturizes,
                    // creates the window fresh if none exists) instead of
                    // assuming a window is already there to activate.
                    if settings.alwaysFocusForRequiredInput {
                        MainWindowTracker.shared.showMainWindow()
                    }
                }
        }
        .handlesExternalEvents(matching: ["*"])
        // The first-open size only; macOS restores whatever size the person
        // leaves it at. The minimum comes from the columns in ContentView.
        .defaultSize(width: 1000, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }

            CommandGroup(replacing: .newItem) {
                Button("New Download...") {
                    NotificationCenter.default.post(name: .newDownload, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button("Paste URLs...") {
                    NotificationCenter.default.post(name: .pasteURLs, object: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            
            CommandGroup(after: .newItem) {
                DownloadCommands()
            }
        }
        
        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}

/// The File menu's download commands, greyed out when they have nothing to
/// act on.
///
/// Its own view for the same reason as CheckForUpdatesButton, and for one
/// more: the App struct deliberately doesn't observe DownloadManager, because
/// doing so re-evaluated the whole scene on every progress update. Observing
/// it here narrows that to three menu items.
private struct DownloadCommands: View {
    @ObservedObject private var manager = DownloadManager.shared

    var body: some View {
        Divider()

        Button("Pause All") {
            Task { await manager.pauseAll() }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!manager.hasPausableTasks)

        Button("Resume All") {
            Task { await manager.resumeAll() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!manager.hasResumableTasks)

        Divider()

        // Posts rather than deleting directly so ⌘⇧⌫ lands in the same
        // confirmation as every other delete — it used to wipe the whole
        // completed list on one keystroke with nothing shown, which made it
        // the easiest destructive action in the app to hit by accident.
        Button("Delete All Completed") {
            NotificationCenter.default.post(name: .deleteAllCompleted, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: [.command, .shift])
        .disabled(!manager.hasCompletedTasks)
    }
}

/// Its own view so the menu item tracks AppUpdater's state; a Button inside
/// `.commands` doesn't observe objects the App struct holds.
private struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

extension Notification.Name {
    static let newDownload = Notification.Name("newDownload")
    static let pasteURLs = Notification.Name("pasteURLs")
    // Posted by ConvoyApp's onOpenURL when a convoy://add?url=
    // link arrives (from the browser extension's YouTube download button).
    // userInfo["url"] carries the YouTube watch-page URL as a String.
    static let openYouTubeDownload = Notification.Name("openYouTubeDownload")
    static let deleteAllCompleted = Notification.Name("deleteAllCompleted")
}
