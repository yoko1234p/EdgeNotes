import NotesCore
import XCTest

final class NoteFormattingTests: XCTestCase {
    private func apply(_ edit: NoteTextEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
    func testUnicodeSelectionCanToggleBoldWithoutChangingOtherText() throws {
        let source = "你好 🐱 世界"
        let selection = (source as NSString).range(of: "🐱 世界")
        let bold = try XCTUnwrap(NoteTextFormatting.edit(source, selection: selection, style: .bold))
        let changed = apply(bold, to: source)
        XCTAssertEqual(changed, "你好 **🐱 世界**")
        let plain = try XCTUnwrap(NoteTextFormatting.edit(changed, selection: bold.selection, style: .bold))
        XCTAssertEqual(apply(plain, to: changed), source)
    }
    func testTaskFormattingHandlesMultipleLinesAndCompletedTasks() throws {
        let source = "買咖啡\n回覆訊息\n"
        let edit = try XCTUnwrap(
            NoteTextFormatting.edit(source, selection: NSRange(location: 0, length: source.utf16.count), style: .task))
        XCTAssertEqual(apply(edit, to: source), "- [ ] 買咖啡\n- [ ] 回覆訊息\n")
        let completed = "- [x] 買咖啡\n- [ ] 回覆訊息\n"
        let remove = try XCTUnwrap(
            NoteTextFormatting.edit(
                completed, selection: NSRange(location: 0, length: completed.utf16.count), style: .task))
        XCTAssertEqual(apply(remove, to: completed), source)
    }
    func testInsertionSelectsPlaceholderAndInvalidRangeIsRejected() throws {
        let edit = try XCTUnwrap(NoteTextFormatting.edit("", selection: NSRange(location: 0, length: 0), style: .code))
        XCTAssertEqual(edit.replacement, "`文字`")
        XCTAssertEqual(edit.selection, NSRange(location: 1, length: 2))
        XCTAssertNil(NoteTextFormatting.edit("abc", selection: NSRange(location: 2, length: Int.max), style: .bold))
    }
}
