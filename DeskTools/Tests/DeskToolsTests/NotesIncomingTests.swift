import Foundation
import NotesCore
import XCTest

@testable import EdgeNotes

final class NotesIncomingTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func payload(_ text: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(UUID().uuidString + ".edgetext")
        try Data(text.utf8).write(to: file)
        return file
    }

    func testChosenFolderAndExistingNoteReceiveRequestsInOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try payload("第一段 日本語 한국어", in: directory)
        let second = try payload("第二段\n\"quotes\" $() & <tag>", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            let inbox = try XCTUnwrap(model.activeFolders.first?.id)
            model.addFolder("Work")
            let work = try XCTUnwrap(model.folder)
            model.newNote("Existing work note")
            let existing = try XCTUnwrap(model.selected)
            model.receive(first)
            let request = try XCTUnwrap(model.incoming)
            model.receive(second)
            XCTAssertEqual(model.incoming?.id, request.id)
            XCTAssertEqual(model.incomingTexts.count, 2)
            XCTAssertTrue(model.saveIncoming(request.id, folderID: inbox, noteID: nil))
            XCTAssertEqual(model.selectedNote?.text, request.text)
            XCTAssertEqual(model.selectedNote?.folderID, inbox)
            XCTAssertEqual(model.incoming?.text, try String(contentsOf: second, encoding: .utf8))
            XCTAssertTrue(model.saveIncoming(try XCTUnwrap(model.incoming?.id), folderID: work, noteID: existing))
            XCTAssertEqual(model.document.notes.count, 2)
            XCTAssertEqual(model.selected, existing)
            XCTAssertEqual(model.folder, work)
            XCTAssertEqual(model.draft, "Existing work note\n\n" + (try String(contentsOf: second, encoding: .utf8)))
            XCTAssertTrue(model.incomingTexts.isEmpty)
            XCTAssertTrue(model.flush())
            XCTAssertEqual(try NotesRepository(directory: directory.appendingPathComponent("store")).document, model.document)
        }
    }

    func testAppendingFlushesDraftAndPreservesAttachmentsAndCalculationOwnership() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Added text", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            model.newNote("1 mm in m（0.001 m）")
            let note = try XCTUnwrap(model.selected)
            let annotation = NoteCalculationAnnotation(location: 9, text: "（0.001 m）")
            let attachment = NoteAttachment(name: "image.png", data: Data("kept attachment".utf8))
            model.change {
                $0.attachments = [attachment]
                $0.pinned = true
                $0.color = "blue"
                $0.folded = true
            }
            model.updateDraft(note, model.draft, calculationAnnotations: [annotation])
            XCTAssertEqual(model.draftCalculationAnnotations, [annotation])
            model.draft += "\nUnflushed draft"
            let expected = model.draft + "\n\nAdded text"
            model.receive(file)
            XCTAssertTrue(model.saveIncoming(try XCTUnwrap(model.incoming?.id), folderID: model.folder, noteID: note))
            XCTAssertEqual(model.draft, expected)
            XCTAssertEqual(model.selectedNote?.text, expected)
            XCTAssertEqual(model.selectedNote?.attachments, [attachment])
            XCTAssertEqual(model.selectedNote?.calculationAnnotations, [annotation])
            XCTAssertEqual(model.selectedNote?.pinned, true)
            XCTAssertEqual(model.selectedNote?.color, "blue")
            XCTAssertEqual(model.selectedNote?.folded, false)
            XCTAssertTrue(model.flush())
            XCTAssertEqual(try NotesRepository(directory: directory.appendingPathComponent("store")).document, model.document)
        }
    }

    func testAppendByteLimitKeepsTextForRetryAsNewNote() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("あ", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            let original = String(repeating: "字", count: 333_333)
            model.newNote(original)
            let folder = model.folder
            let note = model.selected
            model.receive(file)
            let request = try XCTUnwrap(model.incoming?.id)
            XCTAssertFalse(model.saveIncoming(request, folderID: folder, noteID: note))
            XCTAssertEqual(model.selectedNote?.text, original)
            XCTAssertEqual(model.incoming?.id, request)
            XCTAssertTrue(model.incomingError.contains("1 MB"))
            XCTAssertTrue(model.saveIncoming(request, folderID: folder, noteID: nil))
            XCTAssertEqual(model.document.notes.count, 2)
            XCTAssertEqual(model.selectedNote?.text, "あ")
        }
    }

    func testInvalidMovedAndDeletedDestinationsNeverFallBackToAnotherNote() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Incoming", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            model.newNote("Original")
            let inbox = try XCTUnwrap(model.folder)
            let note = try XCTUnwrap(model.selected)
            model.addFolder("Other")
            let other = try XCTUnwrap(model.folder)
            model.receive(file)
            let request = try XCTUnwrap(model.incoming?.id)
            XCTAssertFalse(model.saveIncoming(request, folderID: UUID(), noteID: note))
            XCTAssertFalse(model.saveIncoming(request, folderID: other, noteID: note))
            model.change(note) { $0.trashed = true }
            XCTAssertTrue(model.notesForImport(in: inbox).isEmpty)
            XCTAssertFalse(model.saveIncoming(request, folderID: inbox, noteID: note))
            XCTAssertTrue(model.deleteFolder(inbox))
            XCTAssertFalse(model.saveIncoming(request, folderID: inbox, noteID: nil))
            XCTAssertEqual(model.document.notes.count, 1)
            XCTAssertEqual(model.document.notes[0].text, "Original")
            XCTAssertEqual(model.incoming?.id, request)
        }
    }

    func testDraftSaveFailurePreventsImportAndPreservesBothDraftAndRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Incoming", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            model.newNote("Destination")
            let target = model.selected
            model.newNote("Editing")
            let editing = model.selected
            model.draft = String(repeating: "x", count: 1_000_001)
            model.receive(file)
            let request = try XCTUnwrap(model.incoming?.id)
            XCTAssertFalse(model.saveIncoming(request, folderID: model.folder, noteID: target))
            XCTAssertEqual(model.selected, editing)
            XCTAssertEqual(model.draft.utf8.count, 1_000_001)
            XCTAssertEqual(model.document.notes.first { $0.id == target }?.text, "Destination")
            XCTAssertEqual(model.incoming?.id, request)
            model.draft = "Recovered draft"
            XCTAssertTrue(model.saveIncoming(request, folderID: model.folder, noteID: target))
            XCTAssertEqual(model.draft, "Destination\n\nIncoming")
            XCTAssertEqual(model.document.notes.first { $0.id == editing }?.text, "Recovered draft")
        }
    }

    func testCommitFailureKeepsPendingTextAndDestinationUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Incoming", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            model.newNote("Original")
            model.receive(file)
            let request = try XCTUnwrap(model.incoming?.id)
            let original = model.document
            model.repository = nil
            XCTAssertFalse(model.saveIncoming(request, folderID: model.folder, noteID: model.selected))
            XCTAssertEqual(model.document, original)
            XCTAssertEqual(model.draft, "Original")
            XCTAssertEqual(model.incoming?.id, request)
            XCTAssertFalse(model.incomingError.isEmpty)
        }
    }

    func testQueueLimitAndCancellationPreserveEarlierRequestsAndRejectStaleSave() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Incoming", in: directory)
        await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            for _ in 0..<20 { model.receive(file) }
            let requests = model.incomingTexts.map(\.id)
            model.receive(file)
            XCTAssertEqual(model.incomingTexts.map(\.id), requests)
            XCTAssertFalse(model.incomingError.isEmpty)
            model.cancelIncoming()
            XCTAssertEqual(model.incoming?.id, requests[1])
            XCTAssertFalse(model.saveIncoming(requests[0], folderID: model.activeFolders.first?.id, noteID: nil))
            XCTAssertTrue(model.document.notes.isEmpty)
            XCTAssertEqual(model.incomingTexts.count, 19)
            model.receive(file)
            XCTAssertEqual(model.incomingTexts.count, 20)
            XCTAssertEqual(model.incoming?.id, requests[1])
        }
    }

    func testQueueByteBudgetRejectsNewPayloadWithoutReplacingEarlierText() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload(String(repeating: "a", count: 1_000_000), in: directory)
        await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            for _ in 0..<8 { model.receive(file) }
            let requests = model.incomingTexts.map(\.id)
            model.receive(file)
            XCTAssertEqual(model.incomingTexts.map(\.id), requests)
            XCTAssertEqual(model.incomingTexts.count, 8)
            XCTAssertFalse(model.incomingError.isEmpty)
        }
    }

    func testDeletedLastFolderCanReceiveNewNoteInNewInbox() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try payload("Incoming", in: directory)
        try await MainActor.run {
            let model = NotesModel(directory: directory.appendingPathComponent("store"))
            let deleted = try XCTUnwrap(model.activeFolders.first?.id)
            XCTAssertTrue(model.deleteFolder(deleted))
            model.receive(file)
            XCTAssertTrue(model.saveIncoming(try XCTUnwrap(model.incoming?.id), folderID: nil, noteID: nil))
            XCTAssertEqual(model.activeFolders.count, 1)
            XCTAssertNotEqual(model.folder, deleted)
            XCTAssertEqual(model.selectedNote?.text, "Incoming")
            try model.document.validate()
        }
    }
}
