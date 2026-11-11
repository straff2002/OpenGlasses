import XCTest
@testable import OpenGlasses

/// Plan KT §4.1 — templates filled from a card's facts, in the draft's language. Three languages
/// with the placeholders in different orders, each time formatted in its own locale.
final class DraftTemplatesTests: XCTestCase {
    private typealias F = CardFixtures

    /// Stand-in translations, so the filling is tested without depending on the catalogue's state.
    private struct Table: DraftTemplateSource {
        let rows: [String: [DraftTemplateID: String]]
        func template(_ id: DraftTemplateID, language: String) -> String {
            rows[language]?[id] ?? rows["en"]?[id] ?? ""
        }
    }

    private let table = Table(rows: [
        "en": [.runningLate: "Running about {minutes} minutes late, sorry — there about {arrival}.",
               .jobOnMyWayFromCompany: "Hi {name}, it's {wearer} from {company}. On my way, there about {arrival}.",
               .greetingOne: "Hi {name},"],
        "de": [.runningLate: "Ich komme etwa {minutes} Minuten zu spät, sorry — bin gegen {arrival} da.",
               .jobOnMyWayFromCompany: "Hallo {name}, hier ist {wearer} von {company}. Bin unterwegs, gegen {arrival} da.",
               .greetingOne: "Hallo {name},"],
        "es": [.runningLate: "Llego unos {minutes} minutos tarde, perdón: estaré allí sobre las {arrival}.",
               .jobOnMyWayFromCompany: "Hola {name}, soy {wearer} de {company}. Voy de camino, llego sobre las {arrival}.",
               .greetingOne: "Hola {name},"],
    ])

    private let utc = TimeZone(secondsFromGMT: 0)!

    func testRunningLateFillsInThreeLanguages() {
        let arrival = F.at(18, 45)
        let expected = [
            "en-GB": "Running about 15 minutes late, sorry — there about 18:45.",
            "de": "Ich komme etwa 15 Minuten zu spät, sorry — bin gegen 18:45 da.",
            "es": "Llego unos 15 minutos tarde, perdón: estaré allí sobre las 18:45.",
        ]
        for (language, text) in expected {
            let base = String(language.prefix(2))
            let values = ["minutes": DraftTemplates.number(15, language: language),
                          "arrival": DraftTemplates.time(arrival, language: language, timeZone: utc)]
            let filled = DraftTemplates.text(.runningLate, values, language: base, source: table)
            XCTAssertEqual(filled, text, language)
            let context = DraftValidationContext(channel: .messages, language: language,
                                                 trustedText: Array(values.values))
            XCTAssertNil(DraftValidator.validate(filled, context: context), language)
        }
    }

    func testOnMyWayFillsNamesInEachLanguagesOrder() {
        let values = ["name": "Hana", "wearer": "Sam", "company": "Example Plumbing",
                      "arrival": DraftTemplates.time(F.at(9, 55), language: "de", timeZone: utc)]
        XCTAssertEqual(DraftTemplates.text(.jobOnMyWayFromCompany, values, language: "de", source: table),
                       "Hallo Hana, hier ist Sam von Example Plumbing. Bin unterwegs, gegen 09:55 da.")
        XCTAssertEqual(DraftTemplates.text(.jobOnMyWayFromCompany, values, language: "es", source: table),
                       "Hola Hana, soy Sam de Example Plumbing. Voy de camino, llego sobre las 09:55.")
    }

    func testTimesAreFormattedInTheDraftsLanguage() {
        let arrival = F.at(18, 45)
        XCTAssertEqual(DraftTemplates.time(arrival, language: "de", timeZone: utc), "18:45")
        XCTAssertEqual(DraftTemplates.time(arrival, language: "en-GB", timeZone: utc), "18:45")
        let american = DraftTemplates.time(arrival, language: "en-US", timeZone: utc)
        XCTAssertTrue(american.hasPrefix("6:45"), american)
        XCTAssertEqual(DraftTemplates.number(1500, language: "de"), "1.500")
    }

    func testAnEmailGreetsSignsAndListsWithoutMarkdown() {
        let text = DraftTemplates.email(greetingName: "Hana", body: "Body\n" + DraftTemplates.bulletList(["One", "Two"]),
                                        signOff: "Sam", language: "es", source: table)
        XCTAssertEqual(text, "Hola Hana,\n\nBody\n• One\n• Two\n\nSam")
        let context = DraftValidationContext(channel: .email, language: "es", trustedText: [])
        XCTAssertNotEqual(DraftValidator.validate(text, context: context), .markdown)
    }

    func testAnUnfilledPlaceholderIsLeftForTheValidatorToRefuse() {
        let filled = DraftTemplates.text(.runningLate, ["minutes": "15"], language: "en", source: table)
        XCTAssertTrue(filled.contains("{arrival}"))
        let context = DraftValidationContext(channel: .messages, language: "en", trustedText: ["15"])
        XCTAssertEqual(DraftValidator.validate(filled, context: context), .placeholderLeft)
    }

    func testTheCatalogueGivesEveryTemplateInEnglishWithItsPlaceholders() {
        let catalogue = CatalogDraftTemplates()
        let placeholders: [DraftTemplateID: [String]] = [
            .onMyWay: ["arrival"], .runningLate: ["minutes", "arrival"], .askToMove: ["meeting", "slot"],
            .recapIntro: [], .recapSubject: ["meeting"], .jobOnMyWayFromCompany: ["name", "wearer", "company", "arrival"],
            .jobOnMyWayFromWearer: ["name", "wearer", "arrival"], .jobOnMyWay: ["name", "arrival"],
            .jobRunningLate: ["name", "minutes", "arrival"], .greetingOne: ["name"], .greetingAll: [],
        ]
        XCTAssertEqual(Set(placeholders.keys), Set(DraftTemplateID.allCases))
        for id in DraftTemplateID.allCases {
            let text = catalogue.template(id, language: "en")
            XCTAssertFalse(text.isEmpty, id.rawValue)
            for key in placeholders[id] ?? [] {
                XCTAssertTrue(text.contains("{\(key)}"), "\(id.rawValue) lacks {\(key)}")
            }
            // A language the app does not ship falls back rather than coming back empty.
            XCTAssertFalse(catalogue.template(id, language: "xx-YY").isEmpty, id.rawValue)
        }
        XCTAssertEqual(catalogue.template(.onMyWay, language: "en"), "On my way — there about {arrival}.")
    }
}
