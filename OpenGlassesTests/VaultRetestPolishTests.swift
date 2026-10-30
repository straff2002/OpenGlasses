import XCTest
@testable import OpenGlasses

/// Plan KD P3 — polish after the partner's retest of the code-book vault on build 581.
///
/// Every table number, column and rule here is invented ("Table 97", "Table 98", "Band B", "QX6",
/// rule 99-200); none is from a real code book.
@MainActor
final class VaultRetestPolishTests: XCTestCase {

    // MARK: - A repeated last paragraph is said once

    private let preamble = "I'll read Table 98 for the QX6 run."
    private let answer = "Band B is the column for the QX6 run, and rule 99-200 sets its limit at the second step."

    func testARepeatedLastParagraphIsSaidOnce() {
        let reply = "\(preamble)\n\n\(answer)\n\n\(answer)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(reply), "\(preamble)\n\n\(answer)")
    }

    func testARepeatThatDiffersOnlyInCaseSpacingAndPunctuationIsSaidOnce() {
        let echoed = "band B is the column for the QX6 run  and rule 99-200 sets its limit at the second step"
        let reply = "\(preamble)\n\n\(answer)\n\n\(echoed)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(reply), "\(preamble)\n\n\(answer)")
    }

    func testAReplySaidTwiceWholeIsSaidOnce() {
        XCTAssertEqual(RepeatedReplyCollapse.collapse("\(answer) \(answer)"), answer, "two copies in one paragraph")
        XCTAssertEqual(RepeatedReplyCollapse.collapse("\(preamble) \(answer)\n\n\(preamble) \(answer)"),
                       "\(preamble) \(answer)", "a two-paragraph reply said twice")
        XCTAssertEqual(RepeatedReplyCollapse.collapse("\(answer)\n\n\(answer)\n\n\(answer)"), answer, "three copies")
    }

    func testARepeatedBlockOfParagraphsIsSaidOnce() {
        let second = "Check the QX6 terminal screws before you read the meter on the second step."
        let reply = "\(preamble)\n\n\(answer)\n\n\(second)\n\n\(answer)\n\n\(second)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(reply), "\(preamble)\n\n\(answer)\n\n\(second)")
    }

