import XCTest
@testable import OpenGlasses

/// The ranking features written out for the local eval (Plan KN P1): computed from what the
/// retriever already holds, identical run to run, never changing the order or the outcome, and
/// exported as numbers only. Every manual, model, code and sentence here is invented.
@MainActor
final class RankingFeaturesTests: XCTestCase {

    private static let title = "QX100 Service Guide"

    private func raw(_ index: Int, _ text: String, section: String?, similarity: Float,
                     kind: DocumentChunker.Kind = .prose) -> DocumentStore.Passage {
        DocumentStore.Passage(documentId: "qx-guide", documentName: Self.title, chunkIndex: index, text: text,
                              similarity: similarity, page: index + 1, section: section, kind: kind)
    }

    /// An invented service guide for an invented unit.
    private var manual: [DocumentStore.Passage] {
        [
            raw(0, "Lift the drain tray out and rinse it under warm water before refitting.", section: "Drain tray",
                similarity: 0.62),
            raw(1, "Code E99 means the float switch is stuck. Free the float and restart the QX100.",
                section: "Fault codes", similarity: 0.48),
            raw(2, "Wipe the door seal with a soft cloth each month.", section: "Door seal", similarity: 0.55),
            raw(3, "QX100 QX200 ratings sheet", section: nil, similarity: 0.40, kind: .diagram),
            raw(4, "Rinse filter monthly: QX100 yes, QX200 yes.", section: "Filter chart", similarity: 0.44,
                kind: .tableRow),
        ]
    }

    private var statistics: LexicalSupport.TermStatistics {
        manual.reduce(into: LexicalSupport.TermStatistics()) { $0.add(text: $1.text, heading: $1.section) }
    }

    /// The routes the app builds, over the invented guide: meaning returns every page by its
    /// similarity, the token and word routes what prints the token or shares a word.
    private func retriever(policy: RetrievalEvidencePolicy,
                           meaning: [DocumentStore.Passage]? = nil,
                           tokens: [DocumentStore.Passage]? = nil,
                           words: Bool = true) -> VaultRetriever {
        let pages = manual
        let byMeaning = meaning ?? pages
        let byToken = tokens ?? pages
        let stats = statistics
        return VaultRetriever(
            query: { _, limit in Array(byMeaning.sorted { $0.similarity > $1.similarity }.prefix(limit)) },
            tokenSearch: { token, limit in Array(byToken.filter { CodeTokenizer.contains($0.text, token: token) }.prefix(limit)) },
            termSearch: words ? { query, limit in
                let terms = LexicalSupport.contentTerms(query)
                return Array(pages.filter { LexicalSupport.sharedTermCount(text: $0.text, queryTerms: terms) > 0 }.prefix(limit))
            } : nil,
            termStatistics: { stats },
            policy: policy,
            modelNames: { ["QX100", "QX200"].contains($0.uppercased()) })
    }

    private let requests: [VaultRetriever.Request] = [
        .init(turn: "what does code E99 mean", limit: 4),
        .init(turn: "how do I rinse the drain tray", limit: 4),
        .init(turn: "QX100", limit: 4),
        .init(turn: "what time does the shop open on a holiday", limit: 4),
        .init(turn: "how do I rinse the drain tray", limit: 30),
    ]

    private var shippedGate: RetrievalEvidencePolicy { .default(for: "nl-word.en") }
    /// Every candidate passes: the outcome is the whole ranked list.
    private var noGate: RetrievalEvidencePolicy { RetrievalEvidencePolicy(similarityFloor: -.infinity) }

    // MARK: - Determinism

    func testTheFeaturesAreIdenticalAcrossTwoRunsOnTheSameStore() {
        for request in requests {
            let first = retriever(policy: shippedGate).rankedCandidates(request)
            let second = retriever(policy: shippedGate).rankedCandidates(request)
            XCTAssertFalse(first.isEmpty, "every request finds something to rank")
            XCTAssertEqual(first, second)
        }
    }

    // MARK: - The order is today's

