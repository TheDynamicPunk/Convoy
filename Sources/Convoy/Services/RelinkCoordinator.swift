import AppKit
import Combine
import SwiftUI
import DownloadEngine
import os

private let relinkLogger = Logger(subsystem: "Convoy", category: "Relink")

/// A capture that arrived during a re-link and does not look like the file
/// being re-linked, waiting on the person's answer.
struct RelinkMismatch {
    let capture: CapturedDownload
    let verdict: RelinkVerdict
}

/// What the re-link window is showing.
enum RelinkPhase {
    /// Waiting for the person to capture the download again in the browser.
    case listening
    /// A capture arrived but cannot be shown to be the same file.
    case mismatch(RelinkMismatch)
    /// The link was swapped in. `restarted` is true when the partial data was
    /// discarded and the download begins again from the start.
    case success(restarted: Bool)
}

/// The re-link session: from tapping Re-link on an expired download until its
/// new link is in place (or the person gives up).
///
///  1. Re-link opens the source page in the browser and shows a small
///     floating window asking the person to capture the download again.
///  2. The next capture is routed here by `CaptureCoordinator` instead of
///     being added as a new download, and compared with the expired one.
///  3. Same file: the link is swapped in and the download resumes where it
///     stopped.
///  4. Anything else: the window says so and asks. Only if the person
///     confirms is the link swapped in, and then the download restarts from
///     byte 0, since the partial data belongs to a file that is not this one.
///
/// Only one session at a time; starting another replaces it. The row itself
/// never changes until a link is accepted, so cancelling, timing out or
/// closing the window leaves it exactly as it was: still `.urlExpired`, still
/// offering Re-link.
@MainActor
final class RelinkCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RelinkCoordinator()

    /// How long a session waits for a capture before giving up.
    static let timeout: Duration = .seconds(5 * 60)

    /// The download being re-linked; nil when no session is running.
    @Published private(set) var task: DownloadTask?
    @Published private(set) var phase: RelinkPhase = .listening

    private var panel: RelinkPanel?
    private var timeoutTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var statusObserver: AnyCancellable?

    private override init() { super.init() }

    // MARK: - Starting and ending a session

    /// Starts a session for an expired download: opens its source page and
    /// shows the window. A no-op for a task that is not `.urlExpired`.
    func begin(for task: DownloadTask) {
        guard case .urlExpired = task.status else { return }

        // A second Re-link replaces whatever was running.
        closeTask?.cancel()
        self.task = task
        phase = .listening
        observe(task)
        restartTimeout()
        showPanel()

        // The panel is up first so it is already in place when the browser
        // comes forward. Opening the system default browser for now: which
        // browser to use is a separate setting.
        if let source = task.referrerURL {
            NSWorkspace.shared.open(source)
        }
        relinkLogger.notice("re-link session started")
    }

    func cancel() {
        relinkLogger.notice("re-link session cancelled")
        end()
    }

    private func timedOut() {
        relinkLogger.notice("re-link session timed out with no capture")
        end()
    }

    private func end() {
        timeoutTask?.cancel()
        closeTask?.cancel()
        statusObserver = nil
        task = nil
        phase = .listening
        // close(), not orderOut: DockIconPolicy watches window closes to put
        // the hidden Dock icon back once nothing is left on screen.
        panel?.close()
    }

    private func restartTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: RelinkCoordinator.timeout)
            guard !Task.isCancelled else { return }
            self?.timedOut()
        }
    }

    /// Ends the session if the download stops being `.urlExpired` for any
    /// reason other than this session re-linking it (resumed through the
    /// duplicate sheet, say). Otherwise the window would keep waiting for a
    /// link nothing needs.
    private func observe(_ task: DownloadTask) {
        statusObserver = task.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if case .urlExpired = status { return }
                if case .success = self.phase { return }
                self.end()
            }
    }

    // MARK: - Captures

    /// Called by CaptureCoordinator for every non-stream capture. Returns true
    /// if the session took it, in which case it is not a new download.
    func offer(_ capture: CapturedDownload) -> Bool {
        guard let task else { return false }

        // The row may have been deleted or moved on while the window was up.
        guard case .urlExpired = task.status,
              DownloadManager.shared.tasks.contains(where: { $0.id == task.id }) else {
            end()
            return false
        }

        // A question is already on screen, or the link was just accepted: this
        // capture is not part of the session, so it goes the normal way
        // instead of being lost behind it.
        guard case .listening = phase else { return false }

        let verdict = RelinkVerdict.judge(expected: task.totalBytes, offered: capture.offeredSize)
        switch verdict {
        case .sameFile:
            relinkLogger.notice("re-link capture matches; resuming")
            accept(capture, for: task, restart: false)
        case .differentSize, .cannotVerify:
            relinkLogger.notice("re-link capture does not match; asking")
            // The person is reading a question now: don't time out under them.
            timeoutTask?.cancel()
            phase = .mismatch(RelinkMismatch(capture: capture, verdict: verdict))
            panel?.orderFrontRegardless()
        }
        return true
    }

    /// Mismatch answer: swap the link in anyway and start over from byte 0.
    func confirmRestart() {
        guard let task, case .mismatch(let mismatch) = phase else { return }
        guard case .urlExpired = task.status else {
            end()
            return
        }
        accept(mismatch.capture, for: task, restart: true)
    }

    /// Mismatch answer: this is a different download. It joins the list like
    /// any other capture, and the session keeps waiting for the real one.
    func addAsNewDownload() {
        guard case .mismatch(let mismatch) = phase else { return }
        phase = .listening
        restartTimeout()
        CaptureCoordinator.shared.addAsNew(mismatch.capture)
    }

    /// Mismatch answer: drop that capture and keep waiting.
    func ignoreCapture() {
        guard case .mismatch = phase else { return }
        phase = .listening
        restartTimeout()
    }

    private func accept(_ capture: CapturedDownload, for task: DownloadTask, restart: Bool) {
        timeoutTask?.cancel()
        // Before the swap: relinking changes the task's status, which the
        // observer above would otherwise read as the session being over.
        phase = .success(restarted: restart)
        DownloadManager.shared.relink(task, with: capture, restart: restart)

        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.end()
        }
    }

    func copySourceLink() {
        guard let source = task?.referrerURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source.absoluteString, forType: .string)
    }

    // MARK: - Window

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            fit(panel)
            place(panel)
        }
        // Never made key: the person is about to work in the browser, and
        // taking its keyboard focus would be the opposite of helping.
        panel.orderFrontRegardless()
    }

    private func makePanel() -> RelinkPanel {
        // Same recipe as the capture dialog: a standard titled panel that is
        // non-activating, so it floats over the browser (full-screen included)
        // without making Convoy the active app.
        let panel = RelinkPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Re-link Download"
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let host = NSHostingController(rootView: RelinkHUDRoot(coordinator: self))
        panel.contentViewController = host
        let fitting = host.view.fittingSize
        if fitting.width > 100, fitting.height > 100 { panel.setContentSize(fitting) }
        return panel
    }

    private func fit(_ panel: NSPanel) {
        guard let view = panel.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        if size.width > 100, size.height > 100 { panel.setContentSize(size) }
    }

    /// Top-right of the screen the mouse is on (the one Re-link was tapped
    /// on), clear of the capture dialog, which opens top-centre. Anchored by
    /// the top edge so the window grows downward when the content changes.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        panel.setFrameTopLeftPoint(NSPoint(
            x: visible.maxX - panel.frame.width - 24,
            y: visible.maxY - 24
        ))
    }

    // MARK: - NSWindowDelegate

    /// The red close button means "stop re-linking", the same as Cancel.
    /// With no session running there is nothing to cancel, so it just closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard task != nil else { return true }
        cancel()
        return false
    }
}

/// A floating panel for the re-link window.
final class RelinkPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}
