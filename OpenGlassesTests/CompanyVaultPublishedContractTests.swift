import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LV P0 — the phone's half of the published-vault fields and the sealed core, held to the
/// licence core's (`CompanyVaultContract`, compiled into this bundle) and to the golden fixtures in
/// `Contracts/fixtures/company-vaults-v2/` both sides read.
final class CompanyVaultPublishedContractTests: XCTestCase {

    static let profileId = CompanyVaultContractTests.profileId
    static let otherProfileId = "fixture-other-company"
    static let otherSecret = Data(SHA256.hash(data: Data("Avenkin public fixture other company secret v2".utf8)))
    static var companySecret: Data { CompanyVaultContractTests.companySecret }
    static var publicKey: String { CompanyVaultContractTests.publicKey }
    static let baseId = "fixture-split-systems"
    static let layerId = "fixture-split-systems-company"

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CompanyVaultPublishedContractTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "company-vaults-v2", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    static func catalog(_ name: String = "catalog-v12.json", generation: Int = 12) throws -> CompanyVaultCatalog.Verified {
        try CompanyVaultCatalog.verify(try fixture(name), publicKeyBase64: publicKey, profileId: profileId,
                                       highWater: nil, profileGeneration: generation).get()
    }

    // MARK: - Identifiers

    func testTheCoreSealIsTheCoresOwn() {
        XCTAssertEqual(CompanyCoreSeal.sealingDomain, CompanyVaultContract.CoreSeal.domain)
        XCTAssertEqual(CompanyCoreSeal.sealingDomain, "openglasses.company-core.v1",
                       "Changing it stops every core already delivered from opening.")
        XCTAssertEqual(CompanyCoreSeal.header, CompanyVaultContract.CoreSeal.header())
        XCTAssertNotEqual(CompanyCoreSeal.header, CompanyManualSeal.header)
        XCTAssertEqual(CompanyManualSeal.header, CompanyVaultContract.ManualSeal.header(), "the manual seal's bytes are unchanged")
        XCTAssertEqual(CompanyVaultCatalog.maximumExpectsPerVault, CompanyVaultContract.Limits.expectsPerVault)
        for size in [1, 1_048_576, 1_048_577, 3 * 1_048_576 + 5] {
            XCTAssertEqual(CompanyCoreSeal.sealedLength(plaintextBytes: size), CompanyVaultContract.CoreSeal.sealedLength(plaintextBytes: size))
            XCTAssertEqual(CompanyCoreSeal.plaintextLength(sealedBytes: CompanyCoreSeal.sealedLength(plaintextBytes: size)), size)
        }
        XCTAssertNil(CompanyCoreSeal.plaintextLength(sealedBytes: 9 + 28), "no pack seals to a header and an empty chunk")
        XCTAssertNil(CompanyCoreSeal.plaintextLength(sealedBytes: 9 + 1_048_576 + 28 + 10), "a last chunk shorter than its overhead")
    }

    // MARK: - v1 unchanged

    func testTheV1GoldenCatalogReadsWithNoPublishingFields() throws {
        let verified = try CompanyVaultCatalog.verify(try CompanyVaultContractTests.fixture("catalog-v7.json"),
                                                      publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                      highWater: nil, profileGeneration: 7).get()
        let vault = try XCTUnwrap(verified.vaults.first)
        XCTAssertNil(vault.publisher)
        XCTAssertNil(vault.expects)
        XCTAssertNil(vault.extends)
        XCTAssertFalse(vault.isSealedCore)
        XCTAssertFalse(vault.isFrozen)
        XCTAssertFalse(vault.isCompanyLayer)
        XCTAssertEqual(verified.problems, [:])
        let encoded = String(decoding: try JSONEncoder().encode(vault), as: UTF8.self)
        for key in ["publisher", "sealedCore", "expects", "frozen", "extends"] { XCTAssertFalse(encoded.contains(key), key) }
    }

    // MARK: - The v2 golden catalog

