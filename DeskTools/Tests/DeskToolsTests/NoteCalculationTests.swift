import NotesCore
import XCTest

final class NoteCalculationTests: XCTestCase {
    func testExamplesFromRequestedScreenshots() {
        let source = """
            # Unit Conversion
            $20 in Euro
            4 cm in inches
            30 ml in tea spoons
            15 hours in min
            6 cbm in litres
            3 MB in Kb
            2 kg in pounds
            # Functions
            10% off $99.99
            20% of what is 30 cm
            $5 as a % of $10
            Square root of 9
            Log 2 (10)
            (sin 30°) * (cos 60°)
            # CSS
            em = 14px
            16 px in em
            2 em in px
            ppi = 320px
            1 cm in px
            """
        let output = NoteCalculations.evaluate(source, rates: ["EUR": 1, "USD": 1.1229])
        XCTAssertEqual(
            output.map(\.output),
            [
                "€17.81", "1.57 inch", "6.09 tsp", "900 min", "6,000 L", "24,000 Kb", "4.41 lb",
                "$89.99", "150 cm", "50 %", "3", "3.321928", "0.25",
                "14 px", "1.14 em", "28 px", "320 px", "125.98 px",
            ])
        XCTAssertTrue(output.allSatisfy { !$0.failed })
    }
    func testVariablesPrecedencePreviousTotalsAndDegrees() {
        XCTAssertEqual(
            NoteCalculations.evaluate("cost = $20\ncost * 3\nprev - 10%\n\n2 + 3 * 4\n(2 + 3) * 4\nsum")
                .map(\.output), ["$20.00", "$60.00", "$54.00", "14", "20", "34"])
        XCTAssertEqual(
            NoteCalculations.evaluate("sin(pi / 2)\ncos 60°\nsqrt(16)\nfact 5").map(\.output),
            ["1", "0.5", "4", "120"])
    }
    func testInvalidUnitsMissingRatesAndDomainsDoNotReturnPlausibleNumbers() {
        let output = NoteCalculations.evaluate("2 kg in cm\n$20 in EUR\n1 / 0\n# title\nBuy milk\nx = sqrt(-1)")
        XCTAssertEqual(output.count, 4)
        XCTAssertTrue(output.allSatisfy(\.failed))
    }
    func testCaseSensitiveDataUnitsAndBoundedDeepExpressions() {
        XCTAssertEqual(NoteCalculations.evaluate("1 MB in Mb\n1 KiB in B").map(\.output), ["8 Mb", "1,024 B"])
        XCTAssertTrue(
            NoteCalculations.evaluate(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100))
                .allSatisfy(\.failed))
        XCTAssertEqual(NoteCalculations.evaluate(String(repeating: "1 + 1\n", count: 5000)).count, 2000)
    }

    func testSmallNonzeroValuesStayVisibleInsteadOfRoundingToZero() throws {
        XCTAssertEqual(
            NoteCalculations.evaluate("1 mm in m\n-1 mm in m").map(\.output), ["0.001 m", "-0.001 m"])
        for input in ["1 / 3000000", "1e-100", "-1e-100"] {
            let result = try XCTUnwrap(NoteCalculations.evaluate(input).first)
            XCTAssertFalse(result.failed)
            let displayed = try XCTUnwrap(Double(result.output), result.output)
            XCTAssertNotEqual(displayed, 0, input)
            XCTAssertEqual(displayed > 0, !input.hasPrefix("-"))
        }
    }

    func testLogicalLineBreaksKeepIdenticalTotalsAndLineIndices() {
        let expected = NoteCalculations.evaluate("10\n20\nsum\n\n3\n4\navg")
        for newline in ["\r\n", "\r", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(
                NoteCalculations.evaluate(["10", "20", "sum", "", "3", "4", "avg"].joined(separator: newline)),
                expected, newline.debugDescription)
        }
    }

    func testSignedAndFunctionFailuresReportErrorsWhileOrdinaryProseStaysPlain() {
        let results = NoteCalculations.evaluate("-1 / 0\nsqrt(-1)\nsin(1 kg)\n- Buy milk\nMeeting tomorrow")
        XCTAssertEqual(results.map(\.line), [0, 1, 2])
        XCTAssertTrue(results.allSatisfy(\.failed))
    }

    func testTemperatureResultsCanBePastedBackAsInputs() {
        let results = NoteCalculations.evaluate("0 C in F\n32 °F in °C\n273.15 K in C\n0 °C in K")
        XCTAssertEqual(results.map(\.output), ["32 °F", "0 °C", "0 °C", "273.15 K"])
        XCTAssertTrue(results.allSatisfy { !$0.failed })
    }

    func testFailedReassignmentDoesNotReuseAnOlderVariableValue() {
        let results = NoteCalculations.evaluate("price = 10\nprice = 1 / 0\nprice * 2\nprice = 4\nprice * 2")
        XCTAssertEqual(results.map(\.line), [0, 1, 2, 3, 4])
        XCTAssertEqual(results.map(\.failed), [false, true, true, false, false])
        XCTAssertEqual(results.last?.output, "8")
        let incomplete = NoteCalculations.evaluate("price = 10\nprice =\nprice * 2")
        XCTAssertEqual(incomplete.map(\.failed), [false, true, true])
        let invalidTokens = NoteCalculations.evaluate("price = 10\nprice = 5!\nprice * 2")
        XCTAssertEqual(invalidTokens.map(\.failed), [false, true, true])
    }

    func testCopyOutputRetainsHigherPrecisionWithoutDroppingUnits() throws {
        let results = NoteCalculations.evaluate("1 / 3\n4 cm in inches")
        XCTAssertEqual(results[0].output, "0.333333")
        XCTAssertEqual(try XCTUnwrap(Double(results[0].copyOutput)), 1.0 / 3, accuracy: 1e-15)
        XCTAssertTrue(results[1].copyOutput.hasSuffix(" inch"))
        XCTAssertEqual(
            try XCTUnwrap(Double(results[1].copyOutput.replacingOccurrences(of: " inch", with: ""))),
            0.04 / 0.0254, accuracy: 1e-14)
    }

    func testOverlengthReassignmentInvalidatesThePreviousValue() {
        let source = "price = 10\nprice = " + String(repeating: "1 + ", count: 600) + "1\nprice * 2"
        let results = NoteCalculations.evaluate(source)
        XCTAssertEqual(results.map(\.failed), [false, true, true])
        XCTAssertEqual(results[1].output, "算式太長")
    }

    func testInvalidCSSDefinitionsBlockOldConversionValuesAndCanRecover() {
        let em = NoteCalculations.evaluate("em = 14px\nem = 0px\n2 em in px\nem = 20px\n2 em in px")
        XCTAssertEqual(em.map(\.failed), [false, true, true, false, false])
        XCTAssertEqual(em.last?.output, "40 px")
        let ppi = NoteCalculations.evaluate("ppi = 320px\nppi = 0\n1 cm in px\nppi = 96px\n1 inch in px")
        XCTAssertEqual(ppi.map(\.failed), [false, true, true, false, false])
        XCTAssertEqual(ppi.last?.output, "96 px")
        XCTAssertFalse(NoteCalculations.evaluate("1 cm in mm").contains(where: \.failed))
    }

    func testLogicalLineRangesPreserveUTF16PositionsAndBoundTinyLines() {
        for newline in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let source = "😀" + newline + "1 + 1" + newline + "" + newline + "3" + newline
            let ranges = NoteTextLines.ranges(in: source)
            XCTAssertEqual(ranges.map { (source as NSString).substring(with: $0) }, ["😀", "1 + 1", "", "3", ""])
            let offset = (source as NSString).range(of: "1 + 1").location
            XCTAssertEqual(NoteTextLines.index(atUTF16Offset: offset, in: source), 1)
            XCTAssertEqual(NoteTextLines.index(atUTF16Offset: source.utf16.count, in: source), 4)
        }
        let manyLines = String(repeating: "\r\n", count: 300_000)
        XCTAssertEqual(NoteTextLines.ranges(in: manyLines).count, 2000)
        XCTAssertNil(NoteTextLines.index(atUTF16Offset: manyLines.utf16.count, in: manyLines))
    }

    func testChecklistToggleUsesTheSameLinesAndPreservesOriginalSeparators() {
        for newline in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let source = ["Heading😀", "- [ ] task", "1 + 1"].joined(separator: newline)
            XCTAssertEqual(
                NoteChecklist.toggle(source, line: 1), ["Heading😀", "- [x] task", "1 + 1"].joined(separator: newline))
        }
        let prefix = String(repeating: "ordinary note\n", count: 2500)
        XCTAssertEqual(NoteChecklist.toggle(prefix + "- [ ] task", line: 2500), prefix + "- [x] task")
    }

    func testSentenceEndingInAFormulaGetsAnInlineAnswer() {
        let results = NoteCalculations.evaluate(
            "i will see 1 mm in m\n我想睇1 mm in m\nThe result is (2 + 3) * 4.\nLength:1 mm in m")
        XCTAssertEqual(results.map(\.output), ["0.001 m", "0.001 m", "20", "0.001 m"])
        XCTAssertTrue(results.allSatisfy(\.isInline))
        XCTAssertTrue(results.allSatisfy { !$0.failed })
        XCTAssertFalse(NoteCalculations.evaluate("1 mm in m")[0].isInline)
    }

    func testEmbeddedFormulasDoNotEvaluateDatesIdentifiersURLsOrLoneNumbers() {
        let input = """
            I will see 12 people
            Date is 2026-10-14
            Date is 14/10/2026
            Date is 10/14/2026
            Date is 14-10-2026
            Download https://example.invalid/1/2
            Open /Volumes/Work/1/2
            Build version v1.2.3
            My account is 123456
            """
        XCTAssertTrue(NoteCalculations.evaluate(input).isEmpty)
        let result = NoteCalculations.evaluate("I have 2 children and will see 1 mm in m")
        XCTAssertEqual(result.map(\.output), ["0.001 m"])
    }

    func testEmbeddedErrorsAndVariablesUseTheCurrentContext() {
        let results = NoteCalculations.evaluate("cost = $20\nI will pay cost * 2\nThe value is 1 / 0")
        XCTAssertEqual(results.map(\.isInline), [false, true, true])
        XCTAssertEqual(results.map(\.failed), [false, false, true])
        XCTAssertEqual(results[1].output, "$40.00")
        XCTAssertTrue(NoteCalculations.evaluate("Please set price = 4").isEmpty)
    }

    func testEmbeddedInvalidExpressionsDoNotRetryFromALaterOperand() {
        for input in ["I will see 1 + unknown + 2 * 3", "Area is 2m x 3m in cm"] {
            let results = NoteCalculations.evaluate(input)
            XCTAssertEqual(results.count, 1, input)
            XCTAssertTrue(results.allSatisfy { $0.failed && $0.isInline }, input)
        }
    }

    func testEmbeddedOversizedExpressionCannotBecomeAShorterSuccessfulCalculation() {
        for prefix in ["Total is ", "The total is "] {
            let source = prefix + Array(repeating: "1", count: 130).joined(separator: " + ")
            let results = NoteCalculations.evaluate(source)
            XCTAssertEqual(results.map(\.output), ["算式太長"])
            XCTAssertTrue(results.allSatisfy(\.failed))
        }
    }
}
