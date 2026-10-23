import Foundation
import NotesCore
import XCTest

final class NotesTrashTests: XCTestCase {
    func testEmptyTrashRemovesDeletedFoldersImagesAndSnapshotContentsButKeepsLiveNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotesRepository(directory: root)
        var source = repository.document
        let live = DeskNote(folderID: source.folders[0].id, text: "keep")
        var folder = NoteFolder(name: "deleted")
        source.folders.append(folder)
        var deleted = DeskNote(folderID: folder.id, text: "remove")
        deleted.attachments = [NoteAttachment(name: "image.png", data: Data([8, 9, 10]))]
        source.notes = [live, deleted]
        try repository.commit(source)
        source.notes[1].trashed = true
        source.notes[1].trashedWithFolder = true
        folder.trashed = true
        source.folders[1] = folder
        try repository.commit(source)
        try repository.emptyTrash()
        XCTAssertEqual(repository.document.notes, [live])
        XCTAssertEqual(repository.document.folders.count, 1)
        XCTAssertEqual(try NotesRepository(directory: root).document, repository.document)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Resources").path).isEmpty)
        for snapshot in try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Snapshots"), includingPropertiesForKeys: nil)
        {
            try repository.importSnapshot(at: snapshot)
            XCTAssertFalse(repository.document.notes.contains { $0.id == deleted.id })
        }
    }
    func testTrashWithNoLiveFolderLeavesValidInboxAndUnreadableSnapshotBlocksPurge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotesRepository(directory: root)
        var source = repository.document
        source.folders[0].trashed = true
        try repository.commit(source)
        try repository.emptyTrash()
        XCTAssertEqual(repository.document.folders.count, 1)
        XCTAssertNil(repository.document.folders[0].trashed)
        source = repository.document
        var note = DeskNote(folderID: source.folders[0].id, text: "retain on error")
        note.trashed = true
        source.notes = [note]
        try repository.commit(source)
        let damaged = root.appendingPathComponent("Snapshots/broken.json")
        try Data("broken".utf8).write(to: damaged)
        let original = try Data(contentsOf: root.appendingPathComponent("notes.json"))
        XCTAssertThrowsError(try repository.emptyTrash())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("notes.json")), original)
        XCTAssertEqual(repository.document.notes, [note])
    }
}
