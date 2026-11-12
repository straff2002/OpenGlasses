import XCTest
@testable import OpenGlasses

/// Plan LN P0 — what a fact is about: every category's word list, the near-misses each list must
/// leave alone, the identifier shapes, the wearer as a minor, and who a fact is about.
final class MemorySensitivityTests: XCTestCase {

    private typealias Category = MemorySensitivity.Category

    private func categories(_ key: String, _ value: String) -> Set<Category> {
        MemorySensitivity.classify(key: key, value: value)
    }

    // MARK: - Every list entry is a hit for its own category

    func testEveryWordListEntryMatchesItsCategory() {
        let lists: [(Category, [String])] = [
            (.identifier, MemorySensitivity.identifierLabels),
            (.health, MemorySensitivity.healthTerms),
            (.protectedAttribute, MemorySensitivity.protectedAttributeTerms),
            (.finances, MemorySensitivity.financeTerms),
            (.legalOrHarm, MemorySensitivity.legalOrHarmTerms),
        ]
        for (category, entries) in lists {
            for entry in entries {
                let phrase = entry.replacingOccurrences(of: "*", with: "")
                XCTAssertTrue(categories("note", "they said \(phrase) today").contains(category),
                              "\(entry) should read as \(category)")
            }
        }
    }

    func testRealisticHitsInEachCategory() {
        let cases: [(String, String, Category)] = [
            ("card", "4111 1111 1111 1111", .identifier),
            ("", "my IBAN is GB82 WEST 1234 5698 7654 32", .identifier),
            ("passport number", "LA123456", .identifier),
            ("Sam", "diagnosed with diabetes", .health),
            ("", "I'm allergic to penicillin", .health),
            ("colleague", "is pregnant", .health),
            ("neighbour", "in recovery after rehab", .health),
            ("", "sees a therapist on Tuesdays", .health),
            ("", "Sam is Muslim", .protectedAttribute),
            ("", "voted for the Green Party", .protectedAttribute),
            ("brother", "is gay", .protectedAttribute),
            ("Aroha", "is a union member", .protectedAttribute),
            ("salary", "$95,000", .finances),
            ("", "has a lot of debt on his cards", .finances),
            ("", "Tom was arrested last year", .legalOrHarm),
            ("", "was a victim of domestic violence", .legalOrHarm),
        ]
        for (key, value, expected) in cases {
            XCTAssertTrue(categories(key, value).contains(expected), "\(key) \(value) → \(expected)")
        }
    }

    // MARK: - Near-misses: the everyday neighbour of every risky word

    func testNearMissesAreNotSensitive() {
        let cases: [(String, String)] = [
            ("bank", "ANZ"),
            ("bank", "my bank is Westpac on Lambton Quay"),
            ("rent", "due on the 1st, $450 a week"),
            ("budget", "$200 for the trip"),
            ("power bill", "due on the 20th"),
            ("price", "coffee is $5 at the corner place"),
            ("gym routine", "legs on Monday, a run on Thursday"),
            ("work", "works at the hospital"),
            ("dentist", "Dr Patel on Queen Street"),
            ("meeting spot", "Union Station, under the clock"),
            ("party", "birthday party on Saturday"),
            ("blinds", "the blinds in the lounge stick"),
            ("flight", "trans-Tasman flight on Friday"),
            ("suburb", "lives near Island Bay"),
            ("event", "a race on Saturday at the track"),
            ("hobby", "tennis court booked for Friday"),
            ("phone", "charged overnight on the desk"),
            ("passport", "expires in March"),
            ("phone number", "021 555 1234"),
            ("order number", "1234567890123"),
            ("diet", "vegetarian"),
            ("sleep", "goes to bed at ten"),
            ("coffee", "flat white, no sugar"),
            ("loyalty card", "the café stamps card"),
            ("answers", "a straight answer"),
            ("study", "I'm in year 2 of my degree"),
            ("eta", "I'm 5 minutes away"),
            ("wifi password", "hunter2"),
            ("daughter's name", "Mia"),
        ]
        for (key, value) in cases {
            XCTAssertEqual(categories(key, value), [], "\(key): \(value) is everyday")
        }
    }

