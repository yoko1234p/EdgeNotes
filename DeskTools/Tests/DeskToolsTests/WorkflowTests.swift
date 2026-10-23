import AppKit
import Foundation
import NotesCore
import XCTest
@testable import EdgeNotes

final class WorkflowTests: XCTestCase {

    func testChecklistTogglePreservesOtherLinesAndTrailingNewline() {
        let original = "見出し\n  - [ ] 買咖啡\n- [X] Done\n"
        let toggled = NoteChecklist.toggle(original, line: 1)
        XCTAssertEqual(toggled, "見出し\n  - [x] 買咖啡\n- [X] Done\n")
        XCTAssertEqual(NoteChecklist.toggle(toggled, line: 1), original)
        XCTAssertEqual(NoteChecklist.toggle(original, line: 2), "見出し\n  - [ ] 買咖啡\n- [ ] Done\n")
        XCTAssertEqual(NoteChecklist.toggle(original, line: -1), original)
        XCTAssertEqual(NoteChecklist.toggle(original, line: 0), original)
    }

    func testLegacyNotesDecodeWithoutPresentationFields() throws {
        var document = NotesDocument()
        document.notes = [DeskNote(folderID: document.folders[0].id, text: "legacy")]
        let encoded = try JSONEncoder().encode(document)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var notes = try XCTUnwrap(object["notes"] as? [[String: Any]])
        for key in ["color", "folded", "order"] { notes[0].removeValue(forKey: key) }
        object["notes"] = notes
        let decoded = try NotesDocument.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, document)
        XCTAssertNil(decoded.notes[0].color)
        XCTAssertNil(decoded.notes[0].folded)
    }

    func testInlineEditingAndPresentationRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("one")
            let first = try XCTUnwrap(model.selected)
            model.newNote("two")
            let second = try XCTUnwrap(model.selected)
            let order = model.visible.map(\.id)
            model.updateDraft(first, "edited inline")
            XCTAssertTrue(model.flush())
            XCTAssertEqual(model.visible.map(\.id), order, "Autosave must not move a card while typing")
            model.change(first) {
                $0.color = "blue"
                $0.folded = true
                $0.pinned = true
            }
            XCTAssertEqual(model.visible.first?.id, first)
            model.change(first) { $0.pinned = false }
            model.move(first, before: second)
            XCTAssertEqual(model.visible.map(\.id), [first, second])
            let saved = try NotesRepository(directory: directory).document.notes.first { $0.id == first }
            XCTAssertEqual(saved?.text, "edited inline")
            XCTAssertEqual(saved?.color, "blue")
            XCTAssertEqual(saved?.folded, true)
        }
    }

    func testOrganizingAnotherCardKeepsCurrentEditorSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("other card")
            let other = try XCTUnwrap(model.selected)
            model.newNote("current card")
            let current = try XCTUnwrap(model.selected)
            model.updateDraft(current, "draft being edited")
            model.change(other) {
                $0.color = "blue"
                $0.folded = true
            }
            XCTAssertEqual(model.selected, current)
            XCTAssertEqual(model.draft, "draft being edited")
            XCTAssertEqual(model.document.notes.first { $0.id == other }?.color, "blue")
            XCTAssertEqual(
                try NotesRepository(directory: directory).document.notes.first { $0.id == current }?.text,
                "draft being edited")
        }
    }
}
