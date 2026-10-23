import AppKit
import CoreGraphics
import ImageIO
import NotesCore
import UniformTypeIdentifiers
import XCTest

@testable import EdgeNotes

final class NotesImagePasteTests: XCTestCase {
    private func png(width: Int = 120, height: Int = 80) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    @MainActor func testNativePasteMenuReadsNamedBitmapWithoutTouchingGeneralClipboard() throws {
        let board = NSPasteboard(name: .init("EdgeNotes-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.declareTypes([.png], owner: nil)
        board.setData(try png(), forType: .png)
        let editor = FormattingTextView()
        let menu = NSMenu()
        editor.string = "keep text"
        editor.pasteboard = board
        var received = [NoteClipboardImageSource]()
        editor.imagePaste = { values, text, selection in
            received = values
            XCTAssertEqual(text, "keep text")
            return true
        }
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        paste.target = editor
        menu.addItem(paste)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                isARepeat: false, keyCode: 9))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(editor.string, "keep text")
        XCTAssertEqual(try NotesClipboardImages.prepare(received).count, 1)
    }
    @MainActor func testPlainTextIsNotMisidentifiedAsAnImage() throws {
        let board = NSPasteboard(name: .init("EdgeNotes-test-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.declareTypes([.string], owner: nil)
        board.setString("hello", forType: .string)
        XCTAssertNil(try NotesClipboardImages.read(board))
    }
    func testInvalidDataRejectedAndThumbnailHasIndependentSmallBuffer() throws {
        XCTAssertThrowsError(try NoteImages.prepare(Data("not an image".utf8)))
        let prepared = try NoteImages.prepare(png(width: 1400, height: 900))
        let thumbnail = try XCTUnwrap(NoteImages.thumbnail(prepared.data, maxPixels: 320))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 320)
        XCTAssertLessThan(thumbnail.bytesPerRow * thumbnail.height, 500_000)
    }
    @MainActor func testBackgroundPasteKeepsOriginalNoteWhenSelectionChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NotesModel(directory: directory)
        model.newNote("first")
        let first = try XCTUnwrap(model.selected)
        XCTAssertTrue(
            model.pasteImageSources([.init(name: "fixture", data: try png())], into: first, text: "first edited"))
        model.newNote("second")
        let second = try XCTUnwrap(model.selected)
        for _ in 0..<100 {
            if model.pastingNoteIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.pastingNoteIDs.isEmpty)
        XCTAssertEqual(model.selected, second)
        XCTAssertEqual(model.draft, "second")
        XCTAssertEqual(model.document.notes.first { $0.id == first }?.text, "first edited")
        XCTAssertEqual(model.document.notes.first { $0.id == first }?.attachments.count, 1)
        XCTAssertTrue(model.document.notes.first { $0.id == second }?.attachments.isEmpty == true)
        XCTAssertEqual(try NotesRepository(directory: directory).document, model.document)
    }
    @MainActor func testImageValidationFailurePreservesNoteAndUnsavedDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = NotesModel(directory: directory)
        model.newNote("original")
        let id = try XCTUnwrap(model.selected)
        XCTAssertTrue(
            model.pasteImageSources([.init(name: "bad", data: Data("bad".utf8))], into: id, text: "keep draft"))
        for _ in 0..<100 {
            if model.pastingNoteIDs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(model.failure)
        XCTAssertEqual(model.draft, "keep draft")
        XCTAssertTrue(model.document.notes[0].attachments.isEmpty)
    }
}
