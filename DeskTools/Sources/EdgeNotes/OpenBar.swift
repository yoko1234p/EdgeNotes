import AppKit
import DeskCore
import NotesCore

@MainActor final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class OpenBarPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Always reachable at a fixed display edge; does not activate the app until clicked.
@MainActor final class OpenBarView: NSView {
    let activate: () -> Void
    let changeSide: () -> Void
    let side: EdgePanelSide
    private var hovered = false
    init(side: EdgePanelSide = .right, activate: @escaping () -> Void, changeSide: @escaping () -> Void) {
        self.side = side
        self.activate = activate
        self.changeSide = changeSide
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 88))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L10n.text("EdgeNotes 邊緣入口"))
        setAccessibilityIdentifier("notes.openbar")
        toolTip = L10n.text("開啟／收起 EdgeNotes · ⌃⇧N")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        // Give the complete control a hit surface, including the transparent
        // rounded corners. A clear pixel at the display edge lets resize hits
        // fall through to the window behind this entry.
        NSColor.black.withAlphaComponent(0.01).setFill()
        NSBezierPath(rect: bounds).fill()
        (hovered ? NSColor.systemOrange : NSColor.secondaryLabelColor.withAlphaComponent(0.65)).setFill()
        var shape = bounds.insetBy(dx: 2, dy: 4)
        if side == .left { shape.origin.x -= 4 }
        shape.size.width += 4
        NSBezierPath(roundedRect: shape, xRadius: 3, yRadius: 3).fill()
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { activate() }
    override func mouseUp(with event: NSEvent) {}
    override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let item = NSMenuItem(title: L10n.text("移到另一邊"), action: #selector(switchSide), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func switchSide() { changeSide() }
}
