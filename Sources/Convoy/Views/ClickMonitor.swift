import SwiftUI
import AppKit

/// Watches for clicks that start inside `view`'s frame, including on a
/// button or on empty space, which SwiftUI gestures don't see, and calls
/// `onClick` with the clicked view on the press and again on the release, so
/// focus set there isn't undone by the click itself. The press matters too:
/// a control that tracks the click itself keeps the release from monitors.
final class ClickWatcher {
    private weak var view: NSView?
    private let onClick: (NSView) -> Void
    private var monitor: Any?
    /// The view a click inside the frame started on, until it's released.
    private var pressed: NSView?

    init(view: NSView, onClick: @escaping (NSView) -> Void) {
        self.view = view
        self.onClick = onClick
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            guard let target = pressed else { return }
            pressed = nil
            DispatchQueue.main.async { [onClick] in onClick(target) }
            return
        }
        pressed = nil
        guard let view, let window = view.window, event.window === window,
              let content = window.contentView,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
              // Where AppKit will deliver the click. The sidebar floats over
              // the list's column and the toolbar sits above it, so a click
              // inside these bounds can still be theirs.
              let target = content.superview?.hitTest(event.locationInWindow),
              target.isDescendant(of: Self.column(of: view) ?? content),
              // A text field takes focus itself.
              !(target is NSText || target is NSTextField)
        else { return }
        pressed = target
        DispatchQueue.main.async { [onClick] in onClick(target) }
    }

    /// The split view column holding `view`, or nil outside a split view.
    private static func column(of view: NSView) -> NSView? {
        var child = view
        while let parent = child.superview {
            if parent is NSSplitView { return child }
            child = parent
        }
        return nil
    }
}

/// A SwiftUI background that runs `action` for each click inside it; see
/// `ClickWatcher`.
struct ClickMonitor: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        let coordinator = context.coordinator
        coordinator.watcher = ClickWatcher(view: view) { [weak coordinator] in coordinator?.action($0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    final class Coordinator {
        var action: (NSView) -> Void
        var watcher: ClickWatcher?
        init(action: @escaping (NSView) -> Void) { self.action = action }
    }
}

/// A helper view that never takes a click meant for the views around it.
class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
