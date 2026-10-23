import Foundation
import LocalWorkflowKit
import NotesCore
import XCTest
@testable import EdgeNotes

@MainActor final class NotesWorkflowTests: XCTestCase {
    private func fixture() -> (NotesModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (NotesModel(directory: root), root)
    }
    func testFavoriteCollectionPreservesOtherDraftAndIsIdempotent() throws {
        let (model, _) = fixture()
        model.newNote("Destination")
        let destination = try XCTUnwrap(model.selectedNote)
        model.toggleFavorite(destination)
        model.newNote("Current note")
        let current = model.selected
        model.draft = "Unflushed current note"
        let request = WorkflowDraft(kind: .note, text: "Collected #日本語", source: .init(application: "fixture", url: "https://example.test/owned"), targetNoteID: destination.id)
        let file = try WorkflowFiles.writeDraft(request, in: model.workflowDirectory)
        model.receive(file)
        XCTAssertEqual(model.selected, current)
        XCTAssertEqual(model.draft, "Unflushed current note")
        let saved = try XCTUnwrap(model.document.notes.first { $0.id == destination.id })
        XCTAssertEqual(saved.text, "Destination\n\nCollected #日本語")
        XCTAssertEqual(saved.collectionSources?.first?.source?.url, "https://example.test/owned")
        XCTAssertEqual(model.tags(for: saved), ["日本語"])
        XCTAssertTrue(model.incomingTexts.isEmpty)
        model.receive(file)
        XCTAssertEqual(model.document.notes.first { $0.id == destination.id }?.text, saved.text)
        let catalog = try WorkflowFiles.destinations(in: model.workflowDirectory)
        XCTAssertEqual(catalog.notes.map(\.id), [destination.id])
        let encoded = try String(contentsOf: model.workflowDirectory.appendingPathComponent("edgenotes-destinations.json"), encoding: .utf8)
        XCTAssertFalse(encoded.contains("Collected"))
    }
    func testMissingFavoriteKeepsRequestAndQueueSurvivesRestart() throws {
        let (model, root) = fixture()
        let draft = WorkflowDraft(kind: .note, text: "Keep this", targetNoteID: UUID())
        let file = try WorkflowFiles.writeDraft(draft, in: model.workflowDirectory)
        model.receive(file)
        XCTAssertEqual(model.incoming?.id, draft.id)
        XCTAssertFalse(model.incomingError.isEmpty)
        let reopened = NotesModel(directory: root)
        XCTAssertEqual(reopened.incoming?.text, draft.text)
        XCTAssertEqual(reopened.incoming?.targetNoteID, draft.targetNoteID)
        XCTAssertTrue(reopened.saveIncoming(draft.id, folderID: reopened.activeFolders.first?.id, noteID: nil))
        XCTAssertEqual(reopened.selectedNote?.text, draft.text)
    }
    func testCorruptPendingAndTemplatesAreNeverOverwritten() throws {
        let (_, root) = fixture()
        let pending = root.appendingPathComponent("pending-collections.json")
        let templates = root.appendingPathComponent("templates.json")
        let invalid = Data("future invalid data".utf8)
        try invalid.write(to: pending); try invalid.write(to: templates)
        let reopened = NotesModel(directory: root)
        let file = try WorkflowFiles.writeDraft(.init(kind: .note, text: "new"), in: reopened.workflowDirectory)
        reopened.receive(file)
        reopened.saveTemplate(name: "test", text: "new")
        XCTAssertEqual(try Data(contentsOf: pending), invalid)
        XCTAssertEqual(try Data(contentsOf: templates), invalid)
        XCTAssertTrue(reopened.incomingTexts.isEmpty)
        XCTAssertNotNil(reopened.incomingStorageError)
        XCTAssertFalse(reopened.templateError.isEmpty)
    }
    func testTemplatesAndUnicodeTagsWorkWithoutChangingImageResources() throws {
        let (model, root) = fixture()
        model.saveTemplate(name: "Daily", text: "{{date}} {{time}} {{title}}\n#工作 #EN #工作")
        let reopened = NotesModel(directory: root)
        let template = try XCTUnwrap(reopened.customTemplates.first)
        XCTAssertEqual(template.render(at: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!), "1970-01-01 00:00 Daily\n#工作 #EN #工作")
        reopened.newNote(template.render())
        XCTAssertEqual(reopened.tags(for: try XCTUnwrap(reopened.selectedNote)), ["工作", "en"])
        reopened.search = "#工作"
        XCTAssertEqual(reopened.visible.count, 1)
        reopened.search = "#工"
        XCTAssertTrue(reopened.visible.isEmpty)
    }
}
