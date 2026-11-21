import XCTest
@testable import OpenGlasses

/// Plan JM P0 — the contextual strings a dictation turn is given. Every model, part number and
/// manual title below is invented.
final class DictationVocabularyTests: XCTestCase {

    // MARK: - Fixtures

    private func equipment(stated: String? = "QX9-4410B") -> EquipmentIdentity {
        EquipmentIdentity(modelToken: "QX9-4410", heading: "QX9-4410 / QX9-4410B Packaged Unit",
                          file: "models.md", source: .spoken, statedModel: stated)
    }

    private func vault(name: String = "Rooftop Starter", titles: [String] = ["ZT-200 Service Guide"]) -> VaultManifest {
        VaultManifest(id: "starter", name: name, version: "1.0.0", files: [],
                      documents: titles.enumerated().map { VaultDocument(file: "doc\($0.offset).pdf", title: $0.element) })
    }

    private func stock(_ number: String?, _ description: String) -> VanStockItem {
        VanStockItem(number: number, description: description, createdBatch: "b0")
    }

    // MARK: - Order

    func testSourcesComeInPriorityOrderWithGlossaryLast() {
        let input = DictationVocabulary.Input(
            activeEquipment: equipment(),
            jobEquipment: [KnownEquipment(model: "LM-7720", make: "Northwind", label: "Roof east")],
            vanStock: [stock("77-10432-02", "Pilot assembly")],
            vaults: [vault()],
            wakePhrases: ["hey tess"],
            trades: [.refrigerationHVAC])
        let phrases = DictationVocabulary.build(input)

        func index(_ phrase: String) -> Int {
            guard let i = phrases.firstIndex(of: phrase) else {
                XCTFail("missing \(phrase)")
                return -1
            }
            return i
        }
        // Active equipment: the stated model first, then the vault's spelling.
        XCTAssertEqual(Array(phrases.prefix(2)), ["QX9-4410B", "QX9-4410"])
        XCTAssertLessThan(index("QX9-4410"), index("Northwind LM-7720"))
        XCTAssertLessThan(index("Northwind LM-7720"), index("LM-7720"))
        XCTAssertLessThan(index("Roof east"), index("77-10432-02"))
        XCTAssertLessThan(index("77-10432-02"), index("Pilot assembly"))
        XCTAssertLessThan(index("Pilot assembly"), index("Rooftop Starter"))
        XCTAssertLessThan(index("Rooftop Starter"), index("ZT-200 Service Guide"))
        XCTAssertLessThan(index("ZT-200 Service Guide"), index("hey tess"))
        XCTAssertLessThan(index("hey tess"), index("R-410A"))
        // The heading's prose is not a hint; its model-like tokens are.
        XCTAssertFalse(phrases.contains("QX9-4410 / QX9-4410B Packaged Unit"))
    }

    func testEquipmentWithoutAStatedModelLeadsWithTheVaultSpelling() {
        let phrases = DictationVocabulary.build(.init(activeEquipment: equipment(stated: nil)))
        XCTAssertEqual(phrases.first, "QX9-4410")
    }

    // MARK: - Clean-up

    func testDedupeIsCaseInsensitiveAndKeepsTheFirstSpelling() {
        let phrases = DictationVocabulary.build(.init(
            vanStock: [stock("abc-123", "Contactor")],
            wakePhrases: ["ABC-123", "contactor"],
            trades: [.refrigerationHVAC]))
        XCTAssertEqual(phrases.filter { $0.lowercased() == "abc-123" }, ["abc-123"])
        XCTAssertEqual(phrases.filter { $0.lowercased() == "contactor" }, ["Contactor"])
    }

    func testTrimsAndDropsEmptiesSingleCharactersAndSentences() {
        let sentence = String(repeating: "word ", count: 20)
        let phrases = DictationVocabulary.build(.init(
            wakePhrases: ["  hey tess \n", "", "   ", "x", "ok", sentence]))
        XCTAssertEqual(phrases, ["hey tess", "ok"])
    }

    func testEmptyInputGivesNoHints() {
        XCTAssertEqual(DictationVocabulary.build(.init()), [])
        XCTAssertEqual(DictationVocabulary(.init()).phrases, [])
    }

    // MARK: - Cap

    func testCapTrimsTheGlossaryEndFirst() {
        let parts = (0..<(DictationVocabulary.cap - 5)).map { stock(String(format: "PN-%04d", $0), "") }
        let phrases = DictationVocabulary.build(.init(
            vanStock: parts, wakePhrases: ["hey tess"], trades: [.refrigerationHVAC, .electrical]))
        XCTAssertEqual(phrases.count, DictationVocabulary.cap)
        XCTAssertEqual(phrases.first, "PN-0000")
        XCTAssertTrue(phrases.contains(String(format: "PN-%04d", DictationVocabulary.cap - 6)),
                      "the job's own words survive the cap")
        XCTAssertTrue(phrases.contains("hey tess"))
        // Four glossary entries fit; the rest of the glossaries are what the cap removed.
        XCTAssertEqual(Array(phrases.suffix(4)),
                       Array(DictationVocabulary.refrigerationHVACGlossary.prefix(4)))
        XCTAssertFalse(phrases.contains("GFCI"))
    }

    // MARK: - Glossaries

    func testEveryTradeHasANonEmptyGlossaryWithoutDuplicates() {
        for trade in FieldTrade.allCases {
            let glossary = DictationVocabulary.glossary(for: trade)
            XCTAssertFalse(glossary.isEmpty, "\(trade) has no glossary")
            XCTAssertLessThanOrEqual(glossary.count, 80, "\(trade)'s glossary is meant to be modest")
            let lowered = glossary.map { $0.lowercased() }
            XCTAssertEqual(Set(lowered).count, lowered.count, "\(trade)'s glossary repeats an entry")
            XCTAssertEqual(DictationVocabulary.normalised(glossary), glossary,
                           "\(trade)'s glossary has an entry the clean-up would drop")
        }
    }

    func testBothTradesShareAWordOnce() {
        let phrases = DictationVocabulary.build(.init(trades: [.refrigerationHVAC, .electrical]))
        XCTAssertEqual(phrases.filter { $0 == "contactor" }.count, 1)
    }

    // MARK: - What is never in the list

    /// `Input` is the whole of what the list can be built from. Constructing it with every
    /// parameter, by label, is the compile-time record of that: a customer name, a site address or
    /// a serial number would have to be added here, in the open, to reach the recogniser.
    func testInputCarriesNoCustomerOrSiteFields() {
        let input = DictationVocabulary.Input(
            activeEquipment: nil,
            jobEquipment: [],
            vanStock: [],
            vaults: [],
            wakePhrases: [],
            trades: [],
            // Plan MO §8: a live-hints session's own trigger words and its documents' titles.
            // Titles only, never the names a document mentions.
            keywords: [],
            documentTitles: [])
        let labels = Mirror(reflecting: input).children.compactMap(\.label)
        XCTAssertEqual(labels, ["activeEquipment", "jobEquipment", "vanStock", "vaults", "wakePhrases", "trades",
                                "keywords", "documentTitles"])
    }

    func testJobEquipmentSerialAndUnitKeyAreNotHints() {
        let phrases = DictationVocabulary.build(.init(
            jobEquipment: [KnownEquipment(model: "LM-7720", serial: "SN99887766", unitKey: "unit-42")]))
        XCTAssertEqual(phrases, ["LM-7720"])
    }
}
