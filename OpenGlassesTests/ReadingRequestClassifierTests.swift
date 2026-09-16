import XCTest
@testable import OpenGlasses

/// Plan FF P1/PR4 — the reading-request predicate.
///
/// The positives matter less than the negatives. A false positive here only changes which of two
/// guidance sentences a wearer hears; a false *negative* on "what do you see" would turn the most
/// common thing a blind wearer says into a full-resolution capture on every turn.
final class ReadingRequestClassifierTests: XCTestCase {

    func testRecognisesTheBarReadingInstructions() {
        for phrase in ["read this", "read this to me", "Read it out, please",
                       "what does this say", "what does it say?", "can you read this",
                       "read the text on here"] {
            XCTAssertEqual(ReadingRequestClassifier.classify(phrase)?.kind, .readAloud,
                           "\(phrase) should read as a bare reading instruction")
        }
    }

    func testRecognisesNamedFields() {
        for phrase in ["what's the expiry date", "when's the expiry date on this",
                       "what's the total", "read me the dose", "what is the price"] {
            XCTAssertEqual(ReadingRequestClassifier.classify(phrase)?.kind, .specificField,
                           "\(phrase) should read as a named field")
        }
    }

    func testRecognisesNamedSurfaces() {
        for phrase in ["read the menu", "read the label on this bottle",
                       "what does this label say", "what's on the menu"] {
            XCTAssertEqual(ReadingRequestClassifier.classify(phrase)?.kind, .namedSurface,
                           "\(phrase) should read as a named surface")
        }
    }

    /// A named field beats a bare read verb, because "read me the expiry date" is both and the
    /// field is the more specific of the two answers.
    func testANamedFieldWinsOverABareReadVerb() {
        XCTAssertEqual(ReadingRequestClassifier.classify("read me the expiry date")?.kind,
                       .specificField)
    }

    /// The boundary this type exists to hold.
    func testSceneQuestionsAreNotReadingRequests() {
        for phrase in ["what do you see", "what do you see in front of me",
                       "describe this", "describe what's around me", "is anyone there",
                       "what's in front of me", "am I facing the door", "what colour is this",
                       "is it raining"] {
            XCTAssertNil(ReadingRequestClassifier.classify(phrase),
                         "\(phrase) must not be treated as a reading request")
        }
    }

    /// Talking *about* reading is not asking to be read to.
    func testTalkingAboutReadingIsNotARequest() {
        for phrase in ["I read a book about it last year",
                       "my reading glasses are in the car",
                       "she's a fast reader"] {
            XCTAssertNil(ReadingRequestClassifier.classify(phrase), phrase)
        }
    }

    func testEmptyAndWhitespaceAreNotRequests() {
        XCTAssertNil(ReadingRequestClassifier.classify(""))
        XCTAssertNil(ReadingRequestClassifier.classify("   \n  "))
        XCTAssertFalse(ReadingRequestClassifier.isReadingRequest(""))
    }

    /// A sample, not a claim of coverage — the type's own documentation says so, and an
    /// unrecognised language falls through to the model's tool selection rather than to a worse
    /// outcome.
    func testRecognisesASampleOfNonEnglishPhrasings() {
        let expected: [String: ReadingRequestClassifier.Kind] = [
            "lee esto por favor": .readAloud,
            "qué dice esto": .readAloud,
            "was steht hier": .readAloud,
            "lees dit voor": .readAloud,
            "lis ceci": .readAloud,
            "lee la etiqueta": .namedSurface,
            "fecha de caducidad": .specificField,
        ]
        for (phrase, kind) in expected {
            XCTAssertEqual(ReadingRequestClassifier.classify(phrase)?.kind, kind, phrase)
        }
    }

    /// Curly apostrophes come out of speech transcription constantly and must not defeat a match.
    func testCurlyApostrophesMatch() {
        XCTAssertNotNil(ReadingRequestClassifier.classify("what\u{2019}s the total"))
    }

    /// The description the model selects from is composed from this list, so an empty or shrinking
    /// list would silently un-teach the tool.
    func testTheTriggerPhrasesAreNonEmptyAndSelfRecognising() {
        XCTAssertGreaterThanOrEqual(ReadingRequestClassifier.triggerPhrases.count, 6)
        for phrase in ReadingRequestClassifier.triggerPhrases {
            XCTAssertTrue(ReadingRequestClassifier.isReadingRequest(phrase),
                          "\(phrase) is advertised to the model but not recognised here")
        }
    }
}
