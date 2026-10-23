import AppKit
import SwiftUI
import XCTest
@testable import EdgeNotes

@MainActor final class NativeEditorLayoutTests: XCTestCase {
    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.compactMap { descendant(type, in: $0) }.first
    }
    func testInlineNoteEditorLaysOutVisibleGlyphs() async throws {
        let host = NSHostingView(
            rootView: InlineNoteEditor(text: .constant("Hello **world**"), controller: NoteEditorController()))
        try await verify(host)
    }
    private func verify(_ host: NSView) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(descendant(NSTextView.self, in: host))
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        layout.ensureLayout(for: container)
        let glyph = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        XCTAssertGreaterThan(glyph.width, 0)
        XCTAssertGreaterThan(glyph.height, 0)
        XCTAssertGreaterThan(container.containerSize.height, glyph.maxY)
        XCTAssertLessThan(glyph.minX + editor.textContainerInset.width, editor.bounds.maxX)
        window.close()
    }
}
