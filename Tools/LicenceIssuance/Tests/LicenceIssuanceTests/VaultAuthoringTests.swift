import XCTest
@testable import LicenceIssuance

/// Plan LW P0 — the starter vault, the trade templates, the prompt kits and the paste parser, shared
/// by the phone and the portal. Every code, model and word here is invented.
final class VaultAuthoringTests: XCTestCase {

    // MARK: - The starter

    func testEveryTemplatesStarterPassesThePackRules() throws {
        for template in TradeTemplate.all {
            let out = try VaultStarter.make(name: "Rooftop units", template: template,
                                            models: [.init("QX-100", aliases: ["QX100"]), .init("QX-100A")])
            let manifest = try XCTUnwrap(VaultPackRules.Manifest(json: out.manifestJSON))
            XCTAssertEqual(VaultPackRules.manifestIssues(manifest, manualOnly: false), [], template.name)
            XCTAssertEqual(manifest.files, VaultStarter.fileNames)
            XCTAssertEqual(manifest.gatingIAP, "enterprise")
            for file in out.files {
                XCTAssertNil(VaultPackRules.listedFileIssue(file.name, contents: file.contents), "\(template.name) \(file.name)")
            }
            XCTAssertEqual(out.files.map(\.name), manifest.files, "every listed file is written, in order")
        }
    }

    func testAStarterWithNoModelsStillPasses() throws {
        let out = try VaultStarter.make(name: "Shop kit", template: .general)
        let manifest = try XCTUnwrap(VaultPackRules.Manifest(json: out.manifestJSON))
        XCTAssertEqual(VaultPackRules.manifestIssues(manifest), [])
        XCTAssertTrue(out.files.allSatisfy { VaultPackRules.listedFileIssue($0.name, contents: $0.contents) == nil })
    }

    func testEveryTemplatesRulesCarryTheRequiredThemes() {
        for template in TradeTemplate.all {
            let joined = template.promptRules.joined(separator: " ").lowercased()
            for theme in VaultPackRules.requiredRuleThemes {
                XCTAssertTrue(joined.contains(theme), "\(template.name) lacks \(theme)")
            }
        }
    }

