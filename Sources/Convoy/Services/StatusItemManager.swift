import AppKit
import SwiftUI
import DownloadEngine

@MainActor
final class StatusItemManager: NSObject, NSMenuDelegate {
    static let shared = StatusItemManager()
    
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var liveTaskItems: [(task: DownloadTask, item: NSMenuItem)] = []
    private var liveTimer: Timer?
    
    /// The status item's real screen frame, straight from the actual
    /// `NSStatusItem` we own — no guessing about private AppKit window
    /// class names required. `nil` before `setup()` runs or if the button
    /// isn't currently in a window (e.g. menu bar hidden in full screen).
    var statusButtonFrame: NSRect? {
        statusItem?.button?.window?.frame
    }
    
    override private init() {
        super.init()
    }
    
    func setup() {
        guard statusItem == nil else { return }
        
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let customIcon = loadMenuBarIcon() {
                button.image = customIcon
            } else {
                button.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Convoy")
            }
        }
        
        menu.delegate = self
        // Off, or AppKit decides each item's enabled state itself from whether
        // something in the responder chain answers its action -- which it
        // always does here, so every `isEnabled = false` set in menuWillOpen
        // was being overwritten before the menu drew.
        menu.autoenablesItems = false
        item.menu = menu
        self.statusItem = item
    }
    
    private func loadMenuBarIcon() -> NSImage? {
        // image(forResource:) pairs MenuBarIcon.png with its @2x sibling;
        // NSImage(contentsOfFile:) would load the 1x bitmap alone and blur
        // it on a Retina menu bar.
        if let img = Bundle.main.image(forResource: "MenuBarIcon") {
            img.isTemplate = true
            img.accessibilityDescription = "Convoy"
            return img
        }
        if let img = NSImage(named: "MenuBarIcon") {
            img.isTemplate = true
            return img
        }
        let devPath = (Bundle.main.bundlePath as NSString).deletingLastPathComponent + "/Resources/MenuBarIcon.png"
        if let img = NSImage(contentsOfFile: devPath) {
            img.isTemplate = true
            return img
        }
        return nil
    }
    
    func triggerIconBounce() {
        guard let button = statusItem?.button else { return }
        button.isHighlighted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            button.isHighlighted = false
        }
    }
    
    // MARK: - NSMenuDelegate
    
    func menuWillOpen(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTaskItems.removeAll()
        menu.removeAllItems()
        
        // 1. Open Convoy
        let openItem = NSMenuItem(title: "Open Convoy", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 2. Active downloads list snapshot
        let manager = DownloadManager.shared
        // Listed in the menu; whether Pause All is available comes from
        // hasPausableTasks, which the File menu uses too.
        let active = manager.tasks.filter { $0.status == .downloading || $0.status == .starting || $0.status == .waiting }
        
        if !active.isEmpty {
            for task in active.prefix(5) {
                let title = formattedTaskTitle(task: task)
                let taskItem = NSMenuItem(title: title, action: #selector(openMainWindow), keyEquivalent: "")
                taskItem.target = self
                menu.addItem(taskItem)
                liveTaskItems.append((task: task, item: taskItem))
            }
            if active.count > 5 {
                let moreItem = NSMenuItem(title: "... and \(active.count - 5) more", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                menu.addItem(moreItem)
            }
            menu.addItem(NSMenuItem.separator())
            
            // Start 1Hz timer to update item.title in-place while menu remains open.
            // MUST add forMode: .eventTracking so the timer fires during NSMenu tracking loop!
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.updateLiveTitles()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
            self.liveTimer = timer
        }
        
        // 3. Pause All
        let pauseItem = NSMenuItem(title: "Pause All", action: #selector(pauseAll), keyEquivalent: "")
        pauseItem.target = self
        pauseItem.isEnabled = manager.hasPausableTasks
        menu.addItem(pauseItem)
        
        // 4. Resume All
        let resumeItem = NSMenuItem(title: "Resume All", action: #selector(resumeAll), keyEquivalent: "")
        resumeItem.target = self
        resumeItem.isEnabled = manager.hasResumableTasks
        menu.addItem(resumeItem)
        
        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = AppUpdater.shared.canCheckForUpdates
        menu.addItem(updateItem)

        // 5. Quit Convoy
        let quitItem = NSMenuItem(title: "Quit Convoy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
    
    func menuDidClose(_ menu: NSMenu) {
        liveTimer?.invalidate()
        liveTimer = nil
        liveTaskItems.removeAll()
    }
    
    private func updateLiveTitles() {
        for (task, item) in liveTaskItems {
            let newTitle = formattedTaskTitle(task: task)
            if item.title != newTitle {
                item.title = newTitle
            }
        }
    }
    
    private func formattedTaskTitle(task: DownloadTask) -> String {
        let percent = Int(task.progress * 100)
        let cleanName = (task.filename as NSString).lastPathComponent
        let shortName = cleanName.count > 22 ? String(cleanName.prefix(19)) + "..." : cleanName
        if task.status == .downloading {
            return "↓  \(shortName)  (\(percent)%)"
        } else {
            return "↓  \(shortName)  (Connecting...)"
        }
    }
    
    // MARK: - Actions
    
    @objc private func openMainWindow() {
        // Delegates entirely to MainWindowTracker.showMainWindow() — see its
        // doc comment for why this replaced a second, separately-written
        // copy of the same "activate, deminiaturize if needed, order front,
        // or open fresh" logic that used to live here.
        MainWindowTracker.shared.showMainWindow()
    }
    
    @objc private func pauseAll() {
        Task {
            await DownloadManager.shared.pauseAll()
        }
    }
    
    @objc private func resumeAll() {
        Task {
            await DownloadManager.shared.resumeAll()
        }
    }
    
    @objc private func checkForUpdates() {
        AppUpdater.shared.checkForUpdates()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
