import CoreGraphics
import NotesCore
import XCTest

@testable import EdgeNotes

final class NotesOutsideClickTests: XCTestCase {
    private let panel = CGRect(x: 1080, y: 52, width: 360, height: 800)

    private func dismiss(
        _ point: CGPoint, source: NotesOutsideClickPolicy.Source = .ownApplication,
        isShown: Bool = true, pinned: Bool = false, blocked: Bool = false, additionalFrames: [CGRect] = []
    ) -> Bool {
        NotesOutsideClickPolicy.shouldDismiss(
            at: point, source: source, isShown: isShown, pinned: pinned, blocksDismissal: blocked,
            protectedFrames: [panel] + additionalFrames)
    }

    func testClickWithinNoteOrFolderSurfaceKeepsSidebarOpen() {
        XCTAssertFalse(dismiss(CGPoint(x: 1200, y: 400)))
        XCTAssertFalse(dismiss(CGPoint(x: 1080, y: 52)))
        XCTAssertTrue(dismiss(CGPoint(x: 1079, y: 400)))
        XCTAssertTrue(dismiss(CGPoint(x: 1200, y: 51)))
    }

    func testBackgroundAndOtherApplicationClicksDismissRegardlessOfApplicationDeactivation() {
        let outside = CGPoint(x: 500, y: 400)
        XCTAssertTrue(dismiss(outside))
        XCTAssertTrue(dismiss(outside, source: .otherApplication))
        // A foreground application's popup may cover the visible note panel.
        XCTAssertTrue(dismiss(CGPoint(x: 1200, y: 400), source: .otherApplication))
    }

    func testPhysicalEdgeOpenersAndStatusButtonRetainTheirToggleActions() {
        let controls = [
            CGRect(x: 1430, y: 405, width: 10, height: 88),
            CGRect(x: -1920, y: 405, width: 10, height: 88),
            CGRect(x: 600, y: 875, width: 24, height: 24),
        ]
        for control in controls {
            XCTAssertFalse(dismiss(CGPoint(x: control.minX, y: control.midY), additionalFrames: controls))
        }
        XCTAssertTrue(dismiss(CGPoint(x: 599, y: 887), additionalFrames: controls))
    }

    func testNativeSettingsPopoverOutsideSidebarCountsAsInside() {
        let popover = CGRect(x: 740, y: 30, width: 330, height: 366)
        XCTAssertFalse(dismiss(CGPoint(x: 900, y: 180), additionalFrames: [popover]))
        XCTAssertTrue(dismiss(CGPoint(x: 730, y: 180), additionalFrames: [popover]))
        XCTAssertTrue(dismiss(CGPoint(x: 900, y: 180), source: .otherApplication, additionalFrames: [popover]))
    }

    func testPinnedOrHiddenSidebarIgnoresOutsideClicks() {
        for source in [NotesOutsideClickPolicy.Source.ownApplication, .otherApplication] {
            XCTAssertFalse(dismiss(.zero, source: source, pinned: true))
            XCTAssertFalse(dismiss(.zero, source: source, isShown: false))
        }
    }

    func testModalTextCompositionResizeOrTrackedMenuBlocksDismissal() {
        for source in [NotesOutsideClickPolicy.Source.ownApplication, .otherApplication] {
            XCTAssertFalse(dismiss(.zero, source: source, blocked: true))
        }
    }

    func testOutsideDismissalUsesSaveGuardAndDoesNotRestorePreviousApp() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: 200, ownApplication: 100)
        XCTAssertTrue(dismiss(.zero, source: .otherApplication))
        XCTAssertNil(workflow.hide(reason: .deactivation, saved: false))
        XCTAssertTrue(workflow.isShown)
        let hidden = try XCTUnwrap(workflow.hide(reason: .deactivation, saved: true))
        XCTAssertFalse(workflow.isShown)
        XCTAssertNil(workflow.restorationTarget(for: hidden, frontmostApplication: 100, ownApplication: 100))
        XCTAssertNil(workflow.restorationTarget(for: hidden, frontmostApplication: 300, ownApplication: 100))
    }
}
