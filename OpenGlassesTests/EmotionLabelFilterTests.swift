import XCTest
@testable import OpenGlasses

/// Plan HR P1 item 2 — the filter that keeps Social mode on the observation side of Article 3(39).
///
/// Two tables of sentences, both ways. The pass table is the substance: the observation vocabulary
/// the prompt asks for, and the physical states that are not emotions, must never be flagged —
/// a filter that refuses "smiling" refuses the product. The pass table is a test, not an allowlist:
/// nothing in it appears in the filter's own tables.
final class EmotionLabelFilterTests: XCTestCase {

    /// What Social mode is supposed to say. Each must be an `.observation`.
    private let observations = [
        "They're smiling and looking at you.",
        "Frowning, with their mouth turned down.",
        "Brow raised, eyes narrowed, looking at their phone.",
        "Looking away from you, toward the door.",
        "Arms crossed, standing still.",
        "Leaning in and talking to you.",
        "Stepping back from the counter.",
        "Waving you over and pointing at the table.",
        "Waiting by the till, looking at you.",
        "They are laughing with the person next to them.",
        "Crying, holding a tissue.",
        "Shouting and waving both arms.",
        "Nodding while you talk.",
        "Looking down at the floor.",
        "Mouth open, eyebrows raised.",
        "Looks tired, rubbing their eyes.",
        "Looks cold and is shivering.",
        "Holding their knee; they may be in pain.",
        "Yawning and checking the time.",
        "Reading the content on their screen.",
        "Standing close, about a metre away.",
        // Follow-ups address the wearer, and a question to them must pass.
        "Want me to keep watching?",
        "Should I describe their posture?",
    ]

    /// What Social mode must never say, with one entry each that the filter must report.
    private let inferences: [(String, String)] = [
        ("They look upset.", "upset"),
        ("She seems happy to see you.", "happy"),
        ("He is angry.", "angry"),
        ("She's anxious.", "anxious"),
        ("There is anxiety in his face.", "anxiety"),
        ("Visibly frustrated.", "frustrated"),
        ("Frustration is showing.", "frustration"),
        ("She seems to feel nervous.", "seems to feel"),
        ("He is feeling uneasy.", "is feeling"),
        ("She wants to talk to you.", "wants to"),
        ("He is about to leave.", "about to"),
        ("They are in a bad mood.", "mood"),
        ("They seem friendly.", "friendly"),
        ("Hostile body language.", "hostile"),
        ("He looks bored.", "bored"),
        ("Excited to see you.", "excited"),
        ("The child looks scared.", "scared"),
        ("She looks annoyed.", "annoyed"),
        ("He seems irritated by the queue.", "irritated"),
        ("They look distressed.", "distressed"),
        ("Sadly, she is looking away.", "sadly"),
        ("Their gladness is obvious.", "glad"),
        ("He seems calm and relaxed.", "calm"),
        ("She is trying to get your attention.", "trying to"),
        ("He feels embarrassed.", "feels"),
        ("A sign of depression.", "depression"),
    ]

    func testTheObservationVocabularyPasses() {
        for sentence in observations {
            XCTAssertEqual(EmotionLabelFilter.check(sentence), .observation, sentence)
        }
    }

    func testEmotionalStatesAndIntentionsFail() {
        for (sentence, expected) in inferences {
            guard case .inference(let matched) = EmotionLabelFilter.check(sentence) else {
                XCTFail("passed but names a feeling or an intention: \(sentence)")
                continue
            }
            XCTAssertTrue(matched.contains(expected), "\(sentence) matched \(matched), not \(expected)")
        }
    }

    /// The near misses the plan names: a physical state passes, an emotional one fails.
    func testPhysicalStatesPassAndEmotionalStatesFail() {
        XCTAssertTrue(EmotionLabelFilter.check("They look tired.").isObservation)
        XCTAssertTrue(EmotionLabelFilter.check("They look cold.").isObservation)
        XCTAssertTrue(EmotionLabelFilter.check("They seem to be in pain.").isObservation)
        XCTAssertFalse(EmotionLabelFilter.check("They look upset.").isObservation)
        XCTAssertFalse(EmotionLabelFilter.check("They look sad.").isObservation)
    }

    /// Stemming: one family catches its forms, and a stripped plural or adverb is caught too.
    func testSimpleStemmingCatchesTheFamily() {
        for word in ["anxious", "anxiety", "anxiously", "frustrated", "frustration", "frustrating",
                     "happily", "happiness", "moods", "feelings", "gladness", "proudly"] {
            XCTAssertFalse(EmotionLabelFilter.check("They are \(word).").isObservation, word)
        }
    }

    func testMatchingIsCaseInsensitiveAndWholeWord() {
        XCTAssertFalse(EmotionLabelFilter.check("THEY LOOK ANGRY").isObservation)
        XCTAssertFalse(EmotionLabelFilter.check("They look Angry!").isObservation)
        // Whole words only: these contain a table entry as a substring and are not one.
        XCTAssertTrue(EmotionLabelFilter.check("Standing near the saddle rack.").isObservation)
        XCTAssertTrue(EmotionLabelFilter.check("Holding a madeleine.").isObservation)
        XCTAssertTrue(EmotionLabelFilter.check("Talking about tomorrow.").isObservation)
    }

    /// The table must not contain the vocabulary the prompt asks for, nor words that are also an
    /// everyday observation.
    func testTheObservationVocabularyIsNotInTheTable() {
        let table = Set(EmotionLabelFilter.emotionWords.flatMap { $0 })
        for word in ["smiling", "smile", "frowning", "frown", "looking", "away", "crossed", "cross",
                     "leaning", "stepping", "waving", "pointing", "talking", "waiting", "crying",
                     "laughing", "shouting", "tired", "cold", "pain", "down", "content", "patient",
                     "want", "raised", "narrowed"] {
            XCTAssertFalse(table.contains(word), "\(word) is observation vocabulary")
        }
    }

    /// Advice and follow-up are checked together.
    func testAdviceAndFollowupAreCheckedTogether() {
        let clean = AssistiveAdvice(advice: "Smiling and looking at you.", urgency: .medium,
                                    followup: "Want me to keep watching?")
        XCTAssertEqual(EmotionLabelFilter.check(clean), .observation)
        let followupInfers = AssistiveAdvice(advice: "Smiling and looking at you.", urgency: .medium,
                                             followup: "She seems happy.")
        XCTAssertEqual(EmotionLabelFilter.check(followupInfers), .inference(matched: ["happy"]))
    }

    /// Every word the prompt forbids by name is one the filter catches, so the two never disagree.
    func testEveryWordThePromptForbidsIsInTheFilter() {
        for word in SocialObservationContract.forbiddenExamples {
            XCTAssertFalse(EmotionLabelFilter.check(word).isObservation, word)
            XCTAssertTrue(SocialObservationContract.instructions.contains(word), word)
        }
    }

    /// The tables are lowercase, single-spaced and free of duplicates, so a reviewer reads what runs.
    func testTheTablesAreNormalised() {
        let words = EmotionLabelFilter.emotionWords.flatMap { $0 }
        XCTAssertEqual(Set(words).count, words.count, "a word is listed twice")
        for word in words {
            XCTAssertEqual(EmotionLabelFilter.tokenize(word), [word], "\(word) is not one lowercase word")
        }
        for phrase in EmotionLabelFilter.inferencePhrases {
            XCTAssertEqual(EmotionLabelFilter.tokenize(phrase).joined(separator: " "), phrase, phrase)
        }
    }
}