    func testTheGoldenPublishedCatalogVerifiesOnThePhone() throws {
        let verified = try Self.catalog()
        XCTAssertEqual(verified.problems, [:])
        XCTAssertEqual(verified.vaults.map(\.vaultId), [Self.baseId, Self.layerId])
        let base = verified.vaults[0], layer = verified.vaults[1]
        XCTAssertEqual(base.publisher, .init(id: "p-fixture", name: "Fixture Publishing", version: 5))
        XCTAssertTrue(base.isSealedCore)
        XCTAssertFalse(base.isFrozen)
        XCTAssertEqual(base.expects?.map(\.key), ["install-manual", "service-manual", "wiring-diagram"])
        XCTAssertEqual(base.expects?.last?.edition, "2024")
        XCTAssertNil(base.expects?.last?.revision)
        XCTAssertEqual(layer.extends, Self.baseId)
        XCTAssertTrue(layer.isCompanyLayer)
        XCTAssertNil(layer.publisher)
        XCTAssertFalse(layer.isSealedCore)
        XCTAssertEqual(verified.manuals.map(\.title), ["Installation manual", "Service manual"])

        // Field for field what the core reads.
        let core = try CompanyVaultContract.open(try Self.fixture("catalog-v12.json"), publicKeyBase64: Self.publicKey,
                                                 profileId: Self.profileId)
        XCTAssertEqual(core.vaults.map(\.publisher?.name), verified.vaults.map(\.publisher?.name))
        XCTAssertEqual(core.vaults.map(\.expects?.count), verified.vaults.map(\.expects?.count))
        XCTAssertEqual(core.vaults.map(\.extends), verified.vaults.map(\.extends))
        XCTAssertEqual(core.vaults[0].expects?.map(\.revision), base.expects?.map(\.revision))
    }

    func testTheGoldenSealedCoreOpensToASignedPackForItsCompanyOnly() throws {
        let base = try XCTUnwrap(try Self.catalog().vaults.first)
        let sealed = try Self.fixture("fixture-split-systems-7.zip.sealed")
        XCTAssertEqual(VaultPackArchive.sha256Hex(sealed), base.sha256, "the row's checksum is the sealed file's")
        XCTAssertEqual(sealed.count, base.sizeBytes)
        let pack = try CompanyCoreSeal.open(sealed, context: .init(profileId: Self.profileId, vault: base),
                                            companySecret: Self.companySecret)
        XCTAssertEqual(pack, try Self.fixture("fixture-split-systems-7.zip"))
        XCTAssertEqual(CompanyCoreSeal.plaintextLength(sealedBytes: base.sizeBytes), pack.count)

        // The signature is over the plaintext pack, as for any pack.
        let zip = try XCTUnwrap(ZipArchiveReader(data: pack))
        let packJSON = try XCTUnwrap(zip.entryData(named: "pack.json"))
        var files: [String: Data] = [:]
        for name in zip.entryNames where name != "pack.json" { files[name] = zip.entryData(named: name) }
        XCTAssertEqual(Set(files.keys), ["manifest.json", "safety.md", "fault_codes.md"])
        XCTAssertTrue(VaultPackSignature.verify(signatureBase64: base.packSignature, packManifestData: packJSON, files: files,
                                                publicKeyBase64: Self.publicKey))
        XCTAssertFalse(VaultPackSignature.verify(signatureBase64: base.packSignature, packManifestData: packJSON,
                                                 files: files.merging(["safety.md": Data("changed".utf8)]) { $1 },
                                                 publicKeyBase64: Self.publicKey))

        // Another company's secret, another company, another version: nothing opens.
        XCTAssertThrowsError(try CompanyCoreSeal.open(sealed, context: .init(profileId: Self.profileId, vault: base),
                                                      companySecret: Self.otherSecret)) {
            XCTAssertEqual($0 as? CompanyCoreSeal.Failure, .tampered)
        }
        XCTAssertThrowsError(try CompanyCoreSeal.open(sealed, context: .init(profileId: Self.otherProfileId, vault: base),
                                                      companySecret: Self.otherSecret))
        XCTAssertThrowsError(try CompanyCoreSeal.open(sealed, context: .init(profileId: Self.profileId, vaultId: base.vaultId,
                                                                             packId: base.id, version: "8"),
                                                      companySecret: Self.companySecret))
        XCTAssertThrowsError(try CompanyCoreSeal.open(sealed, context: .init(profileId: Self.profileId, vault: base),
                                                      companySecret: Data(count: 5))) {
            XCTAssertEqual($0 as? CompanyCoreSeal.Failure, .noSecret)
        }
        // A sealed manual never opens as a core, nor a core as a manual.
        let manualRow = try XCTUnwrap(try Self.catalog().manuals.first)
        let sealedManual = try Self.fixture("Installation manual.md.sealed")
        XCTAssertThrowsError(try CompanyCoreSeal.open(sealedManual, context: .init(profileId: Self.profileId, vault: base),
                                                      companySecret: Self.companySecret))
        XCTAssertThrowsError(try CompanyManualSeal.open(sealed, context: .init(profileId: Self.profileId, manual: manualRow),
                                                        companySecret: Self.companySecret))
    }

