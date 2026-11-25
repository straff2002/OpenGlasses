import XCTest
@testable import OpenGlasses

/// Plan NF P0 — `crew-models.md` and the experience-only vault, as the phone's own readers take
/// them: the model index reads every model the portal writes (gotcha 1: a vault with no manuals still
/// knows its models), the corpus publishes a model entry to it, and the validator accepts the vault.
/// `CrewModelsFile` is the licence core's, compiled into this bundle. Invented models only.
@MainActor
final class CrewModelsFileTests: XCTestCase {

    private typealias CoreModel = VaultStarter.Model // the core's own, which shadows the app's here

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CrewModelsFileTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "crew-experience-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    private func index(_ text: String) -> VaultModelIndex {
        VaultModelIndex(vaultName: "Fixture Crew Units", files: [(filename: CrewModelsFile.fileName, contents: text)])
    }

    func testTheModelIndexReadsTheRenderedFileBack() throws {
        let text = try CrewModelsFile.render(models: [CoreModel("ZPL-2040", aliases: ["ZPL2040"]),
                                                      CoreModel("QXRT-990", aliases: ["QXRT990", "QX-RT990"]),
                                                      CoreModel("MNRV-31A")])
        let index = index(text)
        XCTAssertEqual(index.models.map(\.name), ["MNRV-31A", "QXRT-990", "ZPL-2040"])
        XCTAssertEqual(index.models.map(\.file), Array(repeating: CrewModelsFile.fileName, count: 3))
        // A hyphenated spelling also lists the parts the index reads as models on their own.
        XCTAssertEqual(index.models[1].tokens, ["QXRT-990", "QXRT990", "QX-RT990", "RT990"])
        XCTAssertEqual(index.resolve(token: "qxrt990").map(\.name), ["QXRT-990"])
        XCTAssertEqual(index.resolve(token: "ZPL2040").map(\.name), ["ZPL-2040"])
        XCTAssertTrue(index.namesModel("MNRV-31A"))
        XCTAssertFalse(index.namesModel("E999"), "a fault code is never a model")
    }

    func testTheFixtureFileIsWhatRenderWritesAndTheIndexReadsIt() throws {
        let text = String(decoding: try fixture("experience-only-vault/crew-models.md"), as: UTF8.self)
        XCTAssertEqual(text, try CrewModelsFile.render(models: [CoreModel("QXRT-990", aliases: ["QXRT990"]),
                                                                CoreModel("ZPL-2040", aliases: ["ZPL2040"])]))
        let index = index(text)
        XCTAssertEqual(index.models.map(\.name), ["QXRT-990", "ZPL-2040"])
        XCTAssertEqual(index.knownModelTokens, ["QXRT-990", "QXRT990", "ZPL-2040", "ZPL2040"])
    }

    func testIsIndexableAgreesWithTheIndexsOwnHeadingRule() {
        let spellings = ["QXRT-990", "QXRT990", "ZPL-2040", "MNRV-31A", "AB-12", "AB12C", "E999", "E-999", "R-410A", "454B",
                         "QXRT", "990", "Corner unit", "QX 990", "QX.990", "1.25", "A1B2C", "-QX990", "ＱＸ９９０Ａ", "AB1C2D"]
        for spelling in spellings {
            let app = VaultModelIndex.isModelLike(spelling, minimumLength: VaultModelIndex.headingMinimumLength)
                && VaultModelIndex.modelLikeTokens(in: spelling, minimumLength: VaultModelIndex.headingMinimumLength)
                    .map { $0.uppercased() }.first == spelling.uppercased()
            XCTAssertEqual(CrewModelsFile.isIndexable(spelling), app, spelling)
        }
    }

    func testEveryIndexableSpellingIsAKnownTokenOnceRendered() throws {
        for spelling in ["QXRT-990", "AB12C", "MNRV-31A", "ZZ-9000-X"] where CrewModelsFile.isIndexable(spelling) {
            let index = index(try CrewModelsFile.render(models: [CoreModel(spelling)]))
            XCTAssertTrue(index.knownModelTokens.contains(spelling.uppercased()), spelling)
        }
    }

    func testAModelEntryPublishesToAVaultThatKnowsItOnlyFromCrewModels() throws {
        let text = String(decoding: try fixture("experience-only-vault/crew-models.md"), as: UTF8.self)
        let target = LearningCorpus.VaultTarget(id: "fixture-crew-units", modelIndex: index(text))
        let known = LearningEntry(subject: .model(modelToken: "QXRT-990"), vaultIDs: ["fixture-crew-units"], finding: "x",
                                  approvedAt: Date(timeIntervalSince1970: 1_795_564_800), approvedByRole: "Owner",
                                  approvedByName: "Owner", origin: .recollection)
        XCTAssertEqual(LearningCorpus.placement(of: known, among: [target]).published, ["fixture-crew-units"])
        let stranger = LearningEntry(subject: .model(modelToken: "MNOP-12345"), vaultIDs: ["fixture-crew-units"], finding: "x",
                                     approvedAt: Date(timeIntervalSince1970: 1_795_564_800), approvedByRole: "Owner",
                                     approvedByName: "Owner", origin: .recollection)
        XCTAssertEqual(LearningCorpus.placement(of: stranger, among: [target]).unknownModel, ["fixture-crew-units"])
    }

    func testTheExperienceOnlyVaultPassesThePhonesValidator() throws {
        let bundle = Bundle(for: CrewModelsFileTests.self)
        let dir = try XCTUnwrap(bundle.url(forResource: "crew-experience-v1", withExtension: nil))
            .appendingPathComponent("experience-only-vault", isDirectory: true)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: try fixture("experience-only-vault/manifest.json"))
        XCTAssertEqual(manifest.files, [CrewModelsFile.fileName])
        XCTAssertTrue(manifest.documents.isEmpty)
        XCTAssertEqual(OpenGlasses.VaultPackRules.manifestIssues(.init(manifest), manualOnly: false), [])
        let result = VaultValidator.validate(directory: dir)
        XCTAssertTrue(result.isValid, "\(result.issues)")
        XCTAssertTrue(manifest.promptRules.joined(separator: " ").contains(CrewExperienceSheet.leadIn))
    }
}
