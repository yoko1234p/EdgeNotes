import AppKit
import CoreImage
import Darwin
import DeskCore
import NotesCore
import Vision
import XCTest

final class NotesTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRoundTripAndRestoreWithAttachment() throws {
        let repository = try NotesRepository(directory: temporaryDirectory())
        var document = repository.document
        var note = DeskNote(folderID: document.folders[0].id, text: "日本語 👋\n- [ ] task")
        note.attachments = [NoteAttachment(name: "test.txt", data: Data("attachment".utf8))]
        document.notes.append(note)
        try repository.commit(document)
        let reopened = try NotesRepository(directory: repository.directory)
        XCTAssertEqual(reopened.document, document)
        let restored = try NotesRepository(directory: temporaryDirectory())
        try restored.importData(reopened.exportData())
        XCTAssertEqual(restored.document.notes[0].text, note.text)
        XCTAssertEqual(restored.document.notes[0].attachments, note.attachments)
        try restored.importData(reopened.exportData())
        XCTAssertEqual(restored.document.notes.count, 1)
    }
    func testInvalidTransactionDoesNotOverwriteStore() throws {
        let repository = try NotesRepository(directory: temporaryDirectory())
        try repository.commit(repository.document)
        let before = try repository.exportData()
        var invalid = repository.document
        invalid.notes = [DeskNote(folderID: UUID(), text: "bad")]
        XCTAssertThrowsError(try repository.commit(invalid))
        XCTAssertEqual(repository.document.notes.count, 0)
        XCTAssertEqual(try NotesDocument.decode(before), try NotesRepository(directory: repository.directory).document)
    }
    func testDamagedStoreIsNotReplaced() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("notes.json")
        let original = Data("broken".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try NotesRepository(directory: directory))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testConflictingImportPreservesBothVersions() throws {
        let repository = try NotesRepository(directory: temporaryDirectory())
        var document = repository.document
        document.notes = [DeskNote(folderID: document.folders[0].id, text: "before")]
        try repository.commit(document)
        let backup = try repository.exportData()
        document.notes[0].text = "after"
        try repository.commit(document)
        try repository.importData(backup)
        XCTAssertEqual(Set(repository.document.notes.map(\.text)), ["before", "after"])
        XCTAssertEqual(Set(repository.document.notes.map(\.id)).count, 2)
        try repository.importData(backup)
        XCTAssertEqual(repository.document.notes.count, 2)
    }
    func testTrashSurvivesRestartAndSnapshotsAreBounded() throws {
        let repository = try NotesRepository(directory: temporaryDirectory())
        var document = repository.document
        document.notes = [DeskNote(folderID: document.folders[0].id, text: "deleted")]
        document.notes[0].trashed = true
        for revision in 0..<8 {
            document.notes[0].text = "deleted revision \(revision)"
            try repository.commit(document)
        }
        XCTAssertTrue(try NotesRepository(directory: repository.directory).document.notes[0].trashed)
        let snapshots = try FileManager.default.contentsOfDirectory(
            atPath: repository.directory.appendingPathComponent("Snapshots").path)
        XCTAssertEqual(snapshots.count, 5)
    }
    func testUnknownSchemaAndDuplicateIDsRejected() throws {
        var document = NotesDocument()
        document.schemaVersion = 99
        XCTAssertThrowsError(try document.validate())
        document.schemaVersion = 1
        let note = DeskNote(folderID: document.folders[0].id)
        document.notes = [note, note]
        XCTAssertThrowsError(try document.validate())
    }
    func testReaderRejectsSymlinkAndFIFO() throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("file")
        try Data("safe".utf8).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try BoundedFile.read(link, limit: 100))
        let fifo = directory.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try BoundedFile.read(fifo, limit: 100))
    }
}