    func testTheOrderAndOutcomeAreTheSameWithAndWithoutTheFeatures() {
        for policy in [shippedGate, noGate] {
            let subject = retriever(policy: policy)
            for request in requests {
                XCTAssertEqual(subject.retrieveWithFeatures(request).outcome, subject.retrieve(request))
            }
        }
        // With no gate the outcome is every candidate, so the ranked list is today's order.
        let open = retriever(policy: noGate)
        for request in requests.map({ VaultRetriever.Request(turn: $0.turn, limit: 100) }) {
            XCTAssertEqual(open.rankedCandidates(request).map(\.passage), open.retrieve(request).passages)
        }
    }

    func testTheRequestsCoverACodeAProseQuestionABareModelAndOneOutOfScope() {
        let subject = retriever(policy: shippedGate)
        let code = subject.retrieve(requests[0])
        XCTAssertEqual(code.passages.first?.chunkIndex, 1, "the page printing the code leads")
        XCTAssertTrue(subject.retrieve(requests[1]).isSufficient)
        XCTAssertTrue(subject.retrieve(requests[2]).isSufficient, "a model asked for alone is answered by its page")
        XCTAssertFalse(subject.retrieve(requests[3]).isSufficient, "the shop's hours are not in the guide")
        let coded = subject.rankedCandidates(requests[0])
        XCTAssertEqual(coded.first?.features.matchedTokens, 1)
        XCTAssertEqual(coded.first?.features.group, 1)
    }

    // MARK: - The values

    func testTheValuesComeFromWhatTheSortHeld() throws {
        let candidates = retriever(policy: noGate).rankedCandidates(.init(turn: "how do I rinse the drain tray", limit: 4))
        let tray = try XCTUnwrap(candidates.first { $0.passage.chunkIndex == 0 }).features
        XCTAssertEqual(candidates.first?.passage.chunkIndex, 0)
        XCTAssertEqual(tray.similarityRank, 0, "the best similarity is place 0")
        XCTAssertEqual(tray.similarityGap, 0)
        XCTAssertTrue(tray.lexicalWeighed)
        XCTAssertGreaterThan(tray.lexical, 0)
        XCTAssertEqual(tray.sharedTerms, 3, "rinse, drain, tray")
        XCTAssertEqual(tray.sharedFraction, 1)
        XCTAssertTrue(tray.headingHasQuestionTerm)
        XCTAssertEqual(tray.kind, 0)
        XCTAssertTrue(tray.isReference)
        XCTAssertEqual(tray.characters, manual[0].text.count)
        let seal = try XCTUnwrap(candidates.first { $0.passage.chunkIndex == 2 }).features
        XCTAssertEqual(seal.similarityRank, 1)
        XCTAssertEqual(seal.similarityGap, Double(Float(0.62) - Float(0.55)), accuracy: 1e-9)
        XCTAssertFalse(seal.headingHasQuestionTerm)
        let row = try XCTUnwrap(candidates.first { $0.passage.chunkIndex == 4 }).features
        XCTAssertEqual(row.kind, 1)
        XCTAssertEqual(RankingFeatures.code(for: .diagram), 2)
    }

    // MARK: - The routes

