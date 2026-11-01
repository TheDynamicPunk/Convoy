import AppKit
import DownloadEngine
import os

/// The one place the "Hide Dock icon" setting becomes an activation policy.
///
/// Hidden means `.accessory`: no Dock icon, no ⌘+Tab entry, and no menu bar
/// while the app is frontmost. But an accessory app can't leave a full-screen
/// Space or take key focus, so the app is only ever an accessory while it has
/// no window open: anything that opens one lifts it to `.regular` first
/// (`showElevatedIfHidden`, or `applyStored` at launch), and the policy drops
/// back when the last window closes. The one exception is the toggle itself,
/// which applies at once so the person sees what they just chose.
///
/// Info.plist deliberately doesn't set `LSUIElement`, because that is fixed at
/// build time and this has to follow the setting, so the policy is applied
/// from code instead.
@MainActor
enum DockIconPolicy {
    /// At launch, before any window exists.
    ///
    /// With the icon hidden, the app deliberately starts as a regular one and
    /// stays so until its window closes: a launch opens the window like any
    /// other trigger does, and an accessory app can't take focus or switch
    /// Spaces for it. Same rule as `showElevatedIfHidden`, so the revert logic
    /// is shared. A normal launch (icon shown) has nothing to do.
    static func applyStored() {
        guard AppSettings.shared.hideDockIcon else { return }
        beginTemporaryElevation()
    }

    /// When the toggle changes, including via Restore Defaults.
    ///
    /// Changing policy while the app is frontmost can drop it out of the
    /// foreground, which would send the Settings window the person is
    /// using behind everything else. It is brought back on the next turn of
    /// the run loop, once the change has settled.
    static func settingChanged(hidden: Bool) {
        // The setting is the authority now; whatever temporary elevation was
        // in flight no longer has anything to revert to.
        clearElevation()
        let target: NSApplication.ActivationPolicy = hidden ? .accessory : .regular
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        DispatchQueue.main.async {
            SettingsWindowTracker.shared.bringToFront()
        }
    }

