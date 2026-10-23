import AppKit
import SwiftUI

/// Brief feedback without making a window key or changing the active app.
@MainActor public final class TransientFeedback {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    public init() {}
    public func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
    public func show(_ message: String, error: Bool = false, on screen: NSScreen? = nil) {
        hide()
        let frame = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let panel = NSPanel(
            contentRect: NSRect(x: frame.midX - 190, y: frame.maxY - 100, width: 380, height: 58),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(
            rootView:
                Label(message, systemImage: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium)).padding(16)
                .frame(maxWidth: .infinity).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)))
        panel.orderFrontRegardless()
        self.panel = panel
        let work = DispatchWorkItem { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.panel = nil
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 4 : 1.6), execute: work)
    }
}
