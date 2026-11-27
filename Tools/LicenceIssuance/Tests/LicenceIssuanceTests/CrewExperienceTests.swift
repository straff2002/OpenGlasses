import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Plan NF P0 — the crew experience sheet's shared core against the golden fixtures in
/// `Contracts/fixtures/crew-experience-v1/`, which the app's `CrewExperienceSheetTests` read too.
/// Invented brands, models, codes and people only.
final class CrewExperienceTests: XCTestCase {

    typealias Sheet = CrewExperienceSheet
    typealias Contract = CompanyVaultContract

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/crew-experience-v1", isDirectory: true)
    }

    static let profileId = "fixture-company"
    static let issuedAt: Int64 = 1_795_564_800 // 2026-11-25T00:00:00Z
    /// The company-vault fixtures' company secret (`company-vaults-v1/fixture-keys.json`): SHA-256 of
    /// a public label, with no authority anywhere.
    static let companySecret = Data(SHA256.hash(data: Data("Avenkin public fixture company secret v1".utf8)))
    static let setURL = "https://licence.example.test/c/opaque/x/fixture-crew-units-1"

    /// The sealed fixture's nonces, from the chunk index, so it regenerates to the same bytes.
    static func fixtureNonce(_ index: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(SHA256.hash(data: Data("Avenkin public fixture crew experience nonce \(index)".utf8))).prefix(12))
    }

    /// `set-v1.json` as the portal seals it for `fixture-company`, sequence 1.
    func sealedSet(_ set: Data) throws -> Data {
        try Contract.ExperienceSeal.seal(set, context: .init(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                             sequence: 1, revision: digest(set)),
                                         companySecret: Self.companySecret, nonce: Self.fixtureNonce)
    }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }
    func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T { try JSONDecoder().decode(T.self, from: fixture(name)) }

    /// Ids `00…01`, `00…02`, … from `start`: the fixtures' stand-in for minted ids.
    static func ids(from start: Int = 1) -> () -> String {
        var next = start
        return {
            defer { next += 1 }
            let digits = String(next, radix: 16)
            return String(repeating: "0", count: 32 - digits.count) + digits
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    // MARK: - What the fixtures are made of

    func parsed(_ csv: String, vault: String = "vault.json") throws -> Sheet.Parsed {
        try Sheet.parse(csv: fixture(csv), vault: decode(Sheet.Vault.self, vault))
    }

    func cleanEntries() throws -> [CrewExperienceSet.Entry] {
        Sheet.entries(from: try parsed("clean.csv"), approvedBy: try decode(Sheet.Approval.self, "approval.json"), newID: Self.ids())
    }

    struct Reupload: Codable, Equatable {
        let report: CrewExperienceSheet.Report
        let entries: [CrewExperienceSet.Entry]
        let diff: CrewExperienceSheet.Diff
    }

    func reupload() throws -> Reupload {
        let current = try decode(CrewExperienceSet.self, "set-v1.json").entries
        let later = Sheet.Approval(role: "Service manager", name: "Avery Example", approvedAt: Self.issuedAt + 21 * 86_400)
        let sheet = try parsed("reupload.csv", vault: "vault-reupload.json")
        let entries = Sheet.entries(from: sheet, approvedBy: later, current: current, newID: Self.ids(from: 5))
        return Reupload(report: Sheet.report(sheet), entries: entries, diff: Sheet.diff(current: current, next: entries))
    }

    static let crewModels: [VaultStarter.Model] = [.init("ZPL-2040", aliases: ["ZPL2040"]), .init("QXRT-990", aliases: ["QXRT990"])]

    func experienceRow(_ set: Data, sequence: Int = 1, count: Int = 4) -> Contract.Experience {
        .init(sequence: sequence, count: count, sizeBytes: set.count, revision: digest(set),
              sealedSha256: (try? digest(sealedSet(set))) ?? String(repeating: "c", count: 64),
              downloadURL: Self.setURL)
    }

    func vaultRow(_ experience: Contract.Experience?, vaultId: String = "fixture-crew-units", extends: String? = nil) -> Contract.Vault {
        .init(id: Contract.packIdPrefix + vaultId, vaultId: vaultId, version: "1", name: "Fixture Crew Units",
              sizeBytes: 2_048, downloadURL: "https://licence.example.test/c/opaque/v/\(vaultId)-1.zip",
              sha256: String(repeating: "a", count: 64), packSignature: "c2lnbmF0dXJl", extends: extends, experience: experience)
    }

    func catalog(_ vaults: [Contract.Vault], generation: Int = 30) -> Contract.Catalog {
        .init(profileId: Self.profileId, generation: generation, issued: Date(timeIntervalSince1970: TimeInterval(Self.issuedAt)),
              vaults: vaults, manuals: [])
    }

    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    struct NegativeCatalog: Codable { let name: String; let payload: Contract.Catalog; let refusal: String }
    struct NegativeAdvance: Codable { let name: String; let previous: Contract.Catalog; let next: Contract.Catalog; let refusal: String }
    struct Citation: Codable, Equatable { let subject: String; let approvedAt: Int64; let role: String; let name: String }

    func negativeCatalogs(_ set: Data) -> [NegativeCatalog] {
        let good = experienceRow(set)
        let base = vaultRow(nil, vaultId: "fixture-crew-units")
        func row(_ e: Contract.Experience) -> Contract.Catalog { catalog([vaultRow(e)]) }
        return [
            NegativeCatalog(name: "experience on a company layer",
                            payload: catalog([base, vaultRow(good, vaultId: "fixture-crew-units-company", extends: "fixture-crew-units")]),
                            refusal: "fixture-crew-units-company is a company layer; its crew experience belongs on fixture-crew-units"),
            NegativeCatalog(name: "sequence 0",
                            payload: row(.init(sequence: 0, count: 4, sizeBytes: good.sizeBytes, revision: good.revision,
                                               sealedSha256: good.sealedSha256, downloadURL: good.downloadURL)),
                            refusal: "fixture-crew-units's crew experience sequence must be 1 or more"),
            NegativeCatalog(name: "more entries than a set holds",
                            payload: row(.init(sequence: 1, count: 5_001, sizeBytes: good.sizeBytes, revision: good.revision,
                                               sealedSha256: good.sealedSha256, downloadURL: good.downloadURL)),
                            refusal: "fixture-crew-units's crew experience holds at most 5000 entries"),
            NegativeCatalog(name: "over 2 MiB",
                            payload: row(.init(sequence: 1, count: 4, sizeBytes: 2 * 1_048_576 + 1, revision: good.revision,
                                               sealedSha256: good.sealedSha256, downloadURL: good.downloadURL)),
                            refusal: "fixture-crew-units's crew experience is 2097153 bytes; the limit is 2097152"),
            NegativeCatalog(name: "a revision that is not a digest",
                            payload: row(.init(sequence: 1, count: 4, sizeBytes: good.sizeBytes, revision: "ABC",
                                               sealedSha256: good.sealedSha256, downloadURL: good.downloadURL)),
                            refusal: "fixture-crew-units's crew experience has no revision or checksum"),
            NegativeCatalog(name: "a download address that is not HTTPS",
                            payload: row(.init(sequence: 1, count: 4, sizeBytes: good.sizeBytes, revision: good.revision,
                                               sealedSha256: good.sealedSha256, downloadURL: "http://licence.example.test/x")),
                            refusal: "fixture-crew-units's crew experience download address must be HTTPS")
        ]
    }

    func negativeAdvances(_ set: Data) -> [NegativeAdvance] {
        let one = experienceRow(set, sequence: 2)
        let changed = Contract.Experience(sequence: 2, count: 5, sizeBytes: one.sizeBytes, revision: String(repeating: "d", count: 64),
                                          sealedSha256: one.sealedSha256, downloadURL: one.downloadURL)
        let lower = experienceRow(set, sequence: 1)
        let raised = Contract.Experience(sequence: 3, count: 5, sizeBytes: one.sizeBytes, revision: changed.revision,
                                         sealedSha256: one.sealedSha256, downloadURL: one.downloadURL)
        return [
            NegativeAdvance(name: "the sequence goes down", previous: catalog([vaultRow(one)], generation: 30),
                            next: catalog([vaultRow(lower)], generation: 31),
                            refusal: "fixture-crew-units's crew experience sequence went down from 2 to 1"),
            NegativeAdvance(name: "a changed set at the same sequence", previous: catalog([vaultRow(one)], generation: 30),
                            next: catalog([vaultRow(changed)], generation: 31),
                            refusal: "fixture-crew-units's crew experience changed without a higher sequence"),
            NegativeAdvance(name: "a new set at the same generation", previous: catalog([vaultRow(one)], generation: 30),
                            next: catalog([vaultRow(raised)], generation: 30),
                            refusal: "a crew experience changed, so the generation must rise above 30")
        ]
    }

    static let citationCases: [(String, Int64, String)] = [
        ("QXRT-990", 1_795_564_800, "Service manager"),
        ("walk-in cooler", 1_795_564_799, "Owner"),
        ("ZPL-2040", 951_782_400, "Lead technician") // 2000-02-29, a leap day
    ]

    // MARK: - Regenerating

    /// `REGENERATE_CREW_EXPERIENCE_FIXTURES=1 swift test --package-path Tools/LicenceIssuance --filter
    /// CrewExperienceTests/testRegenerateFixtures`. The inputs (`*.csv` other than `current-sheet.csv`
    /// and `reupload.csv`, `vault*.json`, `approval.json`, `sheet-refusals.json`) are hand-written;
    /// everything else is written here, byte for byte the same on every run.
    func testRegenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_CREW_EXPERIENCE_FIXTURES"] == "1" else {
            throw XCTSkip("set REGENERATE_CREW_EXPERIENCE_FIXTURES=1 to rewrite the fixtures")
        }
        let dir = Self.fixtures
        func write(_ value: some Encodable, _ name: String) throws {
            try Self.encoder().encode(value).write(to: dir.appendingPathComponent(name))
        }
        try write(Sheet.report(try parsed("clean.csv")), "clean.expected.json")
        let entries = try cleanEntries()
        try write(entries, "clean.entries.json")
        let set = CrewExperienceSet(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 1, issuedAt: Self.issuedAt, entries: entries)
        try CrewExperienceSet.check(set)
        let setBytes = try CrewExperienceSet.encoder().encode(set)
        try setBytes.write(to: dir.appendingPathComponent("set-v1.json"))
        try sealedSet(setBytes).write(to: dir.appendingPathComponent("set-v1.sealed"))
        try write(Sheet.report(try parsed("refusals.csv", vault: "vault-with-set.json")), "refusals.expected.json")
        try write(Sheet.report(try parsed("redaction.csv")), "redaction.expected.json")

        // Download current sheet, then the administrator's edits three weeks later: entry 2's fix
        // changed, entry 3 deleted, two rows added at the end.
        let current = Sheet.csv(entries: entries)
        try Data(current.utf8).write(to: dir.appendingPathComponent("current-sheet.csv"))
        var lines = current.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        lines[2] = lines[2].replacingOccurrences(of: "Replaced the stage two relay on the board", with: "Replaced the stage two relay and its socket")
        lines.remove(at: 3)
        lines.append(",Fixturetherm,QXRT-990,,E996,Blower stops after ten minutes,Blower motor amps,Cleaned the blower wheel,,fixed it most times,,")
        lines.append(",Examplair,ZPL-2040,,,Ice on the evaporator,Airflow across the coil,Replaced the clogged return filter,,fixed it once,,")
        try Data((lines.joined(separator: "\r\n") + "\r\n").utf8).write(to: dir.appendingPathComponent("reupload.csv"))
        let reuploadVault = Sheet.Vault(vaultId: "fixture-crew-units", modelSpellings: ["QXRT-990", "QXRT990", "ZPL-2040", "ZPL2040"],
                                        equipmentTypes: ["rooftop unit", "walk-in cooler"], currentEntryIDs: entries.map(\.entryID))
        try write(reuploadVault, "vault-reupload.json")
        try write(try reupload(), "reupload.expected.json")

        let vault = try CrewModelsFile.experienceOnlyVault(name: "Fixture Crew Units", id: "fixture-crew-units", models: Self.crewModels)
        let vaultDir = dir.appendingPathComponent("experience-only-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try vault.manifestJSON.write(to: vaultDir.appendingPathComponent("manifest.json"))
        for file in vault.files { try Data(file.contents.utf8).write(to: vaultDir.appendingPathComponent(file.name)) }

        let good = catalog([vaultRow(experienceRow(setBytes))])
        try Contract.check(good)
        try Contract.encoder().encode(good).write(to: dir.appendingPathComponent("catalog-experience-v1.json"))
        let encoder = Self.encoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(negativeCatalogs(setBytes)).write(to: dir.appendingPathComponent("negative-catalogs.json"))
        try encoder.encode(negativeAdvances(setBytes)).write(to: dir.appendingPathComponent("negative-advances.json"))
        try write(Self.citationCases.map { Citation(subject: $0.0, approvedAt: $0.1, role: $0.2,
                                                    name: Sheet.citationName(subject: $0.0, approvedAt: $0.1, role: $0.2)) },
                  "citations.json")
    }

    // MARK: - The golden fixtures

    func testTheCleanSheetMatchesItsReportAndEntries() throws {
        let report = Sheet.report(try parsed("clean.csv"))
        XCTAssertEqual(report, try decode(Sheet.Report.self, "clean.expected.json"))
        XCTAssertEqual(report.ready, 4)
        XCTAssertEqual(report.ignoredColumns, ["photo"])
        XCTAssertEqual(try cleanEntries(), try decode([CrewExperienceSet.Entry].self, "clean.entries.json"))
    }

    func testEveryRowRefusalIsNamedWithItsRow() throws {
        let report = Sheet.report(try parsed("refusals.csv", vault: "vault-with-set.json"))
        XCTAssertEqual(report, try decode(Sheet.Report.self, "refusals.expected.json"))
        let names = Set(report.rows.flatMap { $0.problems.map(\.name) })
        XCTAssertEqual(names, ["noSubject", "unknownModel", "unknownEquipmentType", "missingSymptom", "missingFix", "tooLong",
                               "controlCharacter", "badId", "duplicateId", "unknownId", "howSureIsANumber", "badDate", "extraCells"])
        // Nothing is published from a refused row.
        let sheet = try parsed("refusals.csv", vault: "vault-with-set.json")
        let published = Sheet.entries(from: sheet, approvedBy: try decode(Sheet.Approval.self, "approval.json"), newID: Self.ids())
        XCTAssertEqual(published.map(\.entryID), ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"])
    }

    func testRedactionMarksTheRowAndNamesThePatterns() throws {
        XCTAssertEqual(Sheet.report(try parsed("redaction.csv")), try decode(Sheet.Report.self, "redaction.expected.json"))
    }

    func testEverySheetRefusal() throws {
        struct Case: Decodable { let `case`: String; let csvBase64: String; let refusal: String }
        let vault = try decode(Sheet.Vault.self, "vault.json")
        for item in try decode([Case].self, "sheet-refusals.json") {
            let data = try XCTUnwrap(Data(base64Encoded: item.csvBase64))
            XCTAssertThrowsError(try Sheet.parse(csv: data, vault: vault), item.case) {
                XCTAssertEqual(($0 as? Sheet.SheetRefusal)?.name, item.refusal, item.case)
            }
        }
    }

    func testTheReuploadDiff() throws {
        let result = try reupload()
        XCTAssertEqual(result, try decode(Reupload.self, "reupload.expected.json"))
        XCTAssertEqual(result.diff.summary, "2 new, 1 changed, 1 removed")
    }

    func testTheCurrentSheetUploadsBackUnchanged() throws {
        let entries = try cleanEntries()
        XCTAssertEqual(Sheet.csv(entries: entries), String(decoding: try fixture("current-sheet.csv"), as: UTF8.self))
        let vault = Sheet.Vault(vaultId: "fixture-crew-units", modelSpellings: ["QXRT-990", "QXRT990", "ZPL-2040", "ZPL2040"],
                                equipmentTypes: ["rooftop unit", "walk-in cooler"], currentEntryIDs: entries.map(\.entryID))
        let again = try Sheet.parse(csv: Data(Sheet.csv(entries: entries).utf8), vault: vault)
        XCTAssertEqual(again.toFix.count, 0)
        let later = Sheet.Approval(role: "Owner", name: nil, approvedAt: Self.issuedAt + 86_400)
        let republished = Sheet.entries(from: again, approvedBy: later, current: entries, newID: Self.ids(from: 99))
        XCTAssertEqual(republished, entries)
        XCTAssertEqual(Sheet.diff(current: entries, next: republished).summary, "0 new, 0 changed, 0 removed")
    }

    func testTheSetFixtureChecksAndDecodes() throws {
        let set = try decode(CrewExperienceSet.self, "set-v1.json")
        XCTAssertNoThrow(try CrewExperienceSet.check(set))
        XCTAssertEqual(set.kind, "avenkin.crew-experience-set")
        XCTAssertEqual(set.entries, try decode([CrewExperienceSet.Entry].self, "clean.entries.json"))
        XCTAssertEqual(try CrewExperienceSet.encoder().encode(set), try fixture("set-v1.json"))
    }

    // MARK: - The seal (P1)

    func testTheSealedFixtureIsTheSetSealedForTheFixtureCompany() throws {
        let set = try fixture("set-v1.json")
        let sealed = try fixture("set-v1.sealed")
        XCTAssertEqual(try sealedSet(set), sealed, "the golden sealed set regenerates to the same bytes")
        XCTAssertEqual(sealed.count, Contract.ExperienceSeal.sealedLength(plaintextBytes: set.count))
        XCTAssertEqual(sealed.prefix(4), Data("OGCX".utf8))
        let context = Contract.ExperienceSeal.Context(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                      sequence: 1, revision: digest(set))
        XCTAssertEqual(try Contract.ExperienceSeal.open(sealed, context: context, companySecret: Self.companySecret), set)
        // The catalog fixture points at exactly these bytes.
        let catalog = try Contract.decoder().decode(Contract.Catalog.self, from: try fixture("catalog-experience-v1.json"))
        let pointer = try XCTUnwrap(catalog.vaults.first?.experience)
        XCTAssertEqual(pointer.sealedSha256, digest(sealed))
        XCTAssertEqual(pointer.revision, digest(set))
        XCTAssertEqual(pointer.sizeBytes, set.count)
    }

    func testTheSealBindsCompanyVaultSequenceAndRevision() throws {
        let set = try fixture("set-v1.json")
        let sealed = try fixture("set-v1.sealed")
        let revision = digest(set)
        let wrong: [Contract.ExperienceSeal.Context] = [
            .init(profileId: "fixture-other-company", vaultId: "fixture-crew-units", sequence: 1, revision: revision),
            .init(profileId: Self.profileId, vaultId: "fixture-other-vault", sequence: 1, revision: revision),
            .init(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 2, revision: revision),
            .init(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 1, revision: String(repeating: "d", count: 64)),
        ]
        for context in wrong {
            XCTAssertThrowsError(try Contract.ExperienceSeal.open(sealed, context: context, companySecret: Self.companySecret), "\(context)")
        }
        let right = Contract.ExperienceSeal.Context(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 1, revision: revision)
        XCTAssertThrowsError(try Contract.ExperienceSeal.open(sealed, context: right, companySecret: ProfileContract.Credential.newSecret()))
        var flipped = sealed
        flipped[flipped.count - 5] ^= 0x01
        XCTAssertThrowsError(try Contract.ExperienceSeal.open(flipped, context: right, companySecret: Self.companySecret))
        XCTAssertThrowsError(try Contract.ExperienceSeal.seal(set, context: .init(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                                                  sequence: 1, revision: String(repeating: "d", count: 64)),
                                                              companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? Contract.ManualSeal.Problem, .wrongRevision)
        }
    }

    func testNeitherAManualNorACoreOpensAsASet() throws {
        let set = try fixture("set-v1.json")
        let revision = digest(set)
        let asManual = try Contract.ManualSeal.seal(set, context: .init(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                                        fileName: "1", revision: revision),
                                                    companySecret: Self.companySecret)
        XCTAssertThrowsError(try Contract.ExperienceSeal.open(asManual, context: .init(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                                                       sequence: 1, revision: revision),
                                                              companySecret: Self.companySecret))
        let asSet = try fixture("set-v1.sealed")
        XCTAssertThrowsError(try Contract.ManualSeal.open(asSet, context: .init(profileId: Self.profileId, vaultId: "fixture-crew-units",
                                                                                fileName: "1", revision: revision),
                                                          companySecret: Self.companySecret))
    }

    func testSealSetChecksTheSetAndWritesThePointer() throws {
        let set = try decode(CrewExperienceSet.self, "set-v1.json")
        let made = try Contract.ExperienceSeal.sealSet(set, downloadURL: Self.setURL, companySecret: Self.companySecret,
                                                       nonce: Self.fixtureNonce)
        XCTAssertEqual(made.sealed, try fixture("set-v1.sealed"))
        let catalog = try Contract.decoder().decode(Contract.Catalog.self, from: try fixture("catalog-experience-v1.json"))
        XCTAssertEqual(made.experience, catalog.vaults.first?.experience)
        let bad = CrewExperienceSet(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 0,
                                    issuedAt: Self.issuedAt, entries: set.entries)
        XCTAssertThrowsError(try Contract.ExperienceSeal.sealSet(bad, downloadURL: Self.setURL, companySecret: Self.companySecret))
    }

    func testCitationNames() throws {
        for item in try decode([Citation].self, "citations.json") {
            XCTAssertEqual(Sheet.citationName(subject: item.subject, approvedAt: item.approvedAt, role: item.role), item.name)
        }
        XCTAssertEqual(Sheet.citationName(subject: "QXRT-990", approvedAt: 1_795_564_800, role: "Service manager"),
                       "Crew experience · QXRT-990 · 2026-11-25 · approved by Service manager")
    }

    func testTheExperienceCatalogFieldAndItsChecks() throws {
        let payload = try fixture("catalog-experience-v1.json")
        let catalog = try Contract.decoder().decode(Contract.Catalog.self, from: payload)
        XCTAssertNoThrow(try Contract.check(catalog))
        XCTAssertEqual(try Contract.encoder().encode(catalog), payload)
        let set = try fixture("set-v1.json")
        XCTAssertEqual(catalog.vaults.first?.experience?.revision, digest(set))
        XCTAssertEqual(catalog.vaults.first?.experience?.sizeBytes, set.count)

        let decoder = Contract.decoder()
        for item in try decoder.decode([NegativeCatalog].self, from: fixture("negative-catalogs.json")) {
            XCTAssertThrowsError(try Contract.check(item.payload), item.name) {
                XCTAssertEqual($0 as? Contract.Refusal, .invalid(item.refusal), item.name)
            }
        }
        for item in try decoder.decode([NegativeAdvance].self, from: fixture("negative-advances.json")) {
            XCTAssertEqual(Contract.experienceAdvanceProblem(previous: item.previous, next: item.next), item.refusal, item.name)
        }
    }

    func testARowWithoutExperienceIsTheBytesItWas() throws {
        let bytes = String(decoding: try Contract.encoder().encode(vaultRow(nil)), as: UTF8.self)
        XCTAssertFalse(bytes.contains("experience"))
        // The v1 golden catalog decodes and encodes back to its exact bytes.
        let v1 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/company-vaults-v1/catalog-v7.json")
        let envelope = try JSONDecoder().decode(Contract.Envelope.self, from: Data(contentsOf: v1))
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        XCTAssertEqual(try Contract.encoder().encode(try Contract.decoder().decode(Contract.Catalog.self, from: payload)), payload)
    }

    func testAdvanceAllowsANewerSetAndARemovedOne() throws {
        let set = try fixture("set-v1.json")
        let one = catalog([vaultRow(experienceRow(set, sequence: 1))], generation: 30)
        XCTAssertNil(Contract.experienceAdvanceProblem(previous: one, next: catalog([vaultRow(experienceRow(set, sequence: 1))], generation: 30)))
        let newer = Contract.Experience(sequence: 2, count: 5, sizeBytes: set.count, revision: String(repeating: "d", count: 64),
                                        sealedSha256: String(repeating: "c", count: 64), downloadURL: "https://licence.example.test/x/2")
        XCTAssertNil(Contract.experienceAdvanceProblem(previous: one, next: catalog([vaultRow(newer)], generation: 31)))
        XCTAssertNil(Contract.experienceAdvanceProblem(previous: one, next: catalog([vaultRow(nil)], generation: 31)))
        XCTAssertNotNil(Contract.experienceAdvanceProblem(previous: one, next: catalog([vaultRow(nil)], generation: 30)))
    }

    func testTheExperienceOnlyVaultPassesThePackRules() throws {
        let manifest = try XCTUnwrap(VaultPackRules.Manifest(json: try fixture("experience-only-vault/manifest.json")))
        XCTAssertEqual(VaultPackRules.manifestIssues(manifest), [])
        XCTAssertEqual(manifest.files, [CrewModelsFile.fileName])
        let models = String(decoding: try fixture("experience-only-vault/crew-models.md"), as: UTF8.self)
        XCTAssertNil(VaultPackRules.listedFileIssue(CrewModelsFile.fileName, contents: models))
        XCTAssertEqual(try CrewModelsFile.render(models: Self.crewModels), models)
        XCTAssertTrue(models.contains("## QXRT-990 (QXRT990)\n"))
        XCTAssertLessThan(models.range(of: "## QXRT-990")!.lowerBound, models.range(of: "## ZPL-2040")!.lowerBound)
    }

    func testTheExperienceOnlyStarterWritesItsEquipmentTypes() throws {
        let vault = try CrewModelsFile.experienceOnlyVault(name: "Fixture Crew Units", id: "fixture-crew-units", models: Self.crewModels,
                                                           equipmentTypes: ["rooftop unit", "walk-in cooler"])
        let manifest = try XCTUnwrap(VaultPackRules.Manifest(json: vault.manifestJSON))
        XCTAssertEqual(VaultPackRules.manifestIssues(manifest), [])
        XCTAssertEqual(manifest.equipmentTypes, ["rooftop unit", "walk-in cooler"])
        // No list, no key: the golden fixture's bytes are unchanged.
        let bare = try CrewModelsFile.experienceOnlyVault(name: "Fixture Crew Units", id: "fixture-crew-units", models: Self.crewModels)
        XCTAssertEqual(bare.manifestJSON, try fixture("experience-only-vault/manifest.json"))
        XCTAssertFalse(String(decoding: bare.manifestJSON, as: UTF8.self).contains("equipment_types"))
    }

    func testTheExperienceOnlyStarterRefusesTypesThePhoneWouldRefuse() {
        XCTAssertThrowsError(try CrewModelsFile.experienceOnlyVault(name: "Fixture Crew Units", models: Self.crewModels,
                                                                    equipmentTypes: ["rooftop unit", "Rooftop  Unit"])) {
            guard case .equipmentTypes(let issues)? = $0 as? CrewModelsFile.Problem else { return XCTFail("\($0)") }
            XCTAssertEqual(issues.count, 1)
        }
    }

    // MARK: - Not from fixtures

    func testTheSheetFileStandsAlone() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LicenceIssuance/CrewExperience.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").filter { $0.hasPrefix("import ") }, ["import Foundation"])
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for name in ["CompanyVaultContract", "ProfileContract", "IssuanceWire", "SHA256", "Curve25519"] {
            XCTAssertFalse(code.contains { $0.contains(name) }, name)
        }
    }

    func testRenderRefusesASpellingTheIndexWouldNotRead() {
        XCTAssertThrowsError(try CrewModelsFile.render(models: [.init("Corner unit")])) {
            XCTAssertEqual($0 as? CrewModelsFile.Problem, .notAModelNumber("Corner unit"))
        }
        XCTAssertThrowsError(try CrewModelsFile.render(models: [.init("QXRT-990", aliases: ["E999"])])) {
            XCTAssertEqual($0 as? CrewModelsFile.Problem, .notAModelNumber("E999"))
        }
        XCTAssertThrowsError(try CrewModelsFile.render(models: [])) { XCTAssertEqual($0 as? CrewModelsFile.Problem, .noModels) }
    }

    func testTheUploadAndSetCaps() throws {
        let vault = try decode(Sheet.Vault.self, "vault.json")
        let big = Data(repeating: 0x41, count: Sheet.Limits.bytes + 1)
        XCTAssertThrowsError(try Sheet.parse(csv: big, vault: vault)) { XCTAssertEqual($0 as? Sheet.SheetRefusal, .tooLarge(bytes: big.count)) }
        let row = "QXRT-990,Trips on start,Reseated the harness"
        let rows = "model,symptom,fix\n" + Array(repeating: row, count: Sheet.Limits.rows + 1).joined(separator: "\n")
        XCTAssertThrowsError(try Sheet.parse(csv: Data(rows.utf8), vault: vault)) {
            XCTAssertEqual($0 as? Sheet.SheetRefusal, .tooManyRows(count: Sheet.Limits.rows + 1))
        }
        let fits = "model,symptom,fix\n" + Array(repeating: row, count: Sheet.Limits.rows).joined(separator: "\n") + "\n\n\n"
        XCTAssertEqual(try Sheet.parse(csv: Data(fits.utf8), vault: vault).ready.count, Sheet.Limits.rows)

        let entry = CrewExperienceSet.Entry(entryID: Self.ids()(), subject: .model(modelToken: "QXRT-990", manufacturer: nil, equipmentType: nil),
                                            vaultIDs: ["fixture-crew-units"], finding: "x", symptom: nil, fix: nil, faultCode: nil,
                                            tried: nil, outcome: nil, approvedAt: Self.issuedAt, approvedByRole: "Owner", authorIsApprover: true)
        let twice = CrewExperienceSet(profileId: Self.profileId, vaultId: "fixture-crew-units", sequence: 1, issuedAt: Self.issuedAt,
                                      entries: [entry, entry])
        XCTAssertThrowsError(try CrewExperienceSet.check(twice))
        let elsewhere = CrewExperienceSet(profileId: Self.profileId, vaultId: "another-vault", sequence: 1, issuedAt: Self.issuedAt, entries: [entry])
        XCTAssertThrowsError(try CrewExperienceSet.check(elsewhere))
    }
}
