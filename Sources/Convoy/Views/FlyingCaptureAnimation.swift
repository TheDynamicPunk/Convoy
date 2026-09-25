import SwiftUI
import AppKit

@MainActor
final class FlyingCaptureAnimation {
    static let shared = FlyingCaptureAnimation()
    
    private init() {}
    
    func play(filename: String) {
        // The trigger here is an async network request from the browser
        // extension — there's no captured click coordinate to use. The
        // current mouse position is the most honest available proxy for
        // "where the user's attention currently is," and picking the screen
        // that actually contains it (instead of always NSScreen.main) is
        // what makes this correct on multi-monitor setups: if the browser
        // triggering the download is on a secondary display, the animation
        // now starts there instead of always on the main/menu-bar screen.
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen = screen else { return }
        
        let screenFrame = targetScreen.frame
        let visibleFrame = targetScreen.visibleFrame
        
        let cleanName = (filename as NSString).lastPathComponent
        let displayName = cleanName.count > 24 ? String(cleanName.prefix(21)) + "..." : (cleanName.isEmpty ? "Download" : cleanName)
        
        let contentView = FlyingPillView(filename: displayName)
        let hostingView = NSHostingView(rootView: contentView)
        
        let pillWidth: CGFloat = 220
        let pillHeight: CGFloat = 44
        
        // Start position: anchored at the mouse location, clamped to stay
        // fully within the target screen's visible frame so it can never
        // spawn partially off-screen near an edge or corner.
        let rawStartX = mouseLocation.x - (pillWidth / 2)
        let rawStartY = mouseLocation.y - 60
        let startX = min(max(rawStartX, visibleFrame.minX + 10), visibleFrame.maxX - pillWidth - 10)
        let startY = min(max(rawStartY, visibleFrame.minY + 10), visibleFrame.maxY - pillHeight - 10)
        let startFrame = NSRect(x: startX, y: startY, width: pillWidth, height: pillHeight)
        
        // Calculate target position: EXACT location of the menu bar icon
        let endX: CGFloat
        let endY: CGFloat
        
        if let iconFrame = findMenuBarIconFrame() {
            // Target the exact center of our menu bar status item
            endX = iconFrame.midX - (pillWidth / 2)
            endY = iconFrame.minY - (pillHeight / 2)
        } else {
            // Fallback for full-screen / hidden menu bar: top-right corner
            // of the screen the animation is actually starting on.
            endX = visibleFrame.maxX - pillWidth - 20
            endY = screenFrame.maxY - pillHeight - 12
        }
        
        let endFrame = NSRect(x: endX, y: endY, width: pillWidth, height: pillHeight)
        
        // Create an overlay NSPanel that floats over all spaces & full screen apps
        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.alphaValue = 0.0
        
        panel.orderFrontRegardless()
        
        // Phase 1: Smooth fade in at center
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        } completionHandler: {
            // Phase 2: Glide smoothly up to the exact menu bar icon position and fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.6
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(endFrame, display: true)
                    panel.animator().alphaValue = 0.0
                } completionHandler: {
                    panel.orderOut(nil)
                    panel.close()
                }
            }
        }
    }
    
    private func findMenuBarIconFrame() -> NSRect? {
        // Straight from the real NSStatusItem StatusItemManager owns — no
        // private AppKit class-name matching. This can never silently break
        // on a future macOS update the way string-matching an undocumented
        // window class name could.
        StatusItemManager.shared.statusButtonFrame
    }
}

struct FlyingPillView: View {
    let filename: String
    
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 28)
                
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Captured Download")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                
                Text(filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        }
        .frame(width: 220, height: 44)
    }
}
