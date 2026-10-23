import CoreGraphics
import Foundation
import NotesCore
import XCTest

final class EdgePanelWorkflowTests: XCTestCase {
    private let own: Int32 = 100
    private let editor: Int32 = 200
    private let browser: Int32 = 300

    func testManualDismissalReturnsFocusOnlyWhileNotesStillOwnsIt() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        let hide = try XCTUnwrap(workflow.hide(reason: .manual, saved: true))
        XCTAssertEqual(workflow.restorationTarget(for: hide, frontmostApplication: own, ownApplication: own), editor)
        XCTAssertNil(workflow.restorationTarget(for: hide, frontmostApplication: browser, ownApplication: own))
        XCTAssertNil(workflow.restorationTarget(for: hide, frontmostApplication: nil, ownApplication: own))
        XCTAssertNil(workflow.returnApplication)
    }

    func testDeactivationNeverReactivatesPreviousApplication() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        let hide = try XCTUnwrap(workflow.hide(reason: .deactivation, saved: true))
        XCTAssertFalse(workflow.isShown)
        XCTAssertNil(workflow.restorationTarget(for: hide, frontmostApplication: own, ownApplication: own))
        XCTAssertNil(workflow.restorationTarget(for: hide, frontmostApplication: browser, ownApplication: own))
    }

    func testPinProtectsAutomaticHideAndStillAllowsManualDismissal() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        let revision = workflow.revision
        XCTAssertNil(workflow.hide(reason: .deactivation, saved: true, pinned: true))
        XCTAssertTrue(workflow.isShown)
        XCTAssertEqual(workflow.revision, revision)
        XCTAssertEqual(workflow.returnApplication, editor)
        XCTAssertNotNil(workflow.hide(reason: .manual, saved: true, pinned: true))
    }

    func testFailedSaveAndTextCompositionKeepPanelAndReturnFocusState() {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        let revision = workflow.revision
        XCTAssertNil(workflow.hide(reason: .manual, saved: false))
        XCTAssertNil(workflow.hide(reason: .deactivation, saved: true, blocksDismissal: true))
        XCTAssertTrue(workflow.isShown)
        XCTAssertEqual(workflow.revision, revision)
        XCTAssertEqual(workflow.returnApplication, editor)
    }

    func testRapidShowHideShowMakesOldHideCompletionHarmless() throws {
        var workflow = EdgePanelWorkflow()
        let firstShow = workflow.show(frontmostApplication: editor, ownApplication: own)
        let oldHide = try XCTUnwrap(workflow.hide(reason: .manual, saved: true))
        let lastShow = workflow.show(frontmostApplication: browser, ownApplication: own)
        XCTAssertFalse(workflow.isCurrent(firstShow))
        XCTAssertFalse(workflow.isCurrent(oldHide))
        XCTAssertTrue(workflow.isCurrent(lastShow))
        XCTAssertTrue(workflow.isShown)
        XCTAssertNil(workflow.restorationTarget(for: oldHide, frontmostApplication: own, ownApplication: own))
        let finalHide = try XCTUnwrap(workflow.hide(reason: .manual, saved: true))
        XCTAssertEqual(
            workflow.restorationTarget(for: finalHide, frontmostApplication: own, ownApplication: own), browser)
    }

    func testReopeningFromNotesDoesNotCarryOldReturnApplication() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        _ = workflow.hide(reason: .manual, saved: true)
        workflow.show(frontmostApplication: own, ownApplication: own)
        let hide = try XCTUnwrap(workflow.hide(reason: .manual, saved: true))
        XCTAssertNil(workflow.restorationTarget(for: hide, frontmostApplication: own, ownApplication: own))
        XCTAssertNil(workflow.hide(reason: .manual, saved: true))
    }

    func testRepeatedShowKeepsOriginalReturnApplicationWhileEditing() {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        workflow.show(frontmostApplication: own, ownApplication: own)
        XCTAssertEqual(workflow.returnApplication, editor)
    }

    func testGeometryChangeInvalidatesAnimationCompletion() throws {
        var workflow = EdgePanelWorkflow()
        workflow.show(frontmostApplication: editor, ownApplication: own)
        let hide = try XCTUnwrap(workflow.hide(reason: .manual, saved: true))
        let positioned = workflow.refreshGeometry()
        XCTAssertFalse(workflow.isCurrent(hide))
        XCTAssertTrue(workflow.isCurrent(positioned))
        XCTAssertFalse(workflow.isShown)
    }

    private var displays: [EdgePanelDisplay] {
        [
            EdgePanelDisplay(
                id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 830)),
            EdgePanelDisplay(
                id: 2, frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
                visibleFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1050)),
        ]
    }

    func testNewInvocationFollowsPointerAndOpenEditorKeepsDisplay() {
        let pointer = CGPoint(x: -500, y: 100)
        XCTAssertEqual(
            EdgePanelPlacement.displayID(
                explicit: nil, anchor: 1, isShown: false, pointer: pointer, displays: displays), 2)
        XCTAssertEqual(
            EdgePanelPlacement.displayID(explicit: nil, anchor: 1, isShown: true, pointer: pointer, displays: displays),
            1)
        XCTAssertEqual(
            EdgePanelPlacement.displayID(explicit: 2, anchor: 1, isShown: true, pointer: .zero, displays: displays), 2)
    }

    func testDisconnectedDisplayFallsBackToAvailableDisplay() {
        let remaining = Array(displays.prefix(1))
        XCTAssertEqual(
            EdgePanelPlacement.displayID(
                explicit: 2, anchor: 2, isShown: true, pointer: CGPoint(x: -500, y: 100), displays: remaining), 1)
        XCTAssertNil(
            EdgePanelPlacement.displayID(explicit: nil, anchor: nil, isShown: false, pointer: .zero, displays: []))
    }

    func testOpenBarUsesPhysicalEdgesWhenDockReservesVisibleSpace() {
        let frame = CGRect(x: -1920, y: -180, width: 1920, height: 1080)
        let visible = CGRect(x: -1860, y: -180, width: 1780, height: 1050)
        let display = EdgePanelDisplay(id: 2, frame: frame, visibleFrame: visible)
        let left = EdgePanelPlacement.openBarFrame(display: display, side: .left)
        let right = EdgePanelPlacement.openBarFrame(display: display, side: .right)
        XCTAssertEqual(left.minX, frame.minX)
        XCTAssertEqual(right.maxX, frame.maxX)
        XCTAssertNotEqual(left.minX, visible.minX)
        XCTAssertNotEqual(right.maxX, visible.maxX)
        XCTAssertEqual(left.midY, visible.midY)
        XCTAssertEqual(right.size, CGSize(width: 10, height: 88))
    }

    func testAutomaticHeightFitsEachDisplayInsteadOfKeepingPreviousShorterHeight() {
        let size = CGSize(width: 360, height: 760)
        for visible in [
            CGRect(x: 0, y: 40, width: 1440, height: 830),
            CGRect(x: -1920, y: -180, width: 1920, height: 1370),
        ] {
            let automatic = EdgePanelPlacement.shownFrame(
                size: size, visibleFrame: visible, side: .right, fillHeight: true)
            XCTAssertEqual(automatic.height, visible.height - 24)
            XCTAssertEqual(automatic.minY, visible.minY + 12)
            XCTAssertEqual(automatic.maxY, visible.maxY - 12)
            let manual = EdgePanelPlacement.shownFrame(
                size: size, visibleFrame: visible, side: .right, fillHeight: false)
            XCTAssertEqual(manual.height, 760)
        }
    }

    func testPanelFitsSmallVisibleFrameOnEitherEdge() {
        let visible = CGRect(x: -1200, y: 80, width: 340, height: 420)
        for side in [EdgePanelSide.left, .right] {
            let frame = EdgePanelPlacement.shownFrame(
                size: CGSize(width: 900, height: 900), visibleFrame: visible, side: side)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.width, 340)
            XCTAssertEqual(frame.height, 396)
            XCTAssertEqual(frame.maxY, visible.maxY - 12)
        }
    }

    func testSlideEndsOutsideFullDisplayAndHoverRequiresCorrectEdge() {
        let display = displays[1]
        let shown = EdgePanelPlacement.shownFrame(
            size: CGSize(width: 400, height: 760), visibleFrame: display.visibleFrame, side: .right)
        let right = EdgePanelPlacement.hiddenFrame(shownFrame: shown, displayFrame: display.frame, side: .right)
        let left = EdgePanelPlacement.hiddenFrame(shownFrame: shown, displayFrame: display.frame, side: .left)
        XCTAssertGreaterThan(right.minX, display.frame.maxX)
        XCTAssertLessThan(left.maxX, display.frame.minX)
        XCTAssertTrue(EdgePanelPlacement.isAtEdge(CGPoint(x: -1, y: 100), display: display, side: .right))
        XCTAssertFalse(EdgePanelPlacement.isAtEdge(CGPoint(x: -1, y: 100), display: display, side: .left))
        XCTAssertFalse(EdgePanelPlacement.isAtEdge(CGPoint(x: -1, y: -300), display: display, side: .right))
    }
}
