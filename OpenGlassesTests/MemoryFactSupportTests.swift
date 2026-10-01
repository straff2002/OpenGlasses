import XCTest
@testable import OpenGlasses

/// Plan GG — the pure helpers: tombstone digests, write provenance, resolving a spoken phrase to
/// one fact, note-line matching and the spoken summary.
final class MemoryFactSupportTests: XCTestCase {

    private func fact(_ text: String, _ kind: MemoryFactKind = .semantic(topic: "general"),
                      value: String? = nil, age: TimeInterval = 0,
                      store: MemoryFactStore = .semantic) -> MemoryFact {
        MemoryFact(id: MemoryFactID(store: store, recordID: text), text: text, kind: kind,
                   origin: .toldMe, createdAt: Date(timeIntervalSince1970: 1_800_000_000 - age),
                   correctableValue: value)
    }

    func testTombstoneDigestIsContentFreeAndNormalised() {
        let a = MemoryTombstone.digest("sister_city", "Wellington")
        XCTAssertEqual(a, MemoryTombstone.digest("Sister City", "wellington."))
        XCTAssertNotEqual(a, MemoryTombstone.digest("favourite city", "Wellington"))
        XCTAssertFalse(a.localizedCaseInsensitiveContains("wellington"))
        XCTAssertEqual(a.count, 64)
    }

    func testOriginClassifier() {
        XCTAssertEqual(MemoryOriginClassifier.originForReplyTags(userUtterance: "Remember that I take my tea black"), .toldMe)
        XCTAssertEqual(MemoryOriginClassifier.originForReplyTags(userUtterance: "don’t forget Sam's birthday is May 3"), .toldMe)
        XCTAssertEqual(MemoryOriginClassifier.originForReplyTags(userUtterance: "Actually, she lives in Nelson"), .toldMe)
        XCTAssertEqual(MemoryOriginClassifier.originForReplyTags(userUtterance: "what's the weather"), .inferred)
        XCTAssertEqual(MemoryOriginClassifier.originForReplyTags(userUtterance: nil), .inferred,
                       "background reviews and scheduled tasks have no utterance")
    }

    func testMatcherOneManyNone() {
        let facts = [fact("sister city: Wellington"), fact("brother city: Wellington"),
                     fact("favourite tea: earl grey")]
        XCTAssertEqual(MemoryFactMatcher.candidates(for: "my sister lives in Wellington", in: facts).map(\.text),
                       ["sister city: Wellington"])
        XCTAssertEqual(MemoryFactMatcher.candidates(for: "Wellington", in: facts).count, 2)
        XCTAssertTrue(MemoryFactMatcher.candidates(for: "my car", in: facts).isEmpty)
        XCTAssertTrue(MemoryFactMatcher.candidates(for: "the my", in: facts).isEmpty, "stopwords alone match nothing")
        let tea = [fact("favourite tea: earl grey")]
        XCTAssertEqual(MemoryFactMatcher.candidates(for: "my favourite colour", in: tea).count, 1,
                       "half the words is enough to answer a question")
        XCTAssertTrue(MemoryFactMatcher.candidates(for: "my favourite colour", in: tea,
                                                   minimumShare: MemoryFactMatcher.changeShare).isEmpty,
                      "but not to change anything")
    }

    func testNoteMatcherNeedsTheWholeValueAndBothEndsOfARelation() {
        let lines = ["- Their sister lives in Wellington", "- Maria works at Acme", "- Maria likes Wellington"]
        let semantic = fact("sister city: Wellington", value: "Wellington")
        XCTAssertEqual(MemoryNoteMatcher.lines(lines, mentioning: semantic).count, 2)
        let relation = fact("Maria lives in Wellington",
                            .relation(relation: "lives_in", srcKind: "person", dstKind: "place"),
                            value: "Wellington", store: .brainEdge)
        XCTAssertEqual(MemoryNoteMatcher.lines(lines, mentioning: relation), ["- Maria likes Wellington"])
        XCTAssertTrue(MemoryNoteMatcher.lines(lines, mentioning: fact("pin: 42", value: "42")).isEmpty,
                      "a value too short to match safely matches nothing")
    }

    func testAgentNoteLineParsing() throws {
        let raw = "- Prefers metric units *(learned 2026-09-30T10:00:00Z)*"
        let line = try XCTUnwrap(AgentNoteLine(raw))
        XCTAssertEqual(line.text, "Prefers metric units")
        XCTAssertNotNil(line.learnedAt)
        XCTAssertNil(AgentNoteLine("# Memory"))
        XCTAssertNil(AgentNoteLine("<!-- comment -->"))
        XCTAssertEqual(AgentNoteLine.rewrite(raw, text: "Prefers imperial units"),
                       "- Prefers imperial units *(learned 2026-09-30T10:00:00Z)*")
        let facts = AgentNotesFactSource.facts(fromMemoryDocument: "# Memory\n\(raw)\n\(raw)\n- Other")
        XCTAssertEqual(facts.map(\.text), ["Prefers metric units", "Other"], "duplicate lines are one fact")
    }

    func testSpokenSummaryIsCountsPlusThreeRecent() {
        let facts = [
            fact("a", .semantic(topic: "people"), age: 1), fact("b", .semantic(topic: "places"), age: 2),
            fact("c", .semantic(topic: "places"), age: 3), fact("d", .need, age: 4),
            fact("secret", .semantic(topic: "health"), age: 0),
        ]
        let text = MemorySpokenSummary.summary(facts)
        XCTAssertTrue(text.hasPrefix("I know 4 things about you: 1 about people, 2 places and 1 unfinished thing."), text)
        XCTAssertTrue(text.contains("Most recently: a; b; c."), text)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(MemorySpokenSummary.summary([]).contains("remember that"))
    }
}