    /// Puts the Dock icon back to hidden if something outside the app has
    /// switched it to a regular app behind its back.
    ///
    /// The policy lives only in the running process, while LaunchServices and
    /// Info.plist still describe Convoy as a regular app, so something routed
    /// through the system (most likely reopening a closed window through the
    /// convoy:// URL) can bring the icon back, and nothing else ever takes it
    /// away again. Called whenever the app comes forward or a main window is
    /// created, the two moments the icon was seen coming back.
    ///
    /// Dropping to accessory can take the app out of the foreground, so a
    /// correction re-activates it on the next turn of the run loop.
    /// Returns whether it had to correct anything.
    @discardableResult
    static func restoreIfDrifted() -> Bool {
        // A temporary elevation is deliberate, not drift: correcting it here
        // would flip the app back to accessory the moment it activates, which
        // is exactly the moment the elevation exists for.
        guard AppSettings.shared.hideDockIcon,
              !isTemporarilyRegular,
              NSApp.activationPolicy() != .accessory else { return false }
        appLogger.notice("Dock icon is hidden in Settings but the app had become a regular app; hiding it again")
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            AppActivation.activate()
        }
        return true
    }

    // MARK: - Temporary elevation for focus requests

    /// True while the app is a regular app only because a window needed it to
    /// be, with the setting still saying hidden.
    private static var isTemporarilyRegular = false

    private static var closeObserver: NSObjectProtocol?

    /// The pending backstop check. Replaced on every elevation, so an older
    /// one can't fire while a newer elevation's window is still opening.
    private static var safetyCheck: Task<Void, Never>?

    /// Runs `focus` (a request to bring Convoy forward), first making the app
    /// a regular one if the Dock icon is hidden.
    ///
    /// Why: macOS only lets a `.regular` app pull the person out of another
    /// app's full-screen Space and take key focus there. An `.accessory` app
    /// is treated as a background agent, so with the icon hidden a capture or
    /// a prompt that needs an answer could never come forward from a
    /// full-screen browser, whatever the focus settings said.
    ///
    /// The app stays regular, with the Dock icon showing, until the last
    /// window closes (see `revertIfNoWindowsRemain`). Every path that opens a
    /// window from another app goes through here: captures, prompts that need
    /// an answer, the menu bar, reopening from Finder or the Dock, and the
    /// Settings deep link. `MainWindowTracker.showMainWindow()` is the usual
    /// way in.
    ///
    /// When the policy actually changes, `focus` runs on the next turn of the
    /// run loop, because activating in the same turn as the change is a race
    /// that loses; the app is activated once more shortly after if that still
    /// hasn't taken. Only the activation is repeated, not `focus`, so a window
    /// is never opened twice.
    static func showElevatedIfHidden(_ focus: @escaping @MainActor () -> Void) {
        guard AppSettings.shared.hideDockIcon else {
            focus()
            return
        }

        // Also covers a drifted regular policy: either way the elevation flag
        // has to be up so restoreIfDrifted doesn't undo it mid-activation.
        let needsPolicyChange = NSApp.activationPolicy() != .regular
        beginTemporaryElevation()
        if needsPolicyChange {
            NSApp.setActivationPolicy(.regular)
        }

        guard needsPolicyChange else {
            focus()
            return
        }
        // Named now, while it is still whoever the person was using when this
        // was asked, rather than whoever is frontmost by the time the retry runs.
        let sender = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.async { focus() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if !NSApp.isActive { AppActivation.activate(from: sender) }
        }
    }

    /// Marks the app as regular only for as long as a window needs it, and
    /// arms the revert: the close observer, plus the backstop for a window
    /// that never appears. Sets no policy itself; at launch the app is already
    /// regular, and `showElevatedIfHidden` changes it after calling this.
    private static func beginTemporaryElevation() {
        isTemporarilyRegular = true
        beginWatchingWindowCloses()
        scheduleSafetyCheck()
    }

    /// Drops the temporary elevation without touching the policy. For when
    /// the setting itself has just changed and has set the policy it wants.
    private static func clearElevation() {
        isTemporarilyRegular = false
        safetyCheck?.cancel()
        safetyCheck = nil
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
    }

    /// Hides the Dock icon again once nothing is left on screen to need it.
    ///
    /// `closing` is the window whose willClose triggered the check: it is still
    /// visible at that moment, so it is excluded rather than waiting for it to
    /// disappear. Windows that are only minimized count as remaining, because
    /// an accessory app gives the person no Dock icon to restore them from.
    private static func revertIfNoWindowsRemain(excluding closing: ObjectIdentifier?) {
        guard isTemporarilyRegular, !hasWindowOnScreen(excluding: closing) else { return }
        clearElevation()
        guard AppSettings.shared.hideDockIcon else { return }
        appLogger.notice("last window closed; hiding the Dock icon again")
        NSApp.setActivationPolicy(.accessory)
    }

    /// Real windows only. The status item and menu windows can't become key,
    /// so `canBecomeKey` leaves them out; the main window, Settings, and any
    /// sheet or alert the person is answering all count.
    private static func hasWindowOnScreen(excluding closing: ObjectIdentifier?) -> Bool {
        NSApp.windows.contains { window in
            guard ObjectIdentifier(window) != closing, window.canBecomeKey else { return false }
            return window.isVisible || window.isMiniaturized
        }
    }

    private static func beginWatchingWindowCloses() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            // An ObjectIdentifier rather than the window itself, so nothing
            // non-Sendable crosses into the Task.
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            Task { @MainActor in
                DockIconPolicy.revertIfNoWindowsRemain(excluding: closing)
            }
        }
    }

    /// Backstop for an elevation whose window never appeared (the open failed,
    /// or the window was closed before anything was watching), which would
    /// otherwise leave the Dock icon showing until the next window closes.
    /// Generous on purpose: on a cold launch the window can take a moment.
    private static func scheduleSafetyCheck() {
        safetyCheck?.cancel()
        safetyCheck = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            DockIconPolicy.revertIfNoWindowsRemain(excluding: nil)
        }
    }
}