    func testTheRouteFlagsSayWhichSearchesFoundEachPassage() throws {
        let pages = manual
        // Meaning finds the tray page and the code page; the token search finds the code page and
        // the chart row.
        let subject = retriever(policy: noGate, meaning: [pages[0], pages[1]], tokens: [pages[1], pages[4]], words: false)
        let candidates = subject.rankedCandidates(.init(turn: "QX100 E99", limit: 4))
        func routes(_ chunk: Int) throws -> RankingFeatures {
            try XCTUnwrap(candidates.first { $0.passage.chunkIndex == chunk }, "chunk \(chunk)").features
        }
        XCTAssertEqual(try routes(0).routes, [.meaning])
        XCTAssertEqual(try routes(4).routes, [.token])
        XCTAssertEqual(try routes(1).routes, [.meaning, .token])

        let both = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try routes(1))) as? [String: Any]
        XCTAssertEqual(both?["byMeaning"] as? Bool, true)
        XCTAssertEqual(both?["byToken"] as? Bool, true)
        XCTAssertEqual(both?["byWords"] as? Bool, false)
        XCTAssertEqual(both?["routeCount"] as? Int, 2)
        let tokenOnly = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try routes(4))) as? [String: Any]
        XCTAssertEqual(tokenOnly?["byMeaning"] as? Bool, false)
        XCTAssertEqual(tokenOnly?["routeCount"] as? Int, 1)
    }

    func testTheFeaturesRoundTrip() throws {
        for candidate in retriever(policy: noGate).rankedCandidates(requests[0]) {
            let data = try JSONEncoder().encode(candidate.features)
            XCTAssertEqual(try JSONDecoder().decode(RankingFeatures.self, from: data), candidate.features)
        }
    }

    // MARK: - The export line

    private let embedderId = "nl-word.en"

    private var key: [RetrievalEval.Question] {
        [
            RetrievalEval.Question(q: "how do I rinse the drain tray", pages: [Self.title: [1]]),
            RetrievalEval.Question(q: "what does code E99 mean on the QX100", pages: [Self.title: [2]]),
            RetrievalEval.Question(q: "a question with nothing to score"),
            RetrievalEval.Question(q: "what time does the shop open on a holiday", outOfScope: true),
        ]
    }

    private func lines() -> [RetrievalEval.FeatureLine] {
        RetrievalEval.featureLines(key, openFor: { _ in self.retriever(policy: self.noGate) }, family: 7,
                                   embedder: embedderId, documentIndex: { $0 == "qx-guide" ? 1 : nil })
    }

    func testTheLinesCoverScoredAndOutOfScopeQuestionsWithTheirLabels() {
        let lines = lines()
        XCTAssertEqual(Set(lines.map(\.q)), [1, 2, 4], "the unscorable question is left out; numbers are key lines")
        for q in [1, 2, 4] {
            XCTAssertEqual(lines.filter { $0.q == q }.map(\.rank), Array(0..<lines.filter { $0.q == q }.count))
        }
        XCTAssertEqual(lines.filter { $0.q == 1 && $0.label == 1 }.map(\.chunk), [0])
        XCTAssertEqual(lines.filter { $0.q == 2 && $0.label == 1 }.map(\.chunk), [1])
        XCTAssertTrue(lines.filter { $0.q == 4 }.allSatisfy { $0.label == nil && $0.oos })
        XCTAssertTrue(lines.allSatisfy { $0.family == 7 && $0.doc == 1 && $0.schema == RankingFeatures.schemaVersion })
    }

    func testALineHasNoStringBeyondItsFixedKeys() throws {
        let allowed = Set(RetrievalEval.FeatureLine.fixedKeys + RankingFeatures.keys)
        for line in lines() {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try line.encoded().utf8)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), allowed)
            for (key, value) in object {
                if key == "embedder" {
                    XCTAssertEqual(value as? String, embedderId)
                } else {
                    XCTAssertTrue(value is NSNumber || value is NSNull, "\(key) is a number, a flag or null")
                }
            }
            XCTAssertEqual(object["label"] is NSNull, line.oos)
        }
    }

    func testALineHoldsNoneOfTheManualsWordsNorItsTitle() throws {
        let manualText = manual.map { $0.text + " " + ($0.section ?? "") }.joined(separator: " ") + " " + Self.title
        let words = Set(manualText.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 3 })
        XCTAssertTrue(words.contains("drain") && words.contains("qx100"), "the fixture's words are collected")
        let keys = (RetrievalEval.FeatureLine.fixedKeys + RankingFeatures.keys).sorted { $0.count > $1.count }
        let encoded = try lines().map { try $0.encoded() }
        XCTAssertFalse(encoded.isEmpty)
        for line in encoded {
            XCTAssertFalse(line.contains(Self.title))
            XCTAssertFalse(line.contains("qx-guide"), "the document id is never written")
            // What is left once the keys, the flags and the embedder's id are taken out is numbers.
            var rest = line
            for key in keys { rest = rest.replacingOccurrences(of: "\"\(key)\":", with: "") }
            for literal in ["true", "false", "null", "\"\(embedderId)\""] { rest = rest.replacingOccurrences(of: literal, with: "") }
            rest = rest.replacingOccurrences(of: #"(?<=\d)[eE](?=[+-]?\d)"#, with: "", options: .regularExpression)
            // The key's questions are gone with every other letter.
            XCTAssertNil(rest.rangeOfCharacter(from: .letters), "only numbers remain: \(rest)")
            // And no word of the manual is in the line as written, keys and all.
            let lowered = line.lowercased()
            for word in words { XCTAssertFalse(lowered.contains(word), "a manual word is in a line: \(word)") }
        }
    }
}
