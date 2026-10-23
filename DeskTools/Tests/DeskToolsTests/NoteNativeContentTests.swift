import AppKit
import NotesCore
import SwiftUI
import XCTest

@testable import EdgeNotes

final class NoteNativeContentTests: XCTestCase {
    func testNativeImageRoundTripAndCaretMappingPreserveUnicodeText() async throws {
        try await MainActor.run {
            let attachment = try Self.image()
            let source = "前面😀\n" + NoteImagePlacement.marker(attachment.id) + "\n後面"
            let content = NoteAttributedContent.render(source, attachments: [attachment])
            XCTAssertEqual(content.string, "前面😀\n\u{FFFC}\n後面")
            XCTAssertEqual(NoteAttributedContent.source(content), source)
            XCTAssertEqual(
                NoteAttributedContent.sourceRange(NSRange(location: 7, length: 2), in: content).location,
                source.utf16.count - 2)
            XCTAssertEqual(NoteAttributedContent.displayOffset(source.utf16.count, source: source), content.length)
        }
    }
    func testPasteBetweenTextCanBeUndoneWithoutDeletingTheFollowingText() async throws {
        try await MainActor.run {
            let attachment = try Self.image()
            let before = "before\nafter"
            let after = NoteImagePlacement.inserted([attachment.id], into: before, at: NSRange(location: 7, length: 0))
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
            view.isRichText = true
            view.allowsUndo = true
            view.string = before
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            let controller = NoteEditorController()
            controller.editor = view
            controller.pasted(before: before, after: after, attachments: [attachment], ids: [attachment.id])
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), after)
            XCTAssertTrue(view.undoManager?.canUndo == true)
            view.undoManager?.undo()
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), before)
            let redo = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero,
                    modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: "Z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 6))
            XCTAssertTrue(view.performKeyEquivalent(with: redo))
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), after)
        }
    }
    func testCopyCurrentCalculationUsesCaretAndNamedPasteboardAndRejectsStaleResults() async throws {
        try await MainActor.run {
            let source = "前面😀\r\n1 / 3\r\n1 / 0"
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
            let clipboard = NSPasteboard(name: .init("EdgeNotes-calculation-" + UUID().uuidString))
            defer { clipboard.releaseGlobally() }
            view.pasteboard = clipboard
            view.string = source
            view.applyCalculations(NoteCalculations.evaluate(source), source: source)
            view.setSelectedRange(NSRange(location: (source as NSString).range(of: "1 / 3").location, length: 0))
            let key = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                    windowNumber: 0, context: nil, characters: "C", charactersIgnoringModifiers: "c",
                    isARepeat: false, keyCode: 8))
            XCTAssertTrue(view.performKeyEquivalent(with: key))
            XCTAssertEqual(
                try XCTUnwrap(Double(try XCTUnwrap(clipboard.string(forType: .string)))), 1.0 / 3, accuracy: 1e-15)
            clipboard.clearContents()
            clipboard.setString("sentinel", forType: .string)
            XCTAssertFalse(view.copyCalculation(line: 2))
            XCTAssertEqual(clipboard.string(forType: .string), "sentinel")
            view.string = source + "\r\n4"
            XCTAssertFalse(view.copyCalculation(line: 1))
            view.applyCalculations(NoteCalculations.evaluate(source), source: source)
            XCTAssertFalse(view.copyCalculation(line: 1))
            XCTAssertEqual(clipboard.string(forType: .string), "sentinel")
            view.invalidateCalculations()
            XCTAssertTrue(view.calculations.isEmpty)
        }
    }

    func testCalculationCaretAfterInlineImageKeepsTheRightLogicalLine() async throws {
        try await MainActor.run {
            let attachment = try Self.image()
            let source = "1 + 1\r\n" + NoteImagePlacement.marker(attachment.id) + "\r\n1 / 3"
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
            let clipboard = NSPasteboard(name: .init("EdgeNotes-image-calculation-" + UUID().uuidString))
            defer { clipboard.releaseGlobally() }
            view.pasteboard = clipboard
            view.textStorage?.setAttributedString(NoteAttributedContent.render(source, attachments: [attachment]))
            view.applyCalculations(NoteCalculations.evaluate(source), source: source)
            let offset = NoteAttributedContent.displayOffset(
                (source as NSString).range(of: "1 / 3").location, source: source)
            view.setSelectedRange(NSRange(location: offset, length: 0))
            view.copyCurrentCalculation(nil)
            XCTAssertEqual(
                try XCTUnwrap(Double(try XCTUnwrap(clipboard.string(forType: .string)))), 1.0 / 3, accuracy: 1e-15)
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), source)
        }
    }

    func testPendingCalculationsHideOldAnswersWithoutChangingTheTextGutter() async {
        await MainActor.run {
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
            view.string = "1 / 0"
            view.applyCalculations(NoteCalculations.evaluate(view.string), source: view.string)
            XCTAssertEqual(view.calculationGutterWidth, 96)
            view.string = "sqrt(-1)"
            view.invalidateCalculations(preservingGutter: true)
            XCTAssertEqual(view.calculationGutterWidth, 96)
            XCTAssertTrue(view.calculations.isEmpty)
            XCTAssertFalse(view.canCopyCalculation(line: 0))
            view.applyCalculations(NoteCalculations.evaluate(view.string), source: view.string)
            XCTAssertEqual(view.calculationGutterWidth, 96)
            XCTAssertEqual(view.calculations.first?.output, "無有效結果")
            view.invalidateCalculations()
            XCTAssertEqual(view.calculationGutterWidth, 0)
        }
    }

    func testSentenceAnswerIsPhysicalTextAndOrdinaryCopyIncludesIt() async throws {
        try await MainActor.run {
            let source = "i will see 1 mm in m"
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
            view.isRichText = true
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.makeFirstResponder(view)
            defer { window.close() }
            let board = NSPasteboard(name: .init("EdgeNotes-test-sentence-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            view.pasteboard = board
            view.string = source
            view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
            XCTAssertTrue(view.materializeCalculations(NoteCalculations.evaluate(source), source: source))
            let actual = source + "（0.001 m）"
            view.applyCalculations(NoteCalculations.evaluate(source), source: actual)
            XCTAssertEqual(view.calculations.first?.isInline, true)
            XCTAssertEqual(view.calculationGutterWidth, 0)
            XCTAssertEqual(view.string, actual)
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), actual)
            XCTAssertEqual(view.selectedRange().location, source.utf16.count)
            XCTAssertEqual(NoteAttributedContent.calculationAnnotations(in: view.attributedString()).count, 1)
            view.selectAll(nil)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: actual.utf16.count))
            view.copy(nil)
            XCTAssertEqual(
                board.string(forType: .string), actual, "Types: \(board.types ?? []) selectable: \(view.isSelectable)")
            XCTAssertTrue(view.copyCalculation(line: 0))
            XCTAssertEqual(board.string(forType: .string), "0.001 m")
        }
    }

    func testLiveEditingUpdatesAnExistingAnswerAndUndoDoesNotRegenerateIt() async throws {
        let fixture = await MainActor.run { CalculationEditorFixture("i will see 1 mm in m") }
        defer { Task { @MainActor in fixture.window.close() } }
        try await wait(fixture, for: "i will see 1 mm in m（0.001 m）")
        await MainActor.run {
            let range = (fixture.view.string as NSString).range(of: "1 mm")
            fixture.view.insertText("2", replacementRange: NSRange(location: range.location, length: 1))
        }
        try await wait(fixture, for: "i will see 2 mm in m（0.002 m）")
        await MainActor.run { fixture.view.undoManager?.undo() }
        try await wait(fixture, for: "i will see 2 mm in m（0.001 m）")
        try await Task.sleep(for: .milliseconds(350))
        await MainActor.run {
            XCTAssertEqual(fixture.source, "i will see 2 mm in m（0.001 m）")
            fixture.view.undoManager?.redo()
        }
        try await wait(fixture, for: "i will see 2 mm in m（0.002 m）")
        await MainActor.run {
            XCTAssertEqual(fixture.annotations.count, 1)
            let input = NoteCalculationText.input(fixture.source, annotations: fixture.annotations)
            XCTAssertEqual(input, "i will see 2 mm in m")
        }
    }

    func testReturnKeepsAnswerOnItsLineAndManualAnswerEditsStayEditable() async throws {
        let fixture = await MainActor.run { CalculationEditorFixture("i will see 1 mm in m") }
        defer { Task { @MainActor in fixture.window.close() } }
        try await wait(fixture, for: "i will see 1 mm in m（0.001 m）")
        await MainActor.run { fixture.view.insertNewline(nil) }
        try await wait(fixture, for: "i will see 1 mm in m（0.001 m）\n")
        await MainActor.run {
            let range = (fixture.view.string as NSString).range(of: "0.001 m")
            fixture.view.insertText("my answer", replacementRange: range)
        }
        try await wait(fixture, for: "i will see 1 mm in m（my answer）\n")
        try await Task.sleep(for: .milliseconds(350))
        await MainActor.run {
            XCTAssertEqual(fixture.source, "i will see 1 mm in m（my answer）\n")
            XCTAssertTrue(fixture.annotations.isEmpty)
        }
    }

    func testMaterializationPreservesImagesAndLogicalLinesAcrossOneUndo() async throws {
        try await MainActor.run {
            let image = try Self.image()
            let source = "1 / 3\r\n" + NoteImagePlacement.marker(image.id) + "\r\n後面 2 mm in m"
            let view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
            view.isRichText = true
            view.allowsUndo = true
            view.textStorage?.setAttributedString(NoteAttributedContent.render(source, attachments: [image]))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            XCTAssertTrue(view.materializeCalculations(NoteCalculations.evaluate(source), source: source))
            let expected = "1 / 3（0.333333）\r\n" + NoteImagePlacement.marker(image.id) + "\r\n後面 2 mm in m（0.002 m）"
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), expected)
            let annotations = NoteAttributedContent.calculationAnnotations(in: view.attributedString())
            XCTAssertEqual(annotations.count, 2)
            XCTAssertEqual(NoteCalculationText.input(expected, annotations: annotations), source)
            view.undoManager?.undo()
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), source)
            view.undoManager?.redo()
            XCTAssertEqual(NoteAttributedContent.source(view.attributedString()), expected)
        }
    }

    private func wait(_ fixture: CalculationEditorFixture, for source: String) async throws {
        for _ in 0..<40 {
            if await MainActor.run(body: { fixture.source == source && fixture.view.string == source }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        await MainActor.run { XCTAssertEqual(fixture.source, source) }
    }

    @MainActor private static func image() throws -> NoteAttachment {
        let bitmap = try XCTUnwrap(
            CGContext(
                data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try XCTUnwrap(bitmap.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        return NoteAttachment(name: "inline.png", data: data)
    }
}

@MainActor private final class CalculationEditorFixture {
    var source: String
    var annotations: [NoteCalculationAnnotation] = []
    let view: FormattingTextView
    let window: NSWindow
    let controller = NoteEditorController()
    var coordinator: InlineNoteEditor.Coordinator!
    init(_ source: String) {
        self.source = source
        view = FormattingTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 250))
        view.isRichText = true
        view.allowsUndo = true
        view.string = source
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        let parent = InlineNoteEditor(
            text: Binding(get: { [weak self] in self?.source ?? "" }, set: { [weak self] in self?.source = $0 }),
            controller: controller,
            contentChanged: { [weak self] text, annotations in
                self?.source = text
                self?.annotations = annotations
            })
        coordinator = parent.makeCoordinator()
        view.delegate = coordinator
        controller.editor = view
        coordinator.refresh(view)
        coordinator.calculate(view)
    }
}
