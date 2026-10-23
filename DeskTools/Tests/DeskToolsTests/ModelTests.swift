import Foundation
import NotesCore
import XCTest
@testable import EdgeNotes

final class NotesModelTests: XCTestCase {
    func testPhysicalCalculationTextAndOwnershipPersistThroughReopenAndBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("i will see 1 mm in m")
            let id = try XCTUnwrap(model.selected)
            let source = "i will see 1 mm in m（0.001 m）"
            let annotation = NoteCalculationAnnotation(location: 20, text: "（0.001 m）")
            model.updateDraft(id, source, calculationAnnotations: [annotation])
            XCTAssertTrue(model.flush())
            let reopened = NotesModel(directory: directory)
            reopened.select(id)
            XCTAssertEqual(reopened.draft, source)
            XCTAssertEqual(reopened.draftCalculationAnnotations, [annotation])
            let exported = try NotesDocument.decode(try XCTUnwrap(model.repository).exportData())
            XCTAssertEqual(exported.notes[0].text, source)
            XCTAssertEqual(exported.notes[0].calculationAnnotations, [annotation])
            XCTAssertEqual(
                NoteCalculationText.input(reopened.draft, annotations: reopened.draftCalculationAnnotations),
                "i will see 1 mm in m")
        }
    }
    func testFailedSaveKeepsDraftAndPreventsSwitching() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("saved")
            let id = try XCTUnwrap(model.selected)
            model.draft = String(repeating: "x", count: 1_000_001)
            XCTAssertFalse(model.flush())
            model.select(nil)
            XCTAssertEqual(model.selected, id)
            XCTAssertEqual(model.draft.count, 1_000_001)
            model.newNote("should not be created")
            XCTAssertEqual(model.document.notes.count, 1)
            XCTAssertEqual(try NotesRepository(directory: directory).document.notes[0].text, "saved")
            model.draft = "recovered 日本語"
            XCTAssertTrue(model.flush())
            XCTAssertEqual(try NotesRepository(directory: directory).document.notes[0].text, model.draft)
        }
    }
}
