import SwiftUI
import AppKit

/// Keyboard focus and keys for the downloads list, held by AppKit directly.
///
/// This replaces SwiftUI focus (`.focusable`, `@FocusState`, `.onKeyPress`,
/// `.onExitCommand`, `.onDeleteCommand`, `.onCommand`). On macOS 27 a click in
/// the list could leave SwiftUI sure the list had focus while AppKit's first
/// responder was the bare window: arrows still worked, but Esc, Delete and ⌘A
/// went nowhere, and setting the focus state again was ignored. A plain first
/// responder gets the keys and the Edit menu's actions the standard AppKit way.
struct ListKeyResponder: NSViewRepresentable {
    var canSelectAll: Bool
    var canDelete: Bool
    var onArrow: (_ direction: Int, _ extendSelection: Bool) -> Void
    var onEscape: () -> Void
    var onDelete: () -> Void
    var onSelectAll: () -> Void
    /// Called with whether the list has focus whenever that may have changed.
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> ListResponderView { ListResponderView() }

    func updateNSView(_ view: ListResponderView, context: Context) {
        view.handlers = self
    }
}

final class ListResponderView: PassThroughView {
    var handlers: ListKeyResponder?

    private var clickWatcher: ClickWatcher?
    private var responderObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var hadFocusOnDeactivate = false
    private var hadFocusBeforeSheet = false
    private var lastReclaim = Date.distantPast

    private static let escapeKeyCode: UInt16 = 53

    var hasFocus: Bool { window?.firstResponder === self }

    func takeFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    // MARK: First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        reportFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        reportFocus()
        return true
    }

    /// Deferred so a change made during a SwiftUI update doesn't write SwiftUI
    /// state mid-update, and reads the settled state rather than the event.
    private func reportFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handlers?.onFocusChange(self.hasFocus)
        }
    }

    /// Focus with no particular home: none, the window itself, or a view that
    /// merely contains the list.
    static func isUnclaimed(_ responder: NSResponder?, in window: NSWindow?, around view: NSView) -> Bool {
        guard let responder else { return true }
        if responder === window { return true }
        guard let container = responder as? NSView else { return false }
        return container !== view && view.isDescendant(of: container)
    }

    private func reclaimFocus() {
        guard let window, Self.isUnclaimed(window.firstResponder, in: window, around: self),
              // Never a tight loop if something keeps taking it.
              Date().timeIntervalSince(lastReclaim) > 0.25
        else { return }
        lastReclaim = Date()
        takeFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clickWatcher = nil
        responderObservation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }

        clickWatcher = ClickWatcher(view: self) { [weak self] _ in self?.takeFocus() }

        // When focus falls from the list to nothing in particular, the list
        // keeps it. A move to a real control, like the sidebar or the search
        // field, is left alone.
        responderObservation = window.observe(\.firstResponder, options: [.old, .new]) { [weak self] window, change in
            guard let self, (change.oldValue ?? nil) === self,
                  Self.isUnclaimed(change.newValue ?? nil, in: window, around: self)
            else { return }
            DispatchQueue.main.async { self.reclaimFocus() }
        }

        let center = NotificationCenter.default
        observers = [
            // Reactivating hands focus to the window's first key view, the
            // sidebar, whichever had it before.
            center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hadFocusOnDeactivate = self?.hasFocus ?? false
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard self?.hadFocusOnDeactivate == true else { return }
                // After AppKit's own first-responder restore, or it wins.
                DispatchQueue.main.async { self?.takeFocus() }
            },
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                self?.hadFocusBeforeSheet = self?.hasFocus ?? false
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                guard self?.hadFocusBeforeSheet == true else { return }
                DispatchQueue.main.async { self?.takeFocus() }
            },
        ]

        // Back from an empty category, or at launch, with nothing focused.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  Self.isUnclaimed(window.firstResponder, in: window, around: self)
            else { return }
            self.takeFocus()
        }
    }

    // MARK: Keys and menu actions

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard let handlers, modifiers.isEmpty else { return super.keyDown(with: event) }
        let extend = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: handlers.onArrow(-1, extend)
        case .downArrow?: handlers.onArrow(1, extend)
        case .delete?, .deleteForward?, .backspace?: handlers.onDelete()
        default:
            if event.keyCode == Self.escapeKeyCode {
                handlers.onEscape()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// ⌘. and anything else that sends cancelOperation: to the list.
    override func cancelOperation(_ sender: Any?) { handlers?.onEscape() }

    /// Edit ▸ Select All and ⌘A.
    override func selectAll(_ sender: Any?) { handlers?.onSelectAll() }

    /// Edit ▸ Delete.
    @objc func delete(_ sender: Any?) { handlers?.onDelete() }
}

extension ListResponderView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectAll(_:)): return handlers?.canSelectAll ?? false
        case #selector(delete(_:)): return handlers?.canDelete ?? false
        default: return true
        }
    }
}
