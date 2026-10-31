import XCTest
@testable import OpenGlasses

/// Plan BI — one bounded, transparent, never-worse-than-today web-grounded re-ask.
final class UncertaintyReaskTests: XCTestCase {

    private struct TestError: Error {}

    func testHappyPathGroundsRegeneratesOnceAndPrefixes() async {
        let regenerateCalls = Box<[String]>([])
        let result = await UncertaintyReask.answer(
            question: "What's the latest Swift version?",
            originalAnswer: "I think it's 5.9 but I'm not sure.", vaultOnly: false,
            search: { query in
                XCTAssertEqual(query, "What's the latest Swift version?")
                return "Swift 6.2 was released in June 2026."
            },
            regenerate: { grounding in
                regenerateCalls.value.append(grounding)
                return "The latest Swift version is 6.2."
            }
        )
        XCTAssertEqual(result, UncertaintyReask.transparencyPrefix + "The latest Swift version is 6.2.",
                       "the re-grounded answer must carry the transparency prefix — never a silent swap")
        XCTAssertEqual(regenerateCalls.value.count, 1, "exactly one regeneration — no loops")
        XCTAssertTrue(regenerateCalls.value[0].contains("Swift 6.2 was released"),
                      "search results are spliced into the grounding prompt")
        XCTAssertTrue(regenerateCalls.value[0].contains("What's the latest Swift version?"),
                      "the original question is restated in the grounding prompt")
    }

    func testEmptySearchReturnsOriginalWithoutRegenerating() async {
        let regenerated = Box<[String]>([])
        let result = await UncertaintyReask.answer(
            question: "q", originalAnswer: "original", vaultOnly: false,
            search: { _ in "   \n " },
            regenerate: { g in regenerated.value.append(g); return "should not happen" }
        )
        XCTAssertEqual(result, "original")
        XCTAssertTrue(regenerated.value.isEmpty)
    }

    func testNilSearchReturnsOriginal() async {
        let result = await UncertaintyReask.answer(
            question: "q", originalAnswer: "original", vaultOnly: false,
            search: { _ in nil },
            regenerate: { _ in "should not happen" }
        )
        XCTAssertEqual(result, "original")
    }

    func testSearchThrowReturnsOriginal() async {
        let result = await UncertaintyReask.answer(
            question: "q", originalAnswer: "original", vaultOnly: false,
            search: { _ in throw TestError() },
            regenerate: { _ in "should not happen" }
        )
        XCTAssertEqual(result, "original", "a failed search must never make the answer worse")
    }

    func testRegenerateThrowReturnsOriginal() async {
        let result = await UncertaintyReask.answer(
            question: "q", originalAnswer: "original", vaultOnly: false,
            search: { _ in "some results" },
            regenerate: { _ in throw TestError() }
        )
        XCTAssertEqual(result, "original")
    }

    func testEmptyRegenerationReturnsOriginal() async {
        let result = await UncertaintyReask.answer(
            question: "q", originalAnswer: "original", vaultOnly: false,
            search: { _ in "some results" },
            regenerate: { _ in "  \n" }
        )
        XCTAssertEqual(result, "original")
    }

    // MARK: - Conversation-aware follow-ups

    private let semiFinalHistory: [(role: String, content: String)] = [
        (role: "user", content: "Who's playing in the world cup semi finals?"),
        (role: "assistant", content: "Argentina play France on Tuesday."),
    ]

    func testContextDependentHeuristic() {
        XCTAssertTrue(UncertaintyReask.isContextDependent("what about the other semi final?"),
                      "anaphor 'other' leans on the conversation")
        XCTAssertTrue(UncertaintyReask.isContextDependent("who won?"), "too short to name its subject")
        XCTAssertTrue(UncertaintyReask.isContextDependent("when do they play again?"))
        XCTAssertFalse(UncertaintyReask.isContextDependent("who is playing in the world cup semi finals tomorrow"),
                       "a self-contained question needs no rewrite")
    }

    func testFollowUpSearchesRewrittenQueryAndGroundsWithConversation() async {
        let searchedQuery = Box<[String]>([])
        let groundings = Box<[String]>([])
        let result = await UncertaintyReask.answer(
            question: "what about the other semi final?",
            originalAnswer: "I'm not sure.", vaultOnly: false,
            history: semiFinalHistory,
            search: { query in
                searchedQuery.value.append(query)
                return "England play Spain on Wednesday."
            },
            rewriteQuery: { _ in "world cup 2026 second semi final teams" },
            regenerate: { grounding in
                groundings.value.append(grounding)
                return "The other semi final is England v Spain on Wednesday."
            }
        )
        XCTAssertEqual(searchedQuery.value, ["world cup 2026 second semi final teams"],
                       "the rewritten self-contained query is searched, not the raw follow-up")
        XCTAssertTrue(groundings.value[0].contains("Argentina play France"),
                      "the grounding prompt carries the recent conversation for reconciliation")
        XCTAssertTrue(result.hasPrefix(UncertaintyReask.transparencyPrefix))
    }

    func testRewriteFailureFallsBackToRawQuestion() async {
        let searchedQuery = Box<[String]>([])
        _ = await UncertaintyReask.answer(
            question: "what about the other semi final?",
            originalAnswer: "original", vaultOnly: false,
            history: semiFinalHistory,
            search: { query in searchedQuery.value.append(query); return nil },
            rewriteQuery: { _ in throw TestError() },
            regenerate: { _ in "unused" }
        )
        XCTAssertEqual(searchedQuery.value, ["what about the other semi final?"],
                       "a failed rewrite must never block the search — raw question is used")
    }

    func testSelfContainedQuestionSkipsRewrite() async {
        let rewriteCalls = Box<[String]>([])
        _ = await UncertaintyReask.answer(
            question: "who is playing in the world cup semi finals tomorrow",
            originalAnswer: "original", vaultOnly: false,
            history: semiFinalHistory,
            search: { _ in nil },
            rewriteQuery: { q in rewriteCalls.value.append(q); return "unused" },
            regenerate: { _ in "unused" }
        )
        XCTAssertTrue(rewriteCalls.value.isEmpty, "no rewrite generation spent on a standalone question")
    }

    func testCleanedRewrittenQuery() {
        XCTAssertEqual(UncertaintyReask.cleanedRewrittenQuery("\"world cup semi finals\""), "world cup semi finals")
        XCTAssertEqual(UncertaintyReask.cleanedRewrittenQuery("Query: fifa semi final schedule\nExtra line"),
                       "fifa semi final schedule")
        XCTAssertNil(UncertaintyReask.cleanedRewrittenQuery("  \n"), "empty rewrite → fall back")
        XCTAssertNil(UncertaintyReask.cleanedRewrittenQuery(String(repeating: "a", count: 200)),
                     "an answer-length blob is not a query → fall back")
        XCTAssertNil(UncertaintyReask.cleanedRewrittenQuery(nil))
    }
}
