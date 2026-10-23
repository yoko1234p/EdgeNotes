import Foundation
import NotesCore
import XCTest

final class NoteInlineImageTests: XCTestCase {
    func testPasteKeepsTextOnBothSidesAndDoesNotSplitEmoji() {
        let id = UUID()
        let result = NoteImagePlacement.inserted([id], into: "前面😀\n後面", at: NSRange(location: 5, length: 0))
        XCTAssertEqual(NoteImagePlacement.blocks(result), [.text("前面😀\n"), .image(id), .text("\n後面")])
    }
    func testPendingPasteRebasesEditsBeforeAndAfterCaret() {
        XCTAssertEqual(
            NoteImagePlacement.rebased(NSRange(location: 6, length: 0), from: "beforeafter", to: "Xbeforeafter")
                .location, 7)
        XCTAssertEqual(
            NoteImagePlacement.rebased(NSRange(location: 6, length: 0), from: "beforeafter", to: "beforeafterX")
                .location, 6)
        XCTAssertEqual(
            NoteImagePlacement.rebased(NSRange(location: 2, length: 3), from: "abcdef", to: "abNEWef").length, 0)
    }
    func testMergeImportRemapsInlineImageReferencesAndRepeatedRestoreIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try NotesRepository(directory: root)
        var source = repository.document
        var note = DeskNote(folderID: source.folders[0].id)
        let image = NoteAttachment(name: "sample.png", data: Data([1, 2, 3]))
        note.attachments = [image]
        note.usesInlineImages = true
        note.text = NoteImagePlacement.marker(image.id)
        source.notes = [note]
        try repository.commit(source)
        source.notes[0].text += "\nrestored"
        let backup = try JSONEncoder().encode(source)
        try repository.importData(backup)
        try repository.importData(backup)
        XCTAssertEqual(repository.document.notes.count, 2)
        let restored = repository.document.notes[1]
        XCTAssertNotEqual(restored.attachments[0].id, image.id)
        XCTAssertEqual(NoteImagePlacement.references(in: restored.text).first?.id, restored.attachments[0].id)
    }
}