    // MARK: - Identifier shapes (every language)

    func testLuhnValidCardRunsAreIdentifiersWhateverTheSeparators() {
        XCTAssertTrue(MemorySensitivity.luhnValid("4111111111111111"))
        XCTAssertFalse(MemorySensitivity.luhnValid("4111111111111112"))
        XCTAssertTrue(MemorySensitivity.hasIdentifierShape("4111-1111-1111-1111"))
        XCTAssertTrue(MemorySensitivity.hasIdentifierShape("tarjeta 5555 5555 5555 4444"))
        XCTAssertTrue(MemorySensitivity.hasIdentifierShape("4111111111111111 exp 0129"),
                      "a card read out with its expiry is still a card")
        XCTAssertFalse(MemorySensitivity.hasIdentifierShape("1234 5678 1234 5678"),
                       "sixteen digits that fail the check are not a card")
        XCTAssertFalse(MemorySensitivity.hasIdentifierShape("call 021 555 1234"))
    }

    func testIBANShapeNeedsTheCheckDigitsToAgree() {
        XCTAssertTrue(MemorySensitivity.ibanValid("GB82WEST12345698765432"))
        XCTAssertTrue(MemorySensitivity.containsIBAN("Konto DE89 3704 0044 0532 0130 00"))
        XCTAssertTrue(MemorySensitivity.containsIBAN("iban gb82 west 1234 5698 7654 32"),
                      "a model that lower-cases the tag still trips it")
        XCTAssertFalse(MemorySensitivity.containsIBAN("GB82 WEST 1234 5698 7654 33"))
        XCTAssertFalse(MemorySensitivity.containsIBAN("Flight NZ12 leaves at 9"))
    }

    // MARK: - The wearer as a minor

    func testFirstPersonMinorStatements() {
        for (key, value) in [("", "I'm 15"), ("age", "16"), ("", "I am 12 years old"),
                             ("", "I'm in grade 9"), ("", "I'm in year 10"),
                             ("", "I go to high school in Karori"), ("", "I'm under 18")] {
            XCTAssertTrue(categories(key, value).contains(.minor), "\(key) \(value)")
        }
        for (key, value) in [("age", "34"), ("son", "is 12"), ("", "I'm in year 2 of my degree"),
                             ("", "I teach at the high school"), ("", "I'm 15 minutes late")] {
            XCTAssertFalse(categories(key, value).contains(.minor), "\(key) \(value) is not the wearer as a minor")
        }
    }

    // MARK: - Who a fact is about

    func testSubjectFromKeyAndValue() {
        typealias S = MemorySensitivity.Subject
        XCTAssertEqual(MemorySensitivity.subject(key: "allergy", value: "penicillin"), .wearer)
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "I'm allergic to penicillin"), .wearer)
        XCTAssertEqual(MemorySensitivity.subject(key: "sister", value: "pregnant"), S.otherPerson("sister"))
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "my boss has cancer"), S.otherPerson("boss"))
        XCTAssertEqual(MemorySensitivity.subject(key: "Sam's diagnosis", value: "diabetes"), S.otherPerson("Sam"))
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "Sam has diabetes"), S.otherPerson("Sam"))
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "she's in recovery"), S.otherPerson("shes"))
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "it's the clinic's number"), .wearer,
                       "contractions and possessive things are not people")
        XCTAssertEqual(MemorySensitivity.subject(key: "", value: "I take insulin",
                                                 utteranceSpeakerIsWearer: false),
                       S.otherPerson("someone"), "a bystander's first person is not the wearer")
    }

    func testMostSeriousOrdersIdentifierFirst() {
        XCTAssertEqual(MemorySensitivity.mostSerious([.finances, .health, .identifier]), .identifier)
        XCTAssertEqual(MemorySensitivity.mostSerious([.finances, .health]), .health)
        XCTAssertNil(MemorySensitivity.mostSerious([]))
    }
}
