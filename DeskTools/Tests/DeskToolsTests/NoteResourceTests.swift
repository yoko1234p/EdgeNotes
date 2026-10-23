import DeskCore
import Foundation
import NotesCore
import XCTest

final class NoteResourceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testLegacyAttachmentsMigrateWithoutChangingDocumentAndExportIsPortable() throws {
        let root = try directory()
        var document = NotesDocument()
        var note = DeskNote(folderID: document.folders[0].id, text: "keep text")
        note.attachments = [NoteAttachment(name: "image.png", data: Data(repeating: 42, count: 100_000))]
        document.notes = [note]
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("notes.json"))
        let repository = try NotesRepository(directory: root)
        XCTAssertEqual(repository.document, document)
        var changed = document
        changed.notes[0].text = "edited"
        try repository.commit(changed)
        XCTAssertEqual(try NotesRepository(directory: root).document, changed)
        XCTAssertLessThan(try Data(contentsOf: root.appendingPathComponent("notes.json")).count, 2000)
        XCTAssertEqual(try NotesDocument.decode(repository.exportData()), changed)
        let imported = try NotesRepository(directory: directory())
        try imported.importData(repository.exportData())
        XCTAssertEqual(imported.document.notes[0].attachments[0].data, note.attachments[0].data)
    }
    func testRepeatedTextEditsDoNotRewriteBlobAndSnapshotStorageStaysSmall() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var document = repository.document
        var note = DeskNote(folderID: document.folders[0].id)
        note.attachments = [NoteAttachment(name: "sample.bin", data: Data(repeating: 37, count: 2_000_000))]
        document.notes = [note]
        try repository.commit(document)
        let folder = root.appendingPathComponent("Resources")
        let blob = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let modified = try FileManager.default.attributesOfItem(atPath: blob.path)[.modificationDate] as? Date
        for value in 0..<10 {
            document.notes[0].text = "edit \(value)"
            try repository.commit(document)
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: blob.path)[.modificationDate] as? Date, modified)
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Snapshots"), includingPropertiesForKeys: nil)
        XCTAssertEqual(snapshots.count, 5)
        XCTAssertLessThan(try snapshots.reduce(0) { try $0 + Data(contentsOf: $1).count }, 10_000)
        XCTAssertEqual(try Data(contentsOf: blob), note.attachments[0].data)
    }
    func testIdenticalImageContentsShareOneBlobAndNoOpDoesNotAddSnapshot() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var next = repository.document
        var note = DeskNote(folderID: next.folders[0].id)
        note.attachments = [
            NoteAttachment(name: "a", data: Data("same".utf8)), NoteAttachment(name: "b", data: Data("same".utf8)),
        ]
        next.notes = [note]
        try repository.commit(next)
        try repository.commit(next)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Resources").path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Snapshots").path))
    }
    func testRemovingImageRetainsSnapshotResourceThenReclaimsAfterHistoryExpires() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var next = repository.document
        var note = DeskNote(folderID: next.folders[0].id)
        note.attachments = [NoteAttachment(name: "a", data: Data("image".utf8))]
        next.notes = [note]
        try repository.commit(next)
        next.notes[0].attachments = []
        try repository.commit(next)
        let folder = root.appendingPathComponent("Resources")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        for value in 0..<10 {
            next.notes[0].text = "edit \(value)"
            try repository.commit(next)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
    func testCorruptOrMissingResourcePreventsSilentReplacement() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var next = repository.document
        var note = DeskNote(folderID: next.folders[0].id)
        note.attachments = [NoteAttachment(name: "a", data: Data("good".utf8))]
        next.notes = [note]
        try repository.commit(next)
        let file = root.appendingPathComponent("notes.json")
        let before = try Data(contentsOf: file)
        let blob = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("Resources"), includingPropertiesForKeys: nil
            ).first)
        try Data("evil".utf8).write(to: blob)
        XCTAssertThrowsError(try NotesRepository(directory: root))
        XCTAssertEqual(try Data(contentsOf: file), before)
        try FileManager.default.removeItem(at: blob)
        XCTAssertThrowsError(try NotesRepository(directory: root))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testUntrustedResourceReferencesCannotBeImportedAsPortableBackup() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var next = repository.document
        var note = DeskNote(folderID: next.folders[0].id)
        note.attachments = [NoteAttachment(name: "a", data: Data("content".utf8))]
        next.notes = [note]
        try repository.commit(next)
        let destination = try NotesRepository(directory: directory())
        XCTAssertThrowsError(try destination.importData(Data(contentsOf: root.appendingPathComponent("notes.json"))))
        XCTAssertTrue(destination.document.notes.isEmpty)
    }
    func testOwnResourceSnapshotRestoresImageAndRejectsCopiedExternalManifest() throws {
        let root = try directory()
        let repository = try NotesRepository(directory: root)
        var next = repository.document
        var note = DeskNote(folderID: next.folders[0].id, text: "before")
        note.attachments = [NoteAttachment(name: "image.png", data: Data("image bytes".utf8))]
        next.notes = [note]
        try repository.commit(next)
        next.notes[0].text = "after"
        next.notes[0].attachments = []
        try repository.commit(next)
        let snapshot = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("Snapshots"), includingPropertiesForKeys: nil
            ).first)
        let external = try directory().appendingPathComponent("copy.json")
        try FileManager.default.copyItem(at: snapshot, to: external)
        XCTAssertThrowsError(try repository.importSnapshot(at: external))
        XCTAssertEqual(repository.document.notes.count, 1)
        try repository.importSnapshot(at: snapshot)
        XCTAssertEqual(Set(repository.document.notes.map(\.text)), ["before", "after"])
        XCTAssertEqual(
            repository.document.notes.first { $0.text == "before" }?.attachments.first?.data,
            note.attachments[0].data)
        try repository.importSnapshot(at: snapshot)
        XCTAssertEqual(repository.document.notes.count, 2)
        XCTAssertEqual(try NotesRepository(directory: root).document, repository.document)
    }
}
