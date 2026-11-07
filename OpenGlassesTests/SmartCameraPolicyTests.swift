import XCTest
@testable import OpenGlasses

/// Plan JW P0 — "show me the table" with cited pages is `show_source`'s turn, not the camera's, and
/// smart camera never starts a glasses capture with the link down. P1a — nor is "read the row on
/// this page", and the camera tools decline it.
final class SmartCameraPolicyTests: XCTestCase {

    private let cited = SmartCameraPolicy.Context(citedManualPagesOpen: true)
    private let none = SmartCameraPolicy.Context()

    func testShowingACitedSourceIsNotAVisionTurnWhilePagesAreCited() {
        for turn in ["Show me the table", "show me the page", "Open the page", "bring up the second source",
                     "pull up table 99", "show me the rows", "can you show me that passage again",
                     "show me the diagram", "go to the figure", "highlight the row", "Show me", "show me that",
                     "show it again", "where does it say that"] {
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: cited), .textOnly, turn)
            XCTAssertTrue(SmartCameraPolicy.isAboutCitedPages(turn, context: cited), turn)
        }
    }

    func testWithoutCitedPagesTheWordsDecideAsBefore() {
        for turn in ["Show me the table", "show me the page", "Show me"] {
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: none), VisionIntentDetector.classify(turn), turn)
            XCTAssertFalse(SmartCameraPolicy.isAboutCitedPages(turn, context: none), turn)
        }
        XCTAssertEqual(SmartCameraPolicy.intent(for: "Show me the table", context: none), .vision,
                       "outside a session with cited pages, \"show me\" still looks")
    }

    func testTheCameraAndTheWorldStayCameraTurns() {
        for turn in ["show me what's in front of me", "look at this page and show me the table",
                     "what do you see on the page", "show me through the glasses",
                     "what is this", "read the label"] {
            XCTAssertFalse(SmartCameraPolicy.isAboutCitedPages(turn, context: cited), turn)
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: cited), .vision, turn)
        }
        // "Show me the way" is longer than a bare "show me (that)" and names no source.
        XCTAssertFalse(SmartCameraPolicy.isAboutCitedPages("show me the way out", context: cited))
    }

    // MARK: - Reading a manual page (Plan JW P1a)

    private static let pageReads = ["Read the W3 row in the Rating B column on this page", "read the row on this page",
                                    "what does the table say", "look up the value in row 7",
                                    "what's in the third column of this table", "what is the value in that cell",
                                    "read me the second row"]

    func testReadingACitedOrOpenPageIsNotACameraTurn() {
        let sheetOpen = SmartCameraPolicy.Context(manualPageOnScreen: true)
        for turn in Self.pageReads {
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: cited), .textOnly, turn)
            XCTAssertTrue(SmartCameraPolicy.isAboutCitedPages(turn, context: cited), turn)
            XCTAssertTrue(SmartCameraPolicy.isAboutCitedPages(turn, context: sheetOpen), turn)
            XCTAssertFalse(SmartCameraPolicy.isAboutCitedPages(turn, context: none), turn)
        }
        XCTAssertTrue(SmartCameraPolicy.isAboutCitedPages("show me the table", context: sheetOpen),
                      "an open sheet is a manual page to show as well")
    }

    func testReadingWhatIsInFrontStaysACameraTurn() {
        for turn in ["read this nameplate", "read the label", "read the label in front of me", "what does the gauge read",
                     "read the table on this nameplate", "read row 2 on the sticker", "look at this page and read the row",
                     "what is this"] {
            XCTAssertFalse(SmartCameraPolicy.isAboutCitedPages(turn, context: cited), turn)
        }
        XCTAssertEqual(SmartCameraPolicy.intent(for: "read this nameplate", context: cited),
                       VisionIntentDetector.classify("read this nameplate"))
    }

    func testTheCameraToolsDeclineOnlyAManualPageTurn() {
        let reply = SmartCameraPolicy.manualPageReply
        XCTAssertEqual(SmartCameraPolicy.cameraToolReply(utterance: "read the row on this page", toolReason: nil,
                                                         context: cited), reply)
        // The wearer's words win over the reason the model wrote.
        XCTAssertNil(SmartCameraPolicy.cameraToolReply(utterance: "read this nameplate",
                                                       toolReason: "read the row on the page", context: cited))
        // Without the wearer's words (a live session) the model's reason stands in.
        XCTAssertEqual(SmartCameraPolicy.cameraToolReply(utterance: nil, toolReason: "read the row on the page",
                                                         context: cited), reply)
        XCTAssertEqual(SmartCameraPolicy.cameraToolReply(utterance: "  ", toolReason: "value in Table 99 row 3",
                                                         context: cited), reply)
        // No manual page in play, or no words at all: the tool goes ahead.
        XCTAssertNil(SmartCameraPolicy.cameraToolReply(utterance: "read the row on this page", toolReason: nil,
                                                       context: none))
        XCTAssertNil(SmartCameraPolicy.cameraToolReply(utterance: nil, toolReason: nil, context: cited))
        XCTAssertTrue(reply.contains("table_lookup") && reply.contains("manual_lookup"))
    }

    func testAGlassesCaptureStartsOnlyWithTheLinkUp() {
        XCTAssertTrue(SmartCameraPolicy.mayStartGlassesCapture(linkUp: true))
        XCTAssertFalse(SmartCameraPolicy.mayStartGlassesCapture(linkUp: false))
    }

    // MARK: - A fault code to look up in the manuals (2026-11-07)

    private let vault = SmartCameraPolicy.Context(manualsToSearch: true)

    /// The owner's two turns: each matched "that is", took a glasses frame, and so went to the Vision
    /// model on another provider. With a vault to search they are the manuals' turns.
    func testTheReportedTurnsAreManualTurnsWithAVault() {
        for turn in ["It's the E4 error if you can look what that is on the refrigerator",
                     "Look on the volts for an E4 error and tell me what that is"] {
            XCTAssertEqual(VisionIntentDetector.classify(turn), .vision, "the words alone still read as a look: \(turn)")
            XCTAssertTrue(SmartCameraPolicy.isManualTurn(turn, context: vault), turn)
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: vault), .textOnly, turn)
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: none), .vision, "no manuals, no change: \(turn)")
        }
    }

    func testAFaultCodeOrTheManualsNamedMakeALookUpTurn() {
        for turn in ["tell me what that is, the F21 error", "what is that error 21", "is that code SY1 bad",
                     "look it up in the manual, what that is", "look that up for me, is that right",
                     "check the vault for what that is"] {
            XCTAssertTrue(SmartCameraPolicy.asksToLookUpInManuals(turn, context: vault), turn)
        }
    }

    func testTheCameraAndThingsInFrontOfTheWearerStayCameraTurns() {
        for turn in ["what's this error", "look at this E4 error", "what does the E4 code on the display mean",
                     "read the error code on this nameplate", "is that E4 on the screen", "what is that",
                     "look up at the ceiling, what is that", "can you see the E4 error"] {
            XCTAssertFalse(SmartCameraPolicy.asksToLookUpInManuals(turn, context: vault), turn)
            XCTAssertEqual(SmartCameraPolicy.intent(for: turn, context: vault), VisionIntentDetector.classify(turn), turn)
        }
    }

    func testACodeTokenIsShortLettersThenDigits() {
        for words in [["e4", "error"], ["error", "21"], ["f21", "fault"], ["er10", "code"], ["code", "c3a"]] {
            XCTAssertTrue(SmartCameraPolicy.namesFaultCode(words), "\(words)")
        }
        for words in [["e4"], ["error"], ["error", "12345"], ["fault", "abcd12"], ["code", "4e"], ["error", "e1234"]] {
            XCTAssertFalse(SmartCameraPolicy.namesFaultCode(words), "\(words)")
        }
    }
}
