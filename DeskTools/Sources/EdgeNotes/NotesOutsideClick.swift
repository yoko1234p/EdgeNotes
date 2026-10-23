import CoreGraphics

enum NotesOutsideClickPolicy {
    enum Source {
        case ownApplication
        case otherApplication
    }

    static func shouldDismiss(
        at point: CGPoint, source: Source, isShown: Bool, pinned: Bool, blocksDismissal: Bool,
        protectedFrames: [CGRect]
    ) -> Bool {
        guard isShown, !pinned, !blocksDismissal else { return false }
        // Global monitors receive another application's clicks. Its window may
        // overlap the sidebar, so geometry alone cannot identify an inside click.
        if source == .otherApplication { return true }
        return !protectedFrames.contains { $0.contains(point) }
    }
}