    func testTheStarterIsDeterministic() throws {
        let a = try VaultStarter.make(name: "Rooftop units", template: .hvacR, models: [.init("QX-100")])
        let b = try VaultStarter.make(name: "Rooftop units", template: .hvacR, models: [.init("QX-100")])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.manifestJSON, b.manifestJSON)
    }

    func testTheManifestCarriesWhatTheGuideDescribes() throws {
        let out = try VaultStarter.make(name: "Rooftop units", template: .hvacR)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: out.manifestJSON) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "rooftop_units")
        XCTAssertEqual(object["name"] as? String, "Rooftop units")
        XCTAssertEqual(object["version"] as? String, "1.0.0")
        XCTAssertEqual(object["documents_dir"] as? String, "documents")
        XCTAssertEqual((object["documents"] as? [Any])?.count, 0)
        XCTAssertEqual(object["trades"] as? [String], ["refrigeration_hvac"])
        XCTAssertEqual(object["source_attribution_required"] as? Bool, true)
        XCTAssertEqual(object["source_attribution_format"] as? String, "Source: {files}")
        // General names no trade, so the technician's own choice decides the tiles.
        let general = try VaultStarter.make(name: "Shop kit", template: .general)
        let generalObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: general.manifestJSON) as? [String: Any])
        XCTAssertNil(generalObject["trades"])
        XCTAssertFalse(String(decoding: general.manifestJSON, as: UTF8.self).contains("\\/"), "slashes unescaped")
    }

    func testModelsBecomeOneHeadingEachWithTheirSpellings() throws {
        let out = try VaultStarter.make(name: "Units", template: .hvacR, models: [
            .init("QX-100", aliases: ["QX100", "qx100", " "]),
            .init(" QX-100A "),
            .init("qx-100", aliases: ["QX-100-1"]),
            .init("QX-200 (rev)", aliases: ["QX-100A"]),
            .init("")
        ])
        let models = try XCTUnwrap(out.files.first { $0.name == VaultStarter.modelsFile }).contents
        let headings = models.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        XCTAssertEqual(headings, ["## QX-100 (QX100, QX-100-1)", "## QX-100A", "## QX-200 rev"],
                       "duplicates merged, brackets taken out, another model's own name never an alias")
    }

    func testFaultCodeAndSymptomFilesCarryOnlyTopicHeadings() throws {
        for template in TradeTemplate.all {
            let out = try VaultStarter.make(name: "Units", template: template)
            for name in [VaultStarter.faultCodesFile, VaultStarter.symptomsFile] {
                let contents = try XCTUnwrap(out.files.first { $0.name == name }).contents
                for heading in contents.components(separatedBy: "\n").filter({ $0.hasPrefix("#") }) {
                    XCTAssertFalse(heading.contains(where: \.isNumber), "a heading with a number could read as a model: \(heading)")
                }
            }
            let symptoms = try XCTUnwrap(out.files.first { $0.name == VaultStarter.symptomsFile }).contents
            for heading in template.symptomHeadings { XCTAssertTrue(symptoms.contains("## \(heading)\n")) }
        }
    }

    func testVaultIds() {
        XCTAssertEqual(VaultStarter.vaultId(forName: "Rooftop Units — North"), "rooftop_units_north")
        XCTAssertEqual(VaultStarter.vaultId(forName: "  QX-100 / 200 "), "qx_100_200")
        XCTAssertEqual(VaultStarter.vaultId(forName: "冷却"), "my_vault")
        XCTAssertEqual(VaultStarter.vaultId(forName: String(repeating: "ab ", count: 40)).count <= 64, true)
        XCTAssertFalse(VaultStarter.vaultId(forName: String(repeating: "a", count: 63) + " b").hasSuffix("_"))
    }

    func testAnEmptyNameIsRefusedAndAnIdCanBeGiven() throws {
        XCTAssertThrowsError(try VaultStarter.make(name: "  \n ", template: .general)) {
            XCTAssertEqual($0 as? VaultStarter.Failure, .emptyName)
        }
        XCTAssertEqual(try VaultStarter.make(name: "Units", template: .general, id: "units_2").id, "units_2")
    }

    // MARK: - Templates

    func testCodePatterns() {
        for code in ["E9", "F17", "zx9", "E-12", "33"] { XCTAssertTrue(TradeTemplate.hvacR.isCode(code), code) }
        for notCode in ["QX-100", "E1234", "F170", "Fan", ""] { XCTAssertFalse(TradeTemplate.hvacR.isCode(notCode), notCode) }
        for code in ["E9", "F17", "P9901", "12", "3A"] { XCTAssertTrue(TradeTemplate.general.isCode(code), code) }
        for notCode in ["QX-100A", "Fan", "PUMP"] { XCTAssertFalse(TradeTemplate.general.isCode(notCode), notCode) }
    }

    func testIdentityPatterns() {
        for model in ["QX-100", "QX-100A", "qx100"] { XCTAssertTrue(TradeTemplate.hvacR.isIdentity(model), model) }
        for notModel in ["E9", "F17", "QX-1", "Manual", "12345"] { XCTAssertFalse(TradeTemplate.hvacR.isIdentity(notModel), notModel) }
        XCTAssertTrue(TradeTemplate.general.isIdentity("QX-100"))
        XCTAssertFalse(TradeTemplate.general.isIdentity("E9"))
    }

    func testEveryTemplateHasStarterQuestionsAndATemplateIsFoundById() {
        for id in TradeTemplate.ID.allCases {
            let template = TradeTemplate.template(id: id)
            XCTAssertEqual(template.id, id)
            XCTAssertGreaterThanOrEqual(template.checkQuestions.count, 5)
            XCTAssertFalse(template.symptomHeadings.isEmpty)
            XCTAssertTrue(template.safetyStarter.hasPrefix("# Safety"))
        }
    }

    // MARK: - Prompt kits

    func testEveryKitStatesItsExactFormatLast() {
        for template in TradeTemplate.all {
            for layer in DraftLayer.allCases {
                let prompt = PromptKit.prompt(for: layer, template: template, manualTitle: "Installation manual")
                XCTAssertEqual(prompt.components(separatedBy: "\n").last, PromptKit.format(layer))
                XCTAssertTrue(prompt.contains("\"Installation manual\""))
                XCTAssertTrue(prompt.contains(template.subject))
                XCTAssertTrue(prompt.contains("Never guess"))
                XCTAssertTrue(prompt.contains("printed on that page"))
            }
        }
    }

    func testKitsSayWhatACodeAndAModelLookLikeInTheTrade() {
        let codes = PromptKit.prompt(for: .faultCodes, template: .hvacR)
        XCTAssertTrue(codes.contains(TradeTemplate.hvacR.codeDescription))
        XCTAssertTrue(codes.contains("the manual,"), "no title: the manual")
        let models = PromptKit.prompt(for: .modelMap, template: .general)
        XCTAssertTrue(models.contains(TradeTemplate.general.identity.description))
        let symptoms = PromptKit.prompt(for: .symptoms, template: .hvacR)
        XCTAssertTrue(symptoms.contains("not cooling"))
        XCTAssertEqual(PromptKit.prompt(for: .symptoms, template: .hvacR), symptoms, "deterministic")
    }

    func testAKitsOwnFormatLineParsesAsAHeaderNotARow() {
        for layer in DraftLayer.allCases {
            let parsed = PastedDraftParser.parse(PromptKit.format(layer), layer: layer)
            XCTAssertEqual(parsed.rows, [], "\(layer)")
        }
    }

    // MARK: - The paste parser

    func testAPlainReplyParses() {
        let parsed = PastedDraftParser.parse("""
        E9 | Low refrigerant charge | 41
        F17 | Outdoor fan not turning | p. 42
        """, layer: .faultCodes)
        XCTAssertEqual(parsed.unparsed, [])
        XCTAssertEqual(parsed.rows, [
            .faultCode(FaultCodeRow(code: "E9", label: "Low refrigerant charge", page: DraftPage(cited: "41"))),
            .faultCode(FaultCodeRow(code: "F17", label: "Outdoor fan not turning", page: DraftPage(cited: "42")))
        ])
    }

    func testModelNoiseIsToleratedAndProseIsShownNotDropped() {
        let reply = """
        Here are the fault codes I found in the manual:

        ```
        1. **E9** | Low refrigerant charge | 41
        - `F17` | Outdoor fan not turning | page 42
        * E-12 · Sensor open · 4-12
        ```
        I could not find any more.
        """
        let parsed = PastedDraftParser.parse(reply, layer: .faultCodes)
        XCTAssertEqual(parsed.rows.count, 3)
        XCTAssertEqual(parsed.rows.last, .faultCode(FaultCodeRow(code: "E-12", label: "Sensor open", page: DraftPage(cited: "4-12"))))
        XCTAssertEqual(parsed.unparsed.map(\.text),
                       ["Here are the fault codes I found in the manual:", "I could not find any more."])
        XCTAssertEqual(parsed.unparsed.map(\.line), [1, 8])
    }

    func testAMarkdownTableParsesWithoutItsHeaderAndRule() {
        let reply = """
        | Code | What it means | Page |
        |------|:-------------:|-----:|
        | E9 | Low refrigerant charge | 41 |
        | F17 | Outdoor fan not turning | 42 |
        """
        let parsed = PastedDraftParser.parse(reply, layer: .faultCodes)
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.unparsed, [])
    }

    func testRowsThatBreakTheFormatAreUnparsed() {
        let reply = """
        E9 | Low refrigerant charge
        F17 | Outdoor fan | 42 | extra
        P9901 | Pump fault | soon
         | No code | 12
        E5 | | 12
        """
        let parsed = PastedDraftParser.parse(reply, layer: .faultCodes)
        XCTAssertEqual(parsed.rows, [])
        XCTAssertEqual(parsed.unparsed.count, 5, "a missing page, an extra field, a page that is not one, an empty code, an empty label")
    }

    func testModelRows() {
        let parsed = PastedDraftParser.parse("""
        QX-100 | QX100, QX-100-1; QX 100 | 3
        QX-100A | - | 3
        QX-200 | none
        QX-300 | QX300 | n/a
        QX-400 | QX400 | whenever
        """, layer: .modelMap)
        XCTAssertEqual(parsed.rows, [
            .model(ModelRow(model: "QX-100", aliases: ["QX100", "QX-100-1", "QX 100"], page: DraftPage(cited: "3"))),
            .model(ModelRow(model: "QX-100A", aliases: [], page: DraftPage(cited: "3"))),
            .model(ModelRow(model: "QX-200", aliases: [], page: nil)),
            .model(ModelRow(model: "QX-300", aliases: ["QX300"], page: nil))
        ])
        XCTAssertEqual(parsed.unparsed.map(\.text), ["QX-400 | QX400 | whenever"])
    }

    func testSymptomRows() {
        let parsed = PastedDraftParser.parse("""
        What the technician says | Likely cause | First check | Page
        Not cooling, fan running | Dirty outdoor coil | Look at the coil for dirt | 58
        Ice on the coil | Low airflow | Filter
        """, layer: .symptoms)
        XCTAssertEqual(parsed.rows, [.symptom(SymptomRow(symptom: "Not cooling, fan running", cause: "Dirty outdoor coil",
                                                         check: "Look at the coil for dirt", page: DraftPage(cited: "58")))])
        XCTAssertEqual(parsed.unparsed.map(\.line), [3])
    }

    func testWindowsLineEndingsAndPagePrefixes() {
        let parsed = PastedDraftParser.parse("E9 | Low charge | pp. 41\r\nF17 | Fan | PDF page 42.\r\n", layer: .faultCodes)
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(DraftPage.parse("iv"), DraftPage(cited: "iv"))
        XCTAssertEqual(DraftPage.parse("41\u{2013}42"), DraftPage(cited: "41-42"))
        XCTAssertNil(DraftPage.parse("the back"))
        XCTAssertNil(DraftPage.parse(""))
    }

    // MARK: - Writing kept rows

    func testIndexRowsCiteTheKeyAndPage() {
        XCTAssertEqual(IndexRowWriter.citation(key: "install-manual", page: 43), "install-manual p. 43")
        XCTAssertEqual(IndexRowWriter.citation(key: "install-manual", page: 43, printed: "41"), "install-manual p. 43 (printed 41)")
        XCTAssertEqual(IndexRowWriter.citation(key: "install-manual", page: 43, printed: "43"), "install-manual p. 43")
        let row = FaultCodeRow(code: "E9", label: "Low charge | check", page: DraftPage(cited: "41"))
        XCTAssertEqual(IndexRowWriter.faultCodeLine(row, citation: "install-manual p. 43"),
                       "| E9 | Low charge / check | install-manual p. 43 |")
        XCTAssertEqual(IndexRowWriter.modelSection(ModelRow(model: "QX-100", aliases: ["QX100"]), citations: ["install-manual p. 3"]),
                       "## QX-100 (QX100)\nManuals: install-manual p. 3.")
        XCTAssertEqual(IndexRowWriter.modelSection(ModelRow(model: "QX-100A"), citations: []), "## QX-100A\nManuals: none yet.")
        let symptom = SymptomRow(symptom: "Not cooling", cause: "Dirty coil", check: "Look at the outdoor coil", page: DraftPage(cited: "58"))
        XCTAssertEqual(IndexRowWriter.symptomCheckLine(symptom, number: 1, citation: "install-manual p. 60 (printed 58)"),
                       "1. Look at the outdoor coil. Likely cause: Dirty coil. install-manual p. 60 (printed 58).")
    }

    func testAWrittenFaultCodeRowSitsUnderTheStartersTableAndParsesBack() throws {
        let out = try VaultStarter.make(name: "Units", template: .hvacR)
        let file = try XCTUnwrap(out.files.first { $0.name == VaultStarter.faultCodesFile }).contents
        XCTAssertTrue(file.contains(VaultStarter.faultCodeTableHeader))
        let line = IndexRowWriter.faultCodeLine(FaultCodeRow(code: "E9", label: "Low charge", page: DraftPage(cited: "41")),
                                                citation: "install-manual p. 41")
        // The table the starter writes, with a row under it, reads back as the row.
        let parsed = PastedDraftParser.parse(VaultStarter.faultCodeTableHeader + "\n" + line.replacingOccurrences(of: "install-manual p. 41", with: "41"),
                                             layer: .faultCodes)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.unparsed, [])
    }
}