    func testAChineseReplySaidTwiceIsSaidOnce() {
        let line = "第九十八号表的乙栏适用于这条线路，第二步的限值由规则九十九之二百规定，请先检查左侧面板上的端子螺丝。"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(line + line), line)
    }

    func testDifferentParagraphsAreNeverCollapsed() {
        let other = "Band C is the column for the QX7 run, and rule 99-201 sets its limit at the third step."
        let reply = "\(preamble)\n\n\(answer)\n\n\(other)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(reply), reply)
    }

    func testShortRepeatsAndListItemsAreNeverCollapsed() {
        XCTAssertEqual(RepeatedReplyCollapse.collapse("OK.\n\nOK."), "OK.\n\nOK.")
        XCTAssertEqual(RepeatedReplyCollapse.collapse("Done. Done."), "Done. Done.")
        let item = "- Check the QX6 terminal screws on the left side panel first"
        let list = "Before you start:\n\(item)\n\(item)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(list), list, "a list may repeat an item")
        let numbered = "Steps:\n1. Check the QX6 terminal screws on the left side panel first\n2. Check the QX6 terminal screws on the left side panel first"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(numbered), numbered)
    }

    func testARepeatWithSomethingElseSaidBetweenIsNeverCollapsed() {
        let between = "Band C is the column for the QX7 run instead."
        let separated = "\(answer)\n\n\(between)\n\n\(answer)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(separated), separated)
        let recap = "\(answer)\n\nTo recap: \(answer)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(recap), recap)
    }

    func testAValueThatDiffersIsNotARepeat() {
        let first = "Use the 4/0 row of Table 98 for the QX6 run under rule 99-200 at the second step."
        let second = "Use the 40 row of Table 98 for the QX6 run under rule 99-200 at the second step."
        XCTAssertEqual(RepeatedReplyCollapse.collapse("\(first)\n\n\(second)"), "\(first)\n\n\(second)")
    }

    func testARepeatInsideASentenceIsNotCollapsed() {
        let phrase = "the column for the QX6 run under rule 99-200 at the second step"
        let reply = "Read \(phrase) \(phrase)"
        XCTAssertEqual(RepeatedReplyCollapse.collapse(reply), reply, "the second copy does not start a sentence")
    }

    func testTheHistoryKeepsTheCollapsedReply() {
        let original = "\(answer)\n\n\(answer)"
        let history: [[String: Any]] = [["role": "user", "content": "what does table 98 give"],
                                        ["role": "assistant", "content": original]]
        let fixed = RepeatedReplyCollapse.replacingLastAssistantReply(in: history, original: original, with: answer)
        XCTAssertEqual(fixed.last?["content"] as? String, answer)
        XCTAssertEqual(fixed.first?["content"] as? String, "what does table 98 give")

        let other: [[String: Any]] = [["role": "assistant", "content": "Something else entirely."]]
        let untouched = RepeatedReplyCollapse.replacingLastAssistantReply(in: other, original: original, with: answer)
        XCTAssertEqual(untouched.last?["content"] as? String, "Something else entirely.",
                       "a history entry that is not the reply is left alone")
    }

    /// With the reply streamed to speech, part of the repeat may already have been said when the
    /// collapsed reply arrives: the reply must not then be said again in full.
    func testAStreamedRepeatIsNotSaidAgainInFull() {
        let reply = "Band B is the column. Rule 99-200 sets the limit."
        let spoken = ["Band B is the column.", "Rule 99-200 sets the limit.", "Band B is the column."]
        let reconciled = StreamSpeechGate.reconcile(reply: reply, spoken: spoken)
        XCTAssertTrue(reconciled.spokenIsPartOfReply)
        XCTAssertEqual(reconciled.remainder, "")

        let part = StreamSpeechGate.reconcile(reply: reply + " Check the QX6 first.",
                                              spoken: ["Band B is the column.", "Band B is the column."])
        XCTAssertEqual(part.remainder, "Rule 99-200 sets the limit. Check the QX6 first.")

        let preambleOnly = StreamSpeechGate.reconcile(reply: reply, spoken: ["Let me check that."])
        XCTAssertFalse(preambleOnly.spokenIsPartOfReply, "a preamble the reply does not hold is still a preamble")
        XCTAssertEqual(preambleOnly.remainder, reply)
    }

    // MARK: - A retrieved table goes to the model only under the label asked or looked up

    private typealias Gate = RetrievedFigureLabelGate
    private let modelOnly = FigureAutoOpenPolicy.Decision.attachToModelOnly(reason: .tableNotAskedFor)

    func testATableNamedThisTurnGoesToTheModel() {
        let named = Gate.namedLabels(in: "what does table 98 give for band B on the QX6")
        XCTAssertEqual(named, ["Table 98"])
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .captioned, passageLabel: "Table 98", namedLabels: named),
                       .attachToModelOnly(reason: .labelAsked))
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .tableRow, passageLabel: "TABLE  98", namedLabels: named),
                       .attachToModelOnly(reason: .labelAsked), "labels compare without case or spacing")
    }

    func testTheTableLookedUpGoesToTheModel() {
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .captioned, passageLabel: "Table 98",
                                  namedLabels: [], lookedUpLabels: ["Table 98"]),
                       .attachToModelOnly(reason: .labelAsked))
    }

    func testAnUnrelatedTableIsNotAttached() {
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .captioned, passageLabel: "Table 97",
                                  namedLabels: [], lookedUpLabels: ["Table 98"]),
                       .none(reason: .labelNotAsked))
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .tableRow, passageLabel: "Table 97", namedLabels: []),
                       .none(reason: .labelNotAsked), "nothing named, nothing looked up")
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .captioned, passageLabel: "Tabla 97", namedLabels: []),
                       modelOnly, "only a table's label (\"Table N\", as captions are written) is gated")
    }

    func testACaptionedFigurePassageKeepsItsRule() {
        XCTAssertEqual(Gate.apply(modelOnly, passageKind: .captioned, passageLabel: "Figure 9", namedLabels: []),
                       modelOnly, "a passage naming a figure still reaches the model on a question")
        XCTAssertTrue(Gate.isTable(passageKind: .tableRow, label: nil))
        XCTAssertTrue(Gate.isTable(passageKind: .captioned, label: "Table 98"))
        XCTAssertFalse(Gate.isTable(passageKind: .captioned, label: "Figure 9"))
        XCTAssertFalse(Gate.isTable(passageKind: .diagram, label: "Table 98"), "a drawing is a drawing")
    }

    func testATurnThatNamesATableOpensNoOtherLabel() {
        let named = Gate.namedLabels(in: "show me table 98")
        XCTAssertEqual(Gate.apply(.present(reason: .askedForPage), passageKind: .captioned,
                                  passageLabel: "Table 97", namedLabels: named),
                       .none(reason: .otherLabelNamed))
        XCTAssertEqual(Gate.apply(.present(reason: .askedForPage), passageKind: .captioned,
                                  passageLabel: "Table 98", namedLabels: named),
                       .present(reason: .askedForPage), "the table asked for still opens")
        XCTAssertEqual(Gate.apply(.present(reason: .diagramForQuestion), passageKind: .diagram,
                                  passageLabel: "Figure 3", namedLabels: Gate.namedLabels(in: "what does figure 4 show")),
                       .none(reason: .otherLabelNamed), "a drawing under another label is not the one named")
    }

    func testADrawingKeepsItsOwnRule() {
        XCTAssertEqual(Gate.apply(.present(reason: .diagramForQuestion), passageKind: .diagram,
                                  passageLabel: nil, namedLabels: []),
                       .present(reason: .diagramForQuestion))
        XCTAssertEqual(Gate.apply(.attachToModelOnly(reason: .notAQuestion), passageKind: .diagram,
                                  passageLabel: "Figure 3", namedLabels: []),
                       .attachToModelOnly(reason: .notAQuestion), "a drawing still reaches the model (EK §4)")
        XCTAssertEqual(Gate.apply(.none(reason: .reading), passageKind: .captioned,
                                  passageLabel: "Table 98", namedLabels: ["Table 98"]),
                       .none(reason: .reading), "the gate never widens a decision")
    }

    func testLabelsAreReadTheWayTheAppReadsThem() {
        XCTAssertEqual(Gate.namedLabels(in: "pull up figure 3 and table 95A"), ["Table 95A", "Figure 3"])
        XCTAssertEqual(Gate.namedLabels(in: "what's in table ninety-eight"), ["Table 98"])
        XCTAssertEqual(Gate.figureLabels(in: "see fig. 12a"), ["Figure 12A"])
        XCTAssertEqual(Gate.namedLabels(in: "what size for the QX6 run at band B"), [])
        XCTAssertEqual(Gate.namedLabels(in: "what's the timetable 9 say"), [], "a table word inside another word")
    }

    // MARK: - Only a figure shown on the phone becomes the last shown

    private func figure(_ label: String, page: Int, onPhone: Bool) -> FieldSessionService.StagedFigure {
        FieldSessionService.StagedFigure(documentId: "doc-polish", documentTitle: "Invented Code Book",
                                         page: page, figure: label, sourceFile: "book.pdf",
                                         origin: onPhone ? .requested : .automatic, presentOnPhone: onPhone)
    }

    private func makeService() -> FieldSessionService {
        FieldSessionService(sessionsRoot: FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultRetestPolishTests-\(UUID().uuidString)", isDirectory: true))
    }

    func testAPageStagedForTheModelOnlyIsNeverTheLastShown() {
        let service = makeService()
        service.stageFigure(figure("Table 97", page: 41, onPhone: false))
        XCTAssertEqual(service.stagedFigure?.figure, "Table 97", "the model still gets it this turn")
        XCTAssertNil(service.lastShownFigure, "the technician never saw it")
        XCTAssertNil(service.restageLastFigure(), "so “show that again” has nothing to reopen")
    }

    func testShowThatAgainReopensThePageThatWasShown() {
        let service = makeService()
        service.stageFigure(figure("Table 98", page: 42, onPhone: true))
        service.stageFigure(figure("Table 97", page: 41, onPhone: false))
        XCTAssertEqual(service.lastShownFigure?.figure, "Table 98", "a model-only page does not replace it")
        service.stageFigure(nil)

        let again = service.restageLastFigure()
        XCTAssertEqual(again?.figure, "Table 98")
        XCTAssertEqual(again?.presentOnPhone, true)
        XCTAssertEqual(service.stagedFigure?.figure, "Table 98")
    }

    func testAPageShowSourceOpenedIsTheLastShown() {
        let service = makeService()
        service.noteShownOnPhone(figure("Table 98", page: 42, onPhone: true))
        XCTAssertEqual(service.restageLastFigure()?.figure, "Table 98")
    }

    func testTheTableLookedUpIsRemembered() {
        let service = makeService()
        XCTAssertNil(service.lookedUpTableLabel)
        service.noteLookedUpTable("Table 98")
        service.noteLookedUpTable("  ")
        XCTAssertEqual(service.lookedUpTableLabel, "Table 98", "an empty label changes nothing")
        service.noteLookedUpTable("Table 97")
        XCTAssertEqual(service.lookedUpTableLabel, "Table 97", "the latest lookup is the one kept")
    }

    // MARK: - The chain list stays English

    func testTheChainListIsEnglishForTheModelAndTheTechnicianAlike() {
        let spoken = RuleChainTool.spokenList(["• Size a run (\(RuleChainTool.runningMark))"], problems: 1)
        XCTAssertEqual(spoken, """
        Rule chains in this vault:
        • Size a run (running now)
        Some of the vault's chains have problems and aren't offered.
        Say a chain's name to run it.
        """)
    }
}
