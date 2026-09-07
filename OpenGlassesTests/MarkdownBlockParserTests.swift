import XCTest
@testable import OpenGlasses

/// Tests for the pure chat-message segmenter that splits prose from fenced code blocks.
final class MarkdownBlockParserTests: XCTestCase {

    func testEmptyAndWhitespaceProduceNoBlocks() {
        XCTAssertEqual(MarkdownBlockParser.parse(""), [])
        XCTAssertEqual(MarkdownBlockParser.parse("   \n\n  \t"), [])
    }

    func testPlainProse() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("Hello there.\nHow are you?"),
            [.prose("Hello there.\nHow are you?")]
        )
    }

    func testSingleCodeBlockWithLanguageSurroundedByProse() {
        let input = """
        Here is some Swift:
        ```swift
        let x = 1
        print(x)
        ```
        That's it.
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .prose("Here is some Swift:"),
            .code(language: "swift", body: "let x = 1\nprint(x)"),
            .prose("That's it.")
        ])
    }

    func testCodeBlockWithoutLanguage() {
        let input = """
        ```
        plain code
        ```
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .code(language: nil, body: "plain code")
        ])
    }

    func testUnterminatedFenceCapturesRemainderAsCode() {
        let input = """
        intro
        ```python
        x = 1
        y = 2
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .prose("intro"),
            .code(language: "python", body: "x = 1\ny = 2")
        ])
    }

    func testCodePreservesIndentationAndBlankLines() {
        let input = """
        ```
        def f():

            return 1
        ```
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .code(language: nil, body: "def f():\n\n    return 1")
        ])
    }

    func testMultipleCodeBlocks() {
        let input = """
        a
        ```
        one
        ```
        b
        ```
        two
        ```
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .prose("a"),
            .code(language: nil, body: "one"),
            .prose("b"),
            .code(language: nil, body: "two")
        ])
    }

    func testCarriageReturnsAreNormalized() {
        XCTAssertEqual(
            MarkdownBlockParser.parse("line1\r\nline2"),
            [.prose("line1\nline2")]
        )
    }

    // MARK: - Headings (Plan EK P3)

    func testHeadingsByLevel() {
        XCTAssertEqual(MarkdownBlockParser.parse("# Fault Codes"), [.heading(level: 1, text: "Fault Codes")])
        XCTAssertEqual(MarkdownBlockParser.parse("## Acme RTU-500"), [.heading(level: 2, text: "Acme RTU-500")])
        XCTAssertEqual(MarkdownBlockParser.parse("### Figure 58 \u{2014} Integrated Control"),
                       [.heading(level: 3, text: "Figure 58 \u{2014} Integrated Control")])
        XCTAssertEqual(MarkdownBlockParser.parse("##### Deep"), [.heading(level: 3, text: "Deep")],
                       "there are three heading sizes; a fourth would read as body text")
        XCTAssertEqual(MarkdownBlockParser.parse("## Closed ##"), [.heading(level: 2, text: "Closed")])
    }

    func testAHashThatIsNotAHeading() {
        XCTAssertEqual(MarkdownBlockParser.parse("#hashtag"), [.prose("#hashtag")])
        XCTAssertEqual(MarkdownBlockParser.parse("####### seven"), [.prose("####### seven")])
        XCTAssertEqual(MarkdownBlockParser.parse("#"), [.prose("#")])
    }

    func testHeadingSplitsTheProseAroundIt() {
        let input = """
        Before.
        ## Middle
        After.
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .prose("Before."),
            .heading(level: 2, text: "Middle"),
            .prose("After.")
        ])
    }

    // MARK: - Lists

    func testBulletListRunsTogetherAndEndsAtProse() {
        let input = """
        Check these:
        - Sight glass
        * Subcooling
        + Filter drier
        Then measure.
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .prose("Check these:"),
            .bulletList(["Sight glass", "Subcooling", "Filter drier"]),
            .prose("Then measure.")
        ])
    }

    func testNumberedListKeepsTheAuthorsNumbers() {
        let input = """
        3. Close the gas valve
        4) Wait five minutes
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [
            .numberedList([.init(number: 3, text: "Close the gas valve"),
                           .init(number: 4, text: "Wait five minutes")])
        ])
    }

    func testAMinusThatIsNotABullet() {
        XCTAssertEqual(MarkdownBlockParser.parse("-5 degrees of subcool"), [.prose("-5 degrees of subcool")])
        XCTAssertEqual(MarkdownBlockParser.parse("2026-09-07 was the import date"),
                       [.prose("2026-09-07 was the import date")])
    }

    // MARK: - Tables

    func testPipeTableWithAlignmentRow() {
        let input = """
        | Code | Meaning                | First check   |
        |:-----|:----------------------:|--------------:|
        | ZX9  | Low refrigerant charge | Sight glass   |
        | ZX3  | Condenser fan failure  | Fan capacitor |
        """
        guard case .table(let table)? = MarkdownBlockParser.parse(input).first else {
            return XCTFail("expected a table: \(MarkdownBlockParser.parse(input))")
        }
        XCTAssertEqual(table.headers, ["Code", "Meaning", "First check"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows.first, ["ZX9", "Low refrigerant charge", "Sight glass"])
        XCTAssertEqual(table.alignment(9), .leading, "a column past the alignment row reads left")
    }

    func testRaggedRowsArePaddedAndTruncated() {
        let input = """
        | A | B | C |
        |---|---|---|
        | 1 |
        | 1 | 2 | 3 | 4 |
        """
        guard case .table(let table)? = MarkdownBlockParser.parse(input).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.rows, [["1", "", ""], ["1", "2", "3"]])
    }

    func testATableWithoutAnAlignmentRowStaysProse() {
        let input = """
        | A | B |
        | 1 | 2 |
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input), [.prose("| A | B |\n| 1 | 2 |")])
    }

    func testTableEndsAtTheFirstLineWithoutAPipe() {
        let input = """
        | A | B |
        |---|---|
        | 1 | 2 |
        Back to prose.
        """
        let blocks = MarkdownBlockParser.parse(input)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last, .prose("Back to prose."))
    }

    // MARK: - Mixed

    func testEverythingAtOnceInOrder() {
        let input = """
        ## Diagnostic Codes
        The controller flashes the code twice.
        - E223 is a flame-sense fault
        - E270 is a pressure-switch fault

        | Code | Meaning |
        |------|---------|
        | E223 | Flame sense |

        ```swift
        let x = 1
        ```
        Source: SLP99UHVK Service Manual, page 20
        """
        let blocks = MarkdownBlockParser.parse(input)
        XCTAssertEqual(blocks.count, 6, "\(blocks)")
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Diagnostic Codes"))
        XCTAssertEqual(blocks[1], .prose("The controller flashes the code twice."))
        XCTAssertEqual(blocks[2], .bulletList(["E223 is a flame-sense fault", "E270 is a pressure-switch fault"]))
        guard case .table = blocks[3] else { return XCTFail("expected a table at 3: \(blocks[3])") }
        XCTAssertEqual(blocks[4], .code(language: "swift", body: "let x = 1"))
        XCTAssertEqual(blocks[5], .prose("Source: SLP99UHVK Service Manual, page 20"))
    }

    func testMarkupInsideACodeBlockIsStillCode() {
        let input = """
        ```
        # not a heading
        - not a bullet
        | not | a table |
        |-----|---------|
        ```
        """
        XCTAssertEqual(MarkdownBlockParser.parse(input),
                       [.code(language: nil, body: "# not a heading\n- not a bullet\n| not | a table |\n|-----|---------|")])
    }
}
