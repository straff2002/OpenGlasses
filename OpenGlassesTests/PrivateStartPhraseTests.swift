import XCTest
@testable import OpenGlasses

/// Plan LU P0 §2 — the start and end phrases, pinned by a corpus of sentences that should and
/// shouldn't match.
final class PrivateStartPhraseTests: XCTestCase {

    // MARK: - The corpus

    /// Sentences that start a private conversation, and what is left as its first question.
    private let starts: [(String, PrivateStartPhrase.Remainder)] = [
        ("Off the record, is a mole that's changed shape something to see a doctor about?",
         .question("is a mole that's changed shape something to see a doctor about?")),
        ("off the record: what should I get my sister for her birthday",
         .question("what should I get my sister for her birthday")),
        ("Off the record. How do I ask for a pay rise?", .question("How do I ask for a pay rise?")),
        ("Off-the-record, what's a fair price for a used car?", .question("what's a fair price for a used car?")),
        ("OFF THE RECORD", .nothingFollowed),
        ("Off the record.", .nothingFollowed),
        ("Go private, I need to ask about a loan", .question("I need to ask about a loan")),
        ("Go private please", .nothingFollowed),
        ("go private please, what does this rash look like", .question("what does this rash look like")),
        ("Go private please tell me about debt counselling", .question("tell me about debt counselling")),
        ("Private conversation: my colleague keeps taking credit for my work",
         .question("my colleague keeps taking credit for my work")),
        ("Private conversation", .nothingFollowed),
        ("Privately, how much should a funeral cost?", .question("how much should a funeral cost?")),
        ("Privately.", .nothingFollowed),
        ("Privately - is this lump worth worrying about", .question("is this lump worth worrying about")),
        ("Just between us, I think I'm burning out", .question("I think I'm burning out")),
        ("Just between us!", .nothingFollowed),
        ("This is private: what's the number for a crisis line?", .question("what's the number for a crisis line?")),
        ("This is private. I'm worried about money", .question("I'm worried about money")),
        ("Hey Avenkin, off the record, can you check something for me",
         .question("can you check something for me")),
        ("Avenkin off the record", .nothingFollowed),
        ("  ...Off the record ,  what about tax  ", .question("what about tax")),
    ]

    /// Sentences that must not start a private conversation.
    private let ordinary: [String] = [
        "Private school fees are due next week",
        "Is this private property?",
        "Privately owned companies don't publish accounts",
        "privately-owned land near the river",
        "What does off the record mean?",
        "Can we go private with this company",
        "Private conversations are hard to find at work",
        "This is private property, isn't it",
        "This is private?",
        "Off the record?",
        "Just between us two there's a problem",
        "Tell me something off the record",
        "Go privately to the meeting",
        "Record this off the cuff",
        "",
        "   ",
    ]

    func testTheStartCorpus() {
        for (utterance, remainder) in starts {
            XCTAssertEqual(PrivateStartPhrase.match(utterance, wakePhrases: ["avenkin"]),
                           .start(remainder), utterance)
        }
    }

    func testOrdinarySentencesDoNotMatch() {
        for utterance in ordinary {
            XCTAssertNil(PrivateStartPhrase.match(utterance, wakePhrases: ["avenkin"]), utterance)
        }
    }

    func testTheCorpusIsAboutThirtySentences() {
        XCTAssertGreaterThanOrEqual(starts.count + ordinary.count + endCorpus.count, 30)
    }

    // MARK: - The end phrases

    private let endCorpus: [(String, PrivateStartPhrase.Remainder)] = [
        ("End private", .nothingFollowed),
        ("end private.", .nothingFollowed),
        ("Stop private", .nothingFollowed),
        ("Back on the record", .nothingFollowed),
        ("Back on the record, what's the weather tomorrow?", .question("what's the weather tomorrow?")),
        ("End private conversation", .nothingFollowed),
        ("Stop private conversation please", .nothingFollowed),
        ("Hey Avenkin, end private", .nothingFollowed),
    ]

    func testTheEndPhrases() {
        for (utterance, remainder) in endCorpus {
            XCTAssertEqual(PrivateStartPhrase.match(utterance, wakePhrases: ["avenkin"]),
                           .end(remainder), utterance)
        }
    }

    func testEndPhrasesMidSentenceDoNotMatch() {
        XCTAssertNil(PrivateStartPhrase.match("When does the private sale end privately?"))
        XCTAssertNil(PrivateStartPhrase.match("Stop private messages from strangers"))
        XCTAssertNil(PrivateStartPhrase.match("I want to get back on the record label's list"))
    }

    // MARK: - The wake phrase

    /// A leading wake phrase is skipped only when the caller says it is one.
    func testALeadingWakePhraseIsSkippedOnlyWhenConfigured() {
        XCTAssertNil(PrivateStartPhrase.match("Avenkin, off the record"))
        XCTAssertEqual(PrivateStartPhrase.match("Avenkin, off the record", wakePhrases: ["avenkin"]),
                       .start(.nothingFollowed))
        XCTAssertEqual(PrivateStartPhrase.match("OK Jarvis off the record, a question",
                                                wakePhrases: ["jarvis"]),
                       .start(.question("a question")))
        XCTAssertEqual(PrivateStartPhrase.match("Hey Avenkin off the record", wakePhrases: ["hey avenkin"]),
                       .start(.nothingFollowed))
    }

    // MARK: - Languages

    func testEnglishLocalesMatch() {
        for locale in ["en", "en-GB", "en_NZ", "EN-us"] {
            XCTAssertEqual(PrivateStartPhrase.match("Off the record", language: locale),
                           .start(.nothingFollowed), locale)
        }
    }

    /// Other languages get their phrases after review; until then they match nothing, even an
    /// English phrase.
    func testOtherLanguagesMatchNothingYet() {
        for locale in ["de-DE", "fr", "ja-JP", "zh-Hans", "es"] {
            XCTAssertNil(PrivateStartPhrase.phraseSet(forLanguage: locale), locale)
            XCTAssertNil(PrivateStartPhrase.match("Off the record, a question", language: locale), locale)
        }
    }
}