    func testTheGoldenManualsOpenAfterTheSealRefactor() throws {
        for row in try Self.catalog().manuals {
            let plain = try CompanyManualSeal.open(try Self.fixture(row.fileName + ".sealed"),
                                                   context: .init(profileId: Self.profileId, manual: row),
                                                   companySecret: Self.companySecret)
            XCTAssertEqual(plain, try Self.fixture(row.fileName))
            XCTAssertEqual(VaultPackArchive.sha256Hex(plain), row.revision)
        }
    }

    func testWhatEitherSideSealsAsACoreTheOtherOpens() throws {
        let pack = Data((0..<(CompanyChunkedSeal.chunkSize + 2_500)).map { UInt8($0 % 233) })
        let app = CompanyCoreSeal.Context(profileId: Self.profileId, vaultId: Self.baseId,
                                          packId: "com.openglasses.vault." + Self.baseId, version: "7")
        let core = CompanyVaultContract.CoreSeal.Context(profileId: Self.profileId, vaultId: Self.baseId,
                                                         packId: "com.openglasses.vault." + Self.baseId, version: "7")
        let fromService = try CompanyVaultContract.CoreSeal.seal(pack, context: core, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyCoreSeal.open(fromService, context: app, companySecret: Self.companySecret), pack)
        let opened = try CompanyCoreSeal.open(length: fromService.count, read: { fromService.subdata(in: $0) }, context: app,
                                              companySecret: Self.companySecret) { _ in }
        XCTAssertEqual(opened.bytes, pack.count)
        XCTAssertEqual(opened.digest, VaultPackArchive.sha256Hex(pack))
        let fromApp = try CompanyCoreSeal.seal(pack, context: app, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyVaultContract.CoreSeal.open(fromApp, context: core, companySecret: Self.companySecret), pack)
        var flipped = fromService
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try CompanyCoreSeal.open(flipped, context: app, companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? CompanyCoreSeal.Failure, .tampered)
        }
    }

    func testTheFrozenCatalogMarksTheEntryAndKeepsItsVersion() throws {
        let frozen = try Self.catalog("catalog-frozen-v13.json", generation: 13)
        XCTAssertTrue(frozen.vaults[0].isFrozen)
        XCTAssertEqual(frozen.vaults[0].version, try Self.catalog().vaults[0].version)
        XCTAssertEqual(frozen.problems, [:])
    }

    // MARK: - Negative catalogs

    /// The service refuses to sign these; a phone that receives one anyway leaves the broken row
    /// out, names it on that row, and uses the rest.
    func testThePhoneLeavesOutWhatTheServiceRefuses() throws {
        struct Case: Decodable { let name: String; let catalog: CompanyVaultCatalog.Payload }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try CompanyVaultCatalog.decoder.decode(Cases.self, from: try Self.fixture("negative-catalogs.json")).cases
        XCTAssertEqual(cases.map(\.name), ["extends-missing", "extends-with-publisher", "extends-a-layer", "expects-key-twice"])
        var outcomes: [String: (kept: [String], problems: Set<String>)] = [:]
        for item in cases {
            let screened = CompanyVaultCatalog.screen(item.catalog)
            outcomes[item.name] = (screened.vaults.map(\.vaultId), Set(screened.problems.keys))
        }
        XCTAssertEqual(outcomes["extends-missing"]?.kept, [Self.baseId])
        XCTAssertEqual(outcomes["extends-missing"]?.problems, [Self.layerId])
        XCTAssertEqual(outcomes["extends-with-publisher"]?.kept, [Self.baseId])
        XCTAssertEqual(outcomes["extends-with-publisher"]?.problems, [Self.layerId])
        XCTAssertEqual(outcomes["extends-a-layer"]?.kept, [Self.baseId, Self.layerId])
        XCTAssertEqual(outcomes["extends-a-layer"]?.problems, ["fixture-layer-two"])
        XCTAssertEqual(outcomes["expects-key-twice"]?.kept, [])
        XCTAssertEqual(outcomes["expects-key-twice"]?.problems, [Self.baseId])
    }

    func testALayerWhoseVaultWasLeftOutGoesWithItAndItsManualsToo() throws {
        let verified = try Self.catalog()
        func row(_ vault: CompanyVaultCatalog.Vault, sha256: String? = nil) -> CompanyVaultCatalog.Vault {
            var copy = vault
            if let sha256 { copy = .init(id: vault.id, vaultId: vault.vaultId, version: vault.version, name: vault.name,
                                         summary: vault.summary, author: vault.author, minAppBuild: vault.minAppBuild,
                                         sizeBytes: vault.sizeBytes, downloadURL: vault.downloadURL, sha256: sha256,
                                         packSignature: vault.packSignature, publisher: vault.publisher,
                                         sealedCore: vault.sealedCore, expects: vault.expects, frozen: vault.frozen,
                                         extends: vault.extends) }
            return copy
        }
        let brokenBase = row(verified.vaults[0], sha256: "not-a-digest")
        let screened = CompanyVaultCatalog.screen(.init(
            format: CompanyVaultCatalog.formatId, version: 1, profileId: Self.profileId, generation: 12, issued: Date(),
            manualsOnAnyNetwork: false, vaults: [verified.vaults[1], brokenBase], manuals: verified.manuals))
        XCTAssertEqual(screened.vaults, [])
        XCTAssertEqual(screened.manuals, [])
        XCTAssertEqual(Set(screened.problems.keys), [Self.baseId, Self.layerId])
    }

    func testABadPublishingFieldLeavesOnlyThatRowOut() {
        let base = CompanyVaultCatalog.Vault(id: "com.openglasses.vault." + Self.baseId, vaultId: Self.baseId, version: "7",
                                             name: "Fixture Split Systems", summary: nil, author: nil, minAppBuild: nil,
                                             sizeBytes: 100, downloadURL: "https://licence.example.test/v.zip",
                                             sha256: String(repeating: "a", count: 64), packSignature: "s")
        XCTAssertTrue(CompanyVaultCatalog.publishingFieldsAreSound(base))
        var bad: [CompanyVaultCatalog.Vault] = []
        var v = base; v.publisher = .init(id: "p fixture", name: "Fixture Publishing", version: 5); bad.append(v)
        v = base; v.publisher = .init(id: "p-fixture", name: " ", version: 5); bad.append(v)
        v = base; v.publisher = .init(id: "p-fixture", name: "Fixture Publishing", version: 0); bad.append(v)
        v = base; v.extends = Self.baseId; bad.append(v)
        v = base; v.expects = [.init(key: "k", title: "Installation manual", revision: "ABC")]; bad.append(v)
        v = base; v.expects = [.init(key: "k", title: "Installation manual", edition: "")]; bad.append(v)
        v = base; v.expects = [.init(key: "k", title: "  ")]; bad.append(v)
        v = base; v.expects = (0...CompanyVaultCatalog.maximumExpectsPerVault).map { .init(key: "m\($0)", title: "Manual \($0)") }
        bad.append(v)
        for vault in bad {
            XCTAssertFalse(CompanyVaultCatalog.publishingFieldsAreSound(vault), "\(vault)")
            XCTAssertNotNil(CompanyVaultCatalog.problem(with: vault))
        }
        v = base; v.publisher = .init(id: "p-fixture", name: "Fixture Publishing", version: 5); v.sealedCore = true; v.frozen = true
        v.expects = [.init(key: "install-manual", title: "Installation manual", edition: "Rev C",
                           revision: String(repeating: "b", count: 64))]
        XCTAssertTrue(CompanyVaultCatalog.publishingFieldsAreSound(v))
    }
}
