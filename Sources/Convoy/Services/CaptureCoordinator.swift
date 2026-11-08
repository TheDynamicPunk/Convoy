import AppKit
import SwiftUI
import DownloadEngine
import os

private let captureLogger = Logger(subsystem: "Convoy", category: "CaptureDialog")

/// What the person decided about a captured download.
enum CaptureDecision {
    /// Add it and start it now.
    case start(CaptureChoices)
    /// Add it to the list without starting.
    case later(CaptureChoices)
    /// Discard the capture.
    case cancel
}

/// Where every browser capture goes first.
///
/// With "Show dialog when download is captured" off this does what IPCServer
/// used to do inline: bring the window forward if asked, play the capture
/// animation, check for a re-link, and add. With it on, the capture waits in
/// a small floating dialog (IDM's "Download File Info" is the model) showing
/// its name, size and destination, and is added only when the person answers.
///
/// Both outcomes end in `DownloadManager.addCaptured`, so a download is the
/// same download whether or not anyone was asked about it.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CaptureCoordinator()

    /// The capture the window is showing, and how many wait behind it. One at
    /// a time, in arrival order, like the duplicate sheet.
    @Published private(set) var current: CapturedDownload?
    @Published private(set) var waitingCount = 0

    private var queue: [CapturedDownload] = []
    private var panel: CaptureDialogPanel?

    private override init() { super.init() }

    // MARK: - Entry point

    /// Called by IPCServer for every capture request, on the main actor.
    func handle(_ captures: [CapturedDownload]) {
        let settings = AppSettings.shared
        let confirming = settings.confirmCapturedDownloads

        // The original behaviour, unchanged: silent captures may bring the
        // main window forward. When confirming, the capture dialog is what
        // comes forward instead, and raising the main window as well would
        // race the Dock-icon policy when the dialog closes.
        if !confirming, settings.bringWindowToFrontOnCapture {
            MainWindowTracker.shared.showMainWindow()
        }

        for capture in captures {
            Task { await route(capture, confirming: confirming) }
        }
    }

    private func route(_ capture: CapturedDownload, confirming: Bool) async {
        // A re-link in progress (the person tapped Re-link and is capturing
        // the download again) takes the capture before anything else: it is
        // checked against the expired download rather than added or confirmed.
        // Streams never re-link.
        if capture.stream == nil, RelinkCoordinator.shared.offer(capture) { return }

        // Direct mode plays the animation straight away, as it always did.
        if !confirming { FlyingCaptureAnimation.shared.play(filename: capture.displayName) }

        // A capture that re-links an expired row is not a new download, so
        // there is nothing to confirm: it picks up the old one where it
        // stopped. Streams never re-link.
        if capture.stream == nil,
           await DownloadManager.shared.matchFreshURL(capture.url, headers: capture.matchHeaders) {
            if confirming {
                // No window raise here: that option is greyed out in Settings
                // while the dialog is on, so honouring it would contradict that.
                FlyingCaptureAnimation.shared.play(filename: capture.displayName)
            }
            return
        }

        if confirming {
            enqueue(capture)
        } else {
            await DownloadManager.shared.addCaptured(capture)
        }
    }

    /// A capture the re-link window handed back because the person said it is
    /// a different download. It joins the list like any other capture, without
    /// another re-link check.
    func addAsNew(_ capture: CapturedDownload) {
        if AppSettings.shared.confirmCapturedDownloads {
            enqueue(capture)
        } else {
            FlyingCaptureAnimation.shared.play(filename: capture.displayName)
            Task { await DownloadManager.shared.addCaptured(capture) }
        }
    }

    // MARK: - Queue

    private func enqueue(_ capture: CapturedDownload) {
        if current == nil {
            current = capture
            waitingCount = 0
            present()
        } else {
            queue.append(capture)
            waitingCount = queue.count
        }
    }

    /// Applies the person's answer to `capture` and moves to the next one.
    func resolve(_ capture: CapturedDownload, _ decision: CaptureDecision) {
        // A late or repeated answer (Return pressed twice, say) for a capture
        // that is no longer showing.
        guard current?.id == capture.id else { return }

        switch decision {
        case .cancel:
            captureLogger.notice("capture cancelled in dialog")
        case .start(var choices):
            choices.startsAutomatically = true
            commit(capture, choices)
        case .later(var choices):
            choices.startsAutomatically = false
            commit(capture, choices)
        }
        advance()
    }

    private func commit(_ capture: CapturedDownload, _ choices: CaptureChoices) {
        FlyingCaptureAnimation.shared.play(filename: choices.filename ?? capture.displayName)
        Task { await DownloadManager.shared.addCaptured(capture, choices: choices) }
    }

    private func advance() {
        if queue.isEmpty {
            current = nil
            waitingCount = 0
            // close(), not orderOut: DockIconPolicy watches window closes to
            // put the hidden Dock icon back once nothing is left on screen.
            panel?.close()
        } else {
            current = queue.removeFirst()
            waitingCount = queue.count
            if let panel { releaseTextFocus(in: panel) }
        }
    }

    // MARK: - Window

    private func present() {
        showPanel()

        // Safety net. The panel is built to appear above the browser without
        // Convoy being activated, but if it still ends up where nobody can
        // see it (another Space, say), fall back to the heavier route every
        // other window here uses: lift the Dock policy and activate. A
        // capture the browser has already cancelled must never be left
        // waiting on a window the person can't find.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            ensureVisible()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            fit(panel)
            place(panel)
        }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        releaseTextFocus(in: panel)
    }

    /// If the name field took focus anyway (SwiftUI can, a beat after the
    /// panel appears), hands it back, so the text is never left selected.
    private func releaseTextFocus(in panel: NSPanel) {
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            if panel.firstResponder is NSText { panel.makeFirstResponder(nil) }
        }
    }

    private func ensureVisible() {
        guard current != nil, let panel, !panel.occlusionState.contains(.visible) else { return }
        captureLogger.notice("capture dialog not visible after showing; activating Convoy")
        DockIconPolicy.showElevatedIfHidden {
            panel.orderFrontRegardless()
            AppActivation.activate(from: NSWorkspace.shared.frontmostApplication)
        }
    }

    private func makePanel() -> CaptureDialogPanel {
        // A standard titled panel with its normal opaque background, so
        // AppKit draws it correctly in light and dark; only the close button
        // is kept, as minimise and zoom make no sense on a prompt.
        // Non-activating, like Spotlight's or Alfred's window: it can take
        // keystrokes (see CaptureDialogPanel) without making Convoy the
        // active app, so it appears over whatever the person is doing,
        // full-screen browser included, and leaves them in that app when it
        // closes.
        let panel = CaptureDialogPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Download Captured"
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        // .floating, not .statusBar: the folder chooser opens at modal-panel
        // level and has to stay above this.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // Kept and reused for the next capture rather than rebuilt.
        panel.isReleasedWhenClosed = false
        // On every Space, and over full-screen apps: what FlyingCaptureAnimation
        // already does to reach a full-screen browser.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let host = NSHostingController(rootView: CaptureDialogRoot(coordinator: self))
        panel.contentViewController = host
        // Nothing starts focused. Left to AppKit, the name field takes first
        // focus when the panel becomes key and opens with its text selected,
        // which reads as the window being mid-edit.
        panel.initialFirstResponder = host.view
        let fitting = host.view.fittingSize
        if fitting.width > 100, fitting.height > 100 { panel.setContentSize(fitting) }
        return panel
    }

    /// Sizes the panel to its content NOW, before it is positioned. Left to
    /// SwiftUI it is sized a beat after appearing, so anything that centred it
    /// before then used a placeholder size and ended up off-centre.
    private func fit(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if size.width > 100, size.height > 100 { panel.setContentSize(size) }
    }

    /// Horizontally centred, a fixed distance down from the top of the screen
    /// the mouse is on (the browser's, almost always: the person just clicked
    /// something there). Anchored by the TOP edge, so if the content later
    /// grows (the web-page warning, a queue count) the window extends
    /// downward instead of the whole dialog jumping.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.midX - panel.frame.width / 2,
            y: visible.maxY - visible.height * 0.22
        ))
    }

    // MARK: - NSWindowDelegate

    /// The red close button and ⌘W mean "not this one", the same as Cancel:
    /// the capture is dropped, and the window stays up if more are waiting.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let capture = current {
            resolve(capture, .cancel)
        }
        // resolve() has already closed the panel itself when nothing is left.
        return false
    }
}

/// A floating panel that can take key focus, so the name field is editable
/// and Return / Escape work.
final class CaptureDialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: the current capture's dialog view, rebuilt (via `id`)
/// for each capture so no state leaks from one to the next.
private struct CaptureDialogRoot: View {
    @ObservedObject var coordinator: CaptureCoordinator
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            if let capture = coordinator.current {
                CaptureDialogView(
                    capture: capture,
                    waitingCount: coordinator.waitingCount,
                    onDecision: { decision in coordinator.resolve(capture, decision) }
                )
                .id(capture.id)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .preferredColorScheme(settings.theme.colorScheme)
    }
}
