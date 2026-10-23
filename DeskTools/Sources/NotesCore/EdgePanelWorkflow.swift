import CoreGraphics
import Foundation

public enum EdgePanelDismissal: Sendable {
    case manual
    case deactivation
}

public struct EdgePanelTransition: Equatable, Sendable {
    public let id: UInt64
    public let isShown: Bool
    public let returnApplication: Int32?
}

/// Tracks requested visibility so a late animation cannot undo a newer request.
public struct EdgePanelWorkflow: Sendable {
    public private(set) var isShown = false
    public private(set) var revision: UInt64 = 0
    public private(set) var returnApplication: Int32?

    public init() {}

    @discardableResult public mutating func show(
        frontmostApplication: Int32?, ownApplication: Int32
    ) -> EdgePanelTransition {
        if let frontmostApplication, frontmostApplication != ownApplication {
            returnApplication = frontmostApplication
        }
        isShown = true
        revision &+= 1
        return EdgePanelTransition(id: revision, isShown: true, returnApplication: nil)
    }

    /// Failed saves, sheets and text composition leave the current panel intact.
    public mutating func hide(
        reason: EdgePanelDismissal, saved: Bool, pinned: Bool = false, blocksDismissal: Bool = false
    ) -> EdgePanelTransition? {
        guard isShown, saved, !blocksDismissal, reason != .deactivation || !pinned else { return nil }
        let target = reason == .manual ? returnApplication : nil
        returnApplication = nil
        isShown = false
        revision &+= 1
        return EdgePanelTransition(id: revision, isShown: false, returnApplication: target)
    }

    @discardableResult public mutating func refreshGeometry() -> EdgePanelTransition {
        revision &+= 1
        return EdgePanelTransition(id: revision, isShown: isShown, returnApplication: nil)
    }

    public func isCurrent(_ transition: EdgePanelTransition) -> Bool {
        transition.id == revision && transition.isShown == isShown
    }

    /// Restore focus only while this app still owns it at the end of dismissal.
    public func restorationTarget(
        for transition: EdgePanelTransition, frontmostApplication: Int32?, ownApplication: Int32
    ) -> Int32? {
        guard isCurrent(transition), !isShown, frontmostApplication == ownApplication else { return nil }
        return transition.returnApplication
    }
}

public enum EdgePanelSide: String, Sendable {
    case left
    case right
}

public struct EdgePanelDisplay: Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum EdgePanelPlacement {
    /// Keep the opener at the physical display edge, even when a side Dock
    /// reserves space in visibleFrame. The expanded editor still uses that space.
    public static func openBarFrame(display: EdgePanelDisplay, side: EdgePanelSide) -> CGRect {
        CGRect(
            x: side == .left ? display.frame.minX : display.frame.maxX - 10,
            y: display.visibleFrame.midY - 44, width: 10, height: 88)
    }

    /// An explicit edge click selects its display. An open editor keeps its anchor;
    /// a new invocation follows the pointer, including displays with negative origins.
    public static func displayID(
        explicit: UInt32?, anchor: UInt32?, isShown: Bool, pointer: CGPoint, displays: [EdgePanelDisplay]
    ) -> UInt32? {
        let ids = Set(displays.map(\.id))
        if let explicit, ids.contains(explicit) { return explicit }
        if isShown, let anchor, ids.contains(anchor) { return anchor }
        if let display = displays.first(where: { $0.frame.contains(pointer) }) { return display.id }
        if let anchor, ids.contains(anchor) { return anchor }
        return displays.first?.id
    }

    public static func shownFrame(
        size: CGSize, visibleFrame: CGRect, side: EdgePanelSide, fillHeight: Bool = false
    ) -> CGRect {
        let margin = min(12, max(0, (visibleFrame.height - 1) / 2))
        let width = min(max(size.width, 360), max(1, visibleFrame.width))
        let availableHeight = max(1, visibleFrame.height - 2 * margin)
        let height = fillHeight ? availableHeight : min(max(size.height, 520), availableHeight)
        let x = side == .left ? visibleFrame.minX : visibleFrame.maxX - width
        return CGRect(x: x, y: visibleFrame.maxY - margin - height, width: width, height: height)
    }

    public static func hiddenFrame(shownFrame: CGRect, displayFrame: CGRect, side: EdgePanelSide) -> CGRect {
        var frame = shownFrame
        frame.origin.x = side == .left ? displayFrame.minX - frame.width - 16 : displayFrame.maxX + 16
        return frame
    }

    public static func isAtEdge(_ point: CGPoint, display: EdgePanelDisplay, side: EdgePanelSide) -> Bool {
        guard display.frame.contains(point) else { return false }
        return side == .left ? point.x <= display.frame.minX + 3 : point.x >= display.frame.maxX - 3
    }
}
