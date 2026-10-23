import ServiceManagement
import XCTest

@testable import EdgeNotes

final class NotesLoginItemTests: XCTestCase {
    func testEnableAndDisableReflectActualServiceState() async {
        await MainActor.run {
            var state = SMAppService.Status.notRegistered
            let item = NotesLoginItem(
                readStatus: { state }, register: { state = .enabled }, unregister: { state = .notRegistered })
            item.setEnabled(true)
            XCTAssertTrue(item.isRegistered)
            XCTAssertEqual(item.status, .enabled)
            item.setEnabled(false)
            XCTAssertFalse(item.isRegistered)
            XCTAssertEqual(item.status, .notRegistered)
        }
    }

    func testRejectedRegistrationDoesNotClaimStartupIsEnabled() async {
        await MainActor.run {
            let item = NotesLoginItem(
                readStatus: { .notRegistered }, register: { throw NSError(domain: "Fixture", code: 1) })
            item.setEnabled(true)
            XCTAssertFalse(item.isRegistered)
            XCTAssertEqual(item.status, .notRegistered)
            XCTAssertFalse(item.error.isEmpty)
        }
    }

    func testFailedRemovalPreservesRegisteredStateAndReportsError() async {
        await MainActor.run {
            let item = NotesLoginItem(
                readStatus: { .enabled }, unregister: { throw NSError(domain: "Fixture", code: 2) })
            item.setEnabled(false)
            XCTAssertTrue(item.isRegistered)
            XCTAssertEqual(item.status, .enabled)
            XCTAssertFalse(item.error.isEmpty)
        }
    }

    func testPendingApprovalHasRecoveryAndCanBeRemoved() async {
        await MainActor.run {
            var state = SMAppService.Status.notRegistered
            var openedSettings = false
            let item = NotesLoginItem(
                readStatus: { state }, register: { state = .requiresApproval },
                unregister: { state = .notRegistered }, openSettings: { openedSettings = true })
            item.setEnabled(true)
            XCTAssertTrue(item.isRegistered)
            XCTAssertEqual(item.status, .requiresApproval)
            XCTAssertTrue(item.summary.contains("系統設定允許 EdgeNotes"))
            item.showSettings()
            XCTAssertTrue(openedSettings)
            item.setEnabled(false)
            XCTAssertFalse(item.isRegistered)
        }
    }

    func testRefreshReflectsSystemChangesAndDoesNotRegisterAgain() async {
        await MainActor.run {
            var state = SMAppService.Status.enabled
            var calls = 0
            let item = NotesLoginItem(readStatus: { state }, register: { calls += 1 })
            item.setEnabled(true)
            XCTAssertEqual(calls, 0)
            state = .requiresApproval
            item.refresh()
            XCTAssertEqual(item.status, .requiresApproval)
            item.setEnabled(true)
            XCTAssertEqual(calls, 0)
            state = .notRegistered
            item.refresh()
            XCTAssertFalse(item.isRegistered)
        }
    }

    func testReadingUnavailableServiceNeverMutatesRegistration() async {
        await MainActor.run {
            var calls = 0
            let item = NotesLoginItem(
                readStatus: { .notFound }, register: { calls += 1 }, unregister: { calls += 1 })
            XCTAssertFalse(item.isRegistered)
            XCTAssertTrue(item.summary.contains("已安裝的 App"))
            item.refresh()
            XCTAssertEqual(calls, 0)
        }
    }
}
