import XCTest
@testable import OpenGlasses

/// How the recorded-session rules read words, against the tables in `agreement-v1.json`.
final class RecordingTextTests: XCTestCase {
    private typealias F = RecordedJobFixtures

    private func rules() throws -> [String: Any] {
        try XCTUnwrap(F.object("agreement-v1")["rules"] as? [String: Any])
    }

    func testTheFixturesWordListsAreTheListsInTheCode() throws {
        let rules = try rules()
        let stopWords = try XCTUnwrap(rules["stopWords"] as? [String])
        XCTAssertEqual(Set(stopWords), RecordingText.stopWords)
        XCTAssertEqual(stopWords.count, RecordingText.stopWords.count, "no word twice")
        let negators = try XCTUnwrap(rules["negators"] as? [String])
        XCTAssertEqual(Set(negators), RecordingText.negators)
        XCTAssertEqual(negators.count, RecordingText.negators.count, "no word twice")
        XCTAssertEqual(Set(try XCTUnwrap(rules["clauseBreakCharacters"] as? [String])),
                       Set(RecordingText.clauseBreakCharacters.map { String($0) }))
        XCTAssertEqual(Set(try XCTUnwrap(rules["clauseBreakWords"] as? [String])), RecordingText.clauseBreakWords)
        XCTAssertEqual(rules["minimumWordLength"] as? Int, RecordingText.minimumWordLength)
    }

    func testTheListsHoldOnlyWordsAsTheReaderMakesThem() {
        // A list entry the reader could never produce would silently match nothing.
        for word in RecordingText.stopWords.union(RecordingText.negators).union(RecordingText.clauseBreakWords) {
            XCTAssertEqual(RecordingText.words(word), [word], word)
        }
        XCTAssertTrue(RecordingText.stopWords.isDisjoint(with: RecordingText.negators))
    }

    func testEveryTextInTheFixtureGivesItsStems() throws {
        let table = try XCTUnwrap(F.object("agreement-v1")["words"] as? [[String: Any]])
        XCTAssertEqual(table.count, 8)
        for row in table {
            let text = try XCTUnwrap(row["text"] as? String)
            XCTAssertEqual(RecordingText.contentStems(text), Set(try XCTUnwrap(row["contentStems"] as? [String])), text)
            XCTAssertEqual(RecordingText.affirmedStems(text), Set(try XCTUnwrap(row["affirmedStems"] as? [String])), text)
        }
    }

    func testEveryWordInTheFixtureGivesItsStem() throws {
        let table = try XCTUnwrap(F.object("agreement-v1")["stems"] as? [String: String])
        XCTAssertEqual(table.count, 38)
        for (word, stem) in table {
            XCTAssertEqual(RecordingText.stem(word), stem, word)
        }
    }

    func testAWordIsARunOfUnaccentedLettersAndDigits() {
        XCTAssertEqual(RecordingText.words("Don't touch the M8 bolt — it's 3.5 Nm!"),
                       ["dont", "touch", "the", "m8", "bolt", "its", "3", "5", "nm"])
        XCTAssertEqual(RecordingText.words("the technician\u{2019}s"), ["the", "technicians"])
        XCTAssertEqual(RecordingText.words("naïve Größe"), ["na", "ve", "gr", "e"], "only a–z and 0–9 make words")
        XCTAssertEqual(RecordingText.words("  …  "), [])
        XCTAssertEqual(RecordingText.words(""), [])
    }

    func testClausesEndAtPunctuationAndAtBut() {
        XCTAssertEqual(RecordingText.clauses("Don't worry, remove the cover now."),
                       [["dont", "worry"], ["remove", "the", "cover", "now"]])
        XCTAssertEqual(RecordingText.clauses("Not that one but this one"),
                       [["not", "that", "one"], ["but", "this", "one"]])
        XCTAssertEqual(RecordingText.clauses("a; b: c! d? e"), [["a"], ["b"], ["c"], ["d"], ["e"]])
    }

    func testAWordSaidBothWaysCountsAsSaid() {
        XCTAssertEqual(RecordingText.affirmedStems("Don't remove the cover yet. Okay, now remove the cover."),
                       ["remov", "cover"])
    }

    func testStemmingIsStable() {
        // A stem stems to itself wherever it is long enough to be looked at again, so a list of
        // stems can be compared with freshly made ones.
        for word in ["remov", "cover", "tighten", "fit", "unplug", "press", "battery", "switch", "seal", "bleed"] {
            XCTAssertEqual(RecordingText.stem(word), word, word)
        }
    }
}
