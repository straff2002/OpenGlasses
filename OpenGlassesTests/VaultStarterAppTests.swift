import XCTest
@testable import OpenGlasses

// The licence core is compiled into this bundle too, so its authoring types shadow the app's here.
// Every name below is the app's own copy, the one the phone runs.
private typealias AppTemplate = OpenGlasses.TradeTemplate
private typealias AppStarter = OpenGlasses.VaultStarter
private typealias AppParser = OpenGlasses.PastedDraftParser
private typealias AppWriter = OpenGlasses.IndexRowWriter
private typealias AppModelRow = OpenGlasses.ModelRow
private typealias AppFaultRow = OpenGlasses.FaultCodeRow
private typealias AppPage = OpenGlasses.DraftPage

/// Plan LW P0 — the starter vault as the phone's own readers take it: the manifest decoder, the
/// validator, the pack rules and the model index. Invented names and models only.
final class VaultStarterAppTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultStarterAppTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func starter(_ template: AppTemplate = .hvacR,
                         models: [AppStarter.Model] = [.init("QX-100", aliases: ["QX100"]), .init("QX-100A")]) throws -> AppStarter.Output {
        try AppStarter.make(name: "Rooftop units", template: template, models: models)
    }

    private func write(_ output: AppStarter.Output) throws -> URL {
        let dir = tempRoot.appendingPathComponent(output.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try output.manifestJSON.write(to: dir.appendingPathComponent("manifest.json"))
        for file in output.files {
            try file.contents.write(to: dir.appendingPathComponent(file.name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testTheStarterDecodesAsTheAppsManifest() throws {
        let output = try starter()
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: output.manifestJSON)
        XCTAssertEqual(manifest.id, "rooftop_units")
        XCTAssertEqual(manifest.files, AppStarter.fileNames)
        XCTAssertEqual(manifest.gating.iap, "enterprise")
        XCTAssertEqual(manifest.documentsDir, "documents")
        XCTAssertTrue(manifest.documents.isEmpty)
        XCTAssertTrue(manifest.sourceAttributionRequired)
        XCTAssertEqual(FieldTrade.known(manifest.trades ?? []), [.refrigerationHVAC])
        XCTAssertNil(try JSONDecoder().decode(VaultManifest.self, from: starter(.general).manifestJSON).trades)
    }

    func testEveryTemplatesStarterPassesThePhonesValidatorAndPackRules() throws {
        for template in AppTemplate.all {
            let output = try starter(template)
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: output.manifestJSON)
            XCTAssertEqual(OpenGlasses.VaultPackRules.manifestIssues(.init(manifest), manualOnly: false), [], template.name)
            let result = VaultValidator.validate(directory: try write(output))
            XCTAssertTrue(result.isValid, "\(template.name): \(result.issues)")
        }
    }

    func testTheModelIndexReadsEveryStarterModelAndNothingElse() throws {
        let output = try starter()
        let index = VaultModelIndex(vaultName: output.name, files: output.files.map { ($0.name, $0.contents) })
        XCTAssertEqual(index.models.map(\.name), ["QX-100", "QX-100A"])
        XCTAssertEqual(index.models.map(\.file), [AppStarter.modelsFile, AppStarter.modelsFile])
        XCTAssertEqual(index.models.first?.tokens, ["QX-100", "QX100"])
        XCTAssertEqual(index.resolve(token: "qx100").map(\.name), ["QX-100"])
        XCTAssertEqual(index.resolve(token: "QX-100A").map(\.name), ["QX-100A"])
        XCTAssertEqual(index.models.first?.body.trimmingCharacters(in: .whitespacesAndNewlines), "Manuals: none yet.")
    }

    func testAStarterWithNoModelsHasAnEmptyIndex() throws {
        for template in AppTemplate.all {
            let output = try starter(template, models: [])
            let index = VaultModelIndex(vaultName: output.name, files: output.files.map { ($0.name, $0.contents) })
            XCTAssertTrue(index.isEmpty, "\(template.name): no starter heading reads as a model")
            XCTAssertTrue(index.vaultTokens.isEmpty, "\(template.name): the starter prints no model-like token at all")
        }
    }

    func testAWrittenModelSectionIsReadByTheIndexAndCitesTheManualKey() throws {
        let output = try starter(models: [])
        let section = AppWriter.modelSection(AppModelRow(model: "QX-300", aliases: ["QX300"]),
                                             citations: [AppWriter.citation(key: "installation-manual", page: 5, printed: "3")])
        let models = try XCTUnwrap(output.files.first { $0.name == AppStarter.modelsFile }).contents + "\n" + section + "\n"
        let index = VaultModelIndex(vaultName: output.name, files: [(AppStarter.modelsFile, models)])
        XCTAssertEqual(index.models.map(\.name), ["QX-300"])
        XCTAssertTrue(index.models[0].body.contains("installation-manual p. 5 (printed 3)"))
        // The key and page are what Plan LV's answer note reads; the key names no document by itself.
        XCTAssertTrue(index.models[0].assignedDocumentIds(among: [(id: "d1", title: "Installation manual")]).isEmpty)
    }

    func testAFaultCodeRowUnderTheStartersTableAddsNoModel() throws {
        let output = try starter(models: [])
        var codes = try XCTUnwrap(output.files.first { $0.name == AppStarter.faultCodesFile }).contents
        codes += AppWriter.faultCodeLine(AppFaultRow(code: "E9", label: "Low refrigerant charge", page: AppPage(cited: "39")),
                                         citation: "installation-manual p. 41 (printed 39)") + "\n"
        let index = VaultModelIndex(vaultName: output.name, files: [(AppStarter.faultCodesFile, codes)])
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(CodeTokenizer.contains(codes, token: "E9"), "a lookup for the code finds its row")
    }

    func testTheAppsParserReadsAKitsReply() {
        let parsed = AppParser.parse("Sure:\nE9 | Low refrigerant charge | 39\n", layer: .faultCodes)
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.unparsed.map(\.text), ["Sure:"])
        XCTAssertTrue(OpenGlasses.PromptKit.prompt(for: .faultCodes, template: .hvacR).hasSuffix(OpenGlasses.PromptKit.format(.faultCodes)))
    }
}
