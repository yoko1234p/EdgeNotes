import Foundation
import NotesCore
import XCTest

final class NoteCalculationTextTests: XCTestCase {
    func testDateShapedNumericLinesStayPlainText() {
        let source = "2026-10-14\n14/10/2026\n10/14/2026\n1 / 2 / 3"
        let edits = NoteCalculationText.edits(in: source, annotations: [], results: NoteCalculations.evaluate(source))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.text, "（0.166667）")
    }
    func testOnlySuccessfulNontrivialAnswersAreWritten() {
        let source = "i will see 1 mm in m\r\n10\r\nsqrt(-1)\r\n1 + 1"
        let edits = NoteCalculationText.edits(in: source, annotations: [], results: NoteCalculations.evaluate(source))
        XCTAssertEqual(edits.map(\.text), ["（0.001 m）", "（2）"])
        let result = NSMutableString(string: source)
        for edit in edits.reversed() { result.replaceCharacters(in: edit.range, with: edit.text) }
        XCTAssertEqual(result as String, "i will see 1 mm in m（0.001 m）\r\n10\r\nsqrt(-1)\r\n1 + 1（2）")
    }

    func testStoredAnswersAreExcludedFromVariablesAndTotals() {
        let source = "cost = 1 / 3（0.333333）\r\ncost * 3（1）\r\nsum（1.333333）"
        let annotations = ["（0.333333）", "（1）", "（1.333333）"].map {
            NoteCalculationAnnotation(location: (source as NSString).range(of: $0).location, text: $0)
        }
        let input = NoteCalculationText.input(source, annotations: annotations)
        XCTAssertEqual(input, "cost = 1 / 3\r\ncost * 3\r\nsum")
        let results = NoteCalculations.evaluate(input)
        XCTAssertEqual(results.map(\.output), ["0.333333", "1", "1.333333"])
        XCTAssertTrue(NoteCalculationText.edits(in: source, annotations: annotations, results: results).isEmpty)
    }

    func testChangedFormulaReplacesOneOwnedAnswerAndFailuresRemoveIt() {
        let source = "我想睇 2 mm in m（0.001 m）"
        let annotation = NoteCalculationAnnotation(
            location: (source as NSString).range(of: "（").location, text: "（0.001 m）")
        let input = NoteCalculationText.input(source, annotations: [annotation])
        let edits = NoteCalculationText.edits(
            in: source, annotations: [annotation], results: NoteCalculations.evaluate(input))
        XCTAssertEqual(edits.map(\.text), ["（0.002 m）"])
        XCTAssertEqual(edits.first?.range, annotation.range)
        XCTAssertEqual(NoteCalculationText.edits(in: source, annotations: [annotation], results: []).map(\.text), [""])
    }

    func testUnownedParenthesesAndStaleOrHostileMetadataCannotAuthorizeEdits() {
        let source = "Keep my answer（123）\n1 + 1"
        let input = NoteCalculationText.input(
            source,
            annotations: [
                .init(location: 0, text: "（123）"), .init(location: Int.max, text: "（1）"),
                .init(location: -1, text: "（2）"), .init(location: 14, text: "（wrong）"),
            ])
        XCTAssertEqual(input, source)
        XCTAssertEqual(NoteCalculationText.input(source, annotations: []), source)
        let annotated = "1 + 1（2）"
        let owned = NoteCalculationAnnotation(location: 5, text: "（2）")
        XCTAssertEqual(NoteCalculationText.input(annotated + " keep", annotations: [owned]), annotated + " keep")
    }

    func testMetadataRebasesAroundUnicodeAndDetachesWhenAnswerIsEdited() {
        let old = "1 + 1（2）"
        let owned = NoteCalculationAnnotation(location: 5, text: "（2）")
        let after = "😀\r\n" + old
        let shifted = NoteCalculationText.rebased([owned], from: old, to: after)
        XCTAssertEqual(shifted.first?.location, 9)
        XCTAssertEqual(NoteCalculationText.input(after, annotations: shifted), "😀\r\n1 + 1")
        XCTAssertTrue(NoteCalculationText.rebased([owned], from: old, to: "1 + 1（my answer）").isEmpty)
    }
}
