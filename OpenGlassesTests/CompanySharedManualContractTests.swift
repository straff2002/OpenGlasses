import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LV P3 — the phone's half of shared manuals (`CompanySharedManualSeal`, `CompanySharedManualKey`,
/// the manual row's `shared` field), held to the licence core's (`CompanyVaultContract`, compiled into
/// this bundle) and to the golden fixtures in `Contracts/fixtures/company-vaults-v3/` both sides read.
/// Invented identifiers only.
final class CompanySharedManualContractTests: XCTestCase {

    static let profileId = "fixture-company"
    static let otherProfileId = "fixture-other-company"
    static let thirdProfileId = "fixture-third-company"
    static var companySecret: Data { CompanyVaultContractTests.companySecret }
    static let otherSecret = Data(SHA256.hash(data: Data("Avenkin public fixture other company secret v2".utf8)))
    static let thirdSecret = Data(SHA256.hash(data: Data("Avenkin public fixture third company secret v3".utf8)))
    static var publicKey: String { CompanyVaultContractTests.publicKey }
    static let contentId = "c-fixture-installation-manual"

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CompanySharedManualContractTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "company-vaults-v3", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    static func catalog(_ profileId: String, generation: Int) throws -> CompanyVaultCatalog.Verified {
        try CompanyVaultCatalog.verify(try fixture("catalog-\(profileId)-v\(generation).json"), publicKeyBase64: publicKey,
                                       profileId: profileId, highWater: nil, profileGeneration: generation).get()
    }

    static func row(_ profileId: String, generation: Int) throws -> CompanyVaultCatalog.Manual {
        try XCTUnwrap(try catalog(profileId, generation: generation).manuals.first)
    }

    /// Unwrap the row's key with `secret` for `profileId` and open `file` with it.
    static func open(_ row: CompanyVaultCatalog.Manual, profileId: String, secret: Data, file: String) throws -> Data {
        let shared = try XCTUnwrap(row.shared)
        let key = try CompanySharedManualKey.unwrap(shared.wrappedKey, context: .init(profileId: profileId, shared: shared),
                                                    companySecret: secret)
        return try CompanySharedManualSeal.open(try fixture(file), context: .init(shared: shared), contentKey: key,
                                                revision: row.revision)
    }

    // MARK: - Identifiers

    func testTheSharedSealAndKeyAreTheCoresOwn() {
        XCTAssertEqual(CompanySharedManualSeal.sealingDomain, CompanyVaultContract.SharedManualSeal.domain)
        XCTAssertEqual(CompanySharedManualSeal.sealingDomain, "openglasses.shared-manual.v1",
                       "Changing it stops every shared manual already delivered from opening.")
        XCTAssertEqual(CompanySharedManualKey.derivationDomain, CompanyVaultContract.SharedManualKey.domain)
        XCTAssertEqual(CompanySharedManualKey.derivationDomain, "openglasses.shared-manual-key.v1")
        XCTAssertEqual(CompanySharedManualSeal.header, CompanyVaultContract.SharedManualSeal.header())
        XCTAssertEqual(CompanySharedManualSeal.header.prefix(4), Data("OGSM".utf8))
        XCTAssertNotEqual(CompanySharedManualSeal.header, CompanyManualSeal.header)
        XCTAssertNotEqual(CompanySharedManualSeal.header, CompanyCoreSeal.header)
        XCTAssertEqual(CompanySharedManualKey.wrappedKeyLength, CompanyVaultContract.SharedManualKey.wrappedKeyLength)
        XCTAssertEqual(CompanySharedManualSeal.contentKeyLength, CompanyVaultContract.SharedManualSeal.contentKeyLength)
        for size in [1, 1_048_576, 1_048_577, 2 * 1_048_576 + 9] {
            XCTAssertEqual(CompanySharedManualSeal.sealedLength(plaintextBytes: size),
                           CompanyVaultContract.SharedManualSeal.sealedLength(plaintextBytes: size))
        }
    }

    // MARK: - Unchanged without `shared`

    func testACompanySealedRowReadsAndEncodesWithoutShared() throws {
        let v1 = try CompanyVaultCatalog.verify(try CompanyVaultContractTests.fixture("catalog-v7.json"), publicKeyBase64: Self.publicKey,
                                                profileId: Self.profileId, highWater: nil, profileGeneration: 7).get()
        let v2 = try CompanyVaultPublishedContractTests.catalog()
        for manual in v1.manuals + v2.manuals {
            XCTAssertNil(manual.shared)
            XCTAssertFalse(manual.isShared)
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(manual), as: UTF8.self).contains("shared"))
        }
        XCTAssertEqual(v1.problems, [:])
        XCTAssertEqual(v2.problems, [:])
    }

    // MARK: - The golden catalogs

    func testBothCompaniesCatalogsCarryTheSameFileWithTheirOwnKeys() throws {
        let mine = try Self.catalog(Self.profileId, generation: 20)
        let theirs = try Self.catalog(Self.otherProfileId, generation: 20)
        XCTAssertEqual(mine.problems, [:])
        XCTAssertEqual(theirs.problems, [:])
        XCTAssertEqual(mine.vaults.first?.minAppBuild, 692)
        let a = try XCTUnwrap(mine.manuals.first), b = try XCTUnwrap(theirs.manuals.first)
        XCTAssertTrue(a.isShared)
        XCTAssertEqual(a.shared?.contentId, Self.contentId)
        XCTAssertEqual(a.shared?.keyId, 1)
        XCTAssertEqual(a.downloadURL, b.downloadURL)
        XCTAssertEqual(a.sealedSha256, b.sealedSha256)
        XCTAssertNotEqual(a.shared?.wrappedKey, b.shared?.wrappedKey)
        XCTAssertEqual(a.title, "Installation manual")
        // Field for field what the core reads.
        let core = try CompanyVaultContract.open(try Self.fixture("catalog-fixture-company-v20.json"), publicKeyBase64: Self.publicKey,
                                                 profileId: Self.profileId)
        XCTAssertEqual(core.manuals.first?.shared?.wrappedKey, a.shared?.wrappedKey)
        XCTAssertEqual(core.manuals.first?.shared?.keyId, a.shared?.keyId)
        XCTAssertEqual(core.manuals.first?.sealedSha256, a.sealedSha256)
    }

    func testBothCompaniesOpenTheOneSharedFile() throws {
        let plain = try Self.fixture("Installation manual.md")
        let sealed = try Self.fixture("installation-manual.k1.sealed")
        for (profile, secret) in [(Self.profileId, Self.companySecret), (Self.otherProfileId, Self.otherSecret)] {
            let row = try Self.row(profile, generation: 20)
            XCTAssertEqual(VaultPackArchive.sha256Hex(sealed), row.sealedSha256)
            XCTAssertEqual(sealed.count, CompanySharedManualSeal.sealedLength(plaintextBytes: row.sizeBytes))
            XCTAssertEqual(try Self.open(row, profileId: profile, secret: secret, file: "installation-manual.k1.sealed"), plain, profile)
            XCTAssertEqual(VaultPackArchive.sha256Hex(plain), row.revision)
        }
    }

    func testAThirdCompanyOpensNeither() throws {
        for profile in [Self.profileId, Self.otherProfileId] {
            let row = try Self.row(profile, generation: 20)
            for asProfile in [profile, Self.thirdProfileId] {
                XCTAssertThrowsError(try Self.open(row, profileId: asProfile, secret: Self.thirdSecret,
                                                   file: "installation-manual.k1.sealed")) {
                    XCTAssertEqual($0 as? CompanySharedManualKey.Failure, .tampered)
                }
            }
        }
    }

    func testAKeyWrappedForAnotherProfileDoesNotUnwrap() throws {
        let theirs = try Self.row(Self.otherProfileId, generation: 20)
        // The other company's row, read by this company's phone with its own secret and profile.
        XCTAssertThrowsError(try Self.open(theirs, profileId: Self.profileId, secret: Self.companySecret,
                                           file: "installation-manual.k1.sealed")) {
            XCTAssertEqual($0 as? CompanySharedManualKey.Failure, .tampered)
        }
        // Their own secret under this company's profile fails too: the profile is in the context.
        XCTAssertThrowsError(try Self.open(theirs, profileId: Self.profileId, secret: Self.otherSecret,
                                           file: "installation-manual.k1.sealed"))
    }

    func testAfterARotationBothOpenTheNewFileAndTheOldKeyOpensNothingServed() throws {
        let plain = try Self.fixture("Installation manual.md")
        let before = try Self.row(Self.profileId, generation: 20)
        for (profile, secret) in [(Self.profileId, Self.companySecret), (Self.otherProfileId, Self.otherSecret)] {
            let after = try Self.row(profile, generation: 21)
            XCTAssertEqual(after.shared?.keyId, 2)
            XCTAssertEqual(after.revision, before.revision, "the same manual, re-encrypted")
            XCTAssertNotEqual(after.downloadURL, before.downloadURL)
            XCTAssertEqual(after.sealedSha256, VaultPackArchive.sha256Hex(try Self.fixture("installation-manual.k2.sealed")))
            XCTAssertEqual(try Self.open(after, profileId: profile, secret: secret, file: "installation-manual.k2.sealed"), plain)
        }
        // The key kept from keyId 1 against the file now served.
        XCTAssertThrowsError(try Self.open(before, profileId: Self.profileId, secret: Self.companySecret,
                                           file: "installation-manual.k2.sealed")) {
            XCTAssertEqual($0 as? CompanySharedManualSeal.Failure, .tampered)
        }
    }

    // MARK: - Negatives

    /// Every key in `negative-keys.json` fails on the phone where it fails in the core.
    func testTheNegativeKeysNeverOpenTheManual() throws {
        struct Case: Decodable {
            let name: String; let profileId: String; let secretLabel: String
            let shared: CompanyVaultCatalog.SharedManual; let file: String; let revision: String; let fails: String
        }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try JSONDecoder().decode(Cases.self, from: try Self.fixture("negative-keys.json")).cases
        XCTAssertEqual(cases.count, 4)
        for item in cases {
            let secret = Data(SHA256.hash(data: Data(item.secretLabel.utf8)))
            let context = CompanySharedManualKey.Context(profileId: item.profileId, shared: item.shared)
            switch item.fails {
            case "unwrap":
                XCTAssertThrowsError(try CompanySharedManualKey.unwrap(item.shared.wrappedKey, context: context, companySecret: secret),
                                     item.name) { XCTAssertEqual($0 as? CompanySharedManualKey.Failure, .tampered, item.name) }
            case "open":
                let key = try CompanySharedManualKey.unwrap(item.shared.wrappedKey, context: context, companySecret: secret)
                XCTAssertThrowsError(try CompanySharedManualSeal.open(try Self.fixture(item.file), context: .init(shared: item.shared),
                                                                      contentKey: key, revision: item.revision), item.name) {
                    XCTAssertEqual($0 as? CompanySharedManualSeal.Failure, .tampered, item.name)
                }
            default:
                XCTFail("\(item.name): \(item.fails)")
            }
        }
    }

    /// The service refuses to sign these; a phone that receives one anyway leaves the shared row out
    /// and names it on its vault's row, and keeps the vault.
    func testThePhoneLeavesOutTheSharedRowsTheServiceRefuses() throws {
        struct Case: Decodable { let name: String; let catalog: CompanyVaultCatalog.Payload }
        struct Cases: Decodable { let cases: [Case] }
        let cases = try CompanyVaultCatalog.decoder.decode(Cases.self, from: try Self.fixture("negative-catalogs.json")).cases
        XCTAssertEqual(cases.map(\.name), ["shared-without-min-app-build", "shared-key-id-zero", "shared-content-id-unsafe",
                                           "shared-wrapped-key-short"])
        for item in cases {
            let screened = CompanyVaultCatalog.screen(item.catalog)
            XCTAssertEqual(screened.vaults.map(\.vaultId), ["fixture-split-systems"], item.name)
            XCTAssertEqual(screened.manuals, [], item.name)
            XCTAssertEqual(screened.problems["fixture-split-systems"],
                           "A manual can't be downloaded: its entry in the vault list is incomplete.", item.name)
        }
    }

    func testTheSharedFieldsChecks() throws {
        let good = try XCTUnwrap(try Self.row(Self.profileId, generation: 20).shared)
        XCTAssertTrue(CompanyVaultCatalog.sharedFieldIsSound(good))
        for bad in [CompanyVaultCatalog.SharedManual(contentId: "", keyId: 1, wrappedKey: good.wrappedKey),
                    .init(contentId: "c fixture", keyId: 1, wrappedKey: good.wrappedKey),
                    .init(contentId: Self.contentId, keyId: -1, wrappedKey: good.wrappedKey),
                    .init(contentId: Self.contentId, keyId: 1, wrappedKey: good.wrappedKey + "AAAA"),
                    .init(contentId: Self.contentId, keyId: 1, wrappedKey: "")] {
            XCTAssertFalse(CompanyVaultCatalog.sharedFieldIsSound(bad), "\(bad)")
        }
    }

    // MARK: - Across the two implementations

    func testWhatEitherSideSealsAndWrapsTheOtherOpens() throws {
        let plain = Data((0..<(CompanyChunkedSeal.chunkSize + 1_234)).map { UInt8($0 % 241) })
        let revision = VaultPackArchive.sha256Hex(plain)
        let key = CompanyVaultContract.SharedManualSeal.newContentKey()
        let core = CompanyVaultContract.SharedManualSeal.Context(contentId: Self.contentId, keyId: 4)
        let app = CompanySharedManualSeal.Context(contentId: Self.contentId, keyId: 4)
        let fromService = try CompanyVaultContract.SharedManualSeal.seal(plain, context: core, contentKey: key)
        XCTAssertEqual(try CompanySharedManualSeal.open(fromService, context: app, contentKey: key, revision: revision), plain)
        let fromApp = try CompanySharedManualSeal.seal(plain, context: app, contentKey: key)
        XCTAssertEqual(try CompanyVaultContract.SharedManualSeal.open(fromApp, context: core, contentKey: key, revision: revision), plain)
        XCTAssertThrowsError(try CompanySharedManualSeal.open(fromService, context: app, contentKey: key, revision: String(repeating: "0", count: 64))) {
            XCTAssertEqual($0 as? CompanySharedManualSeal.Failure, .wrongRevision)
        }

        let wrapped = try CompanyVaultContract.SharedManualKey.wrap(
            key, context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4), companySecret: Self.companySecret)
        XCTAssertEqual(try CompanySharedManualKey.unwrap(wrapped, context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4),
                                                         companySecret: Self.companySecret), key)
        let wrappedOnPhone = try CompanySharedManualKey.wrap(key, context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4),
                                                             companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyVaultContract.SharedManualKey.unwrap(
            wrappedOnPhone, context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4), companySecret: Self.companySecret), key)
        XCTAssertThrowsError(try CompanySharedManualKey.unwrap(wrapped, context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4),
                                                               companySecret: Data(count: 3))) {
            XCTAssertEqual($0 as? CompanySharedManualKey.Failure, .noSecret)
        }
        XCTAssertThrowsError(try CompanySharedManualKey.unwrap("c2hvcnQ=", context: .init(profileId: Self.profileId, contentId: Self.contentId, keyId: 4),
                                                               companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? CompanySharedManualKey.Failure, .malformed)
        }
        // A shared file never opens as a company manual, nor a company manual as a shared file.
        let manualRow = try XCTUnwrap(try CompanyVaultPublishedContractTests.catalog().manuals.first)
        XCTAssertThrowsError(try CompanyManualSeal.open(fromService, context: .init(profileId: Self.profileId, manual: manualRow),
                                                        companySecret: key))
        let sealedManual = try CompanyVaultPublishedContractTests.fixture("Installation manual.md.sealed")
        XCTAssertThrowsError(try CompanySharedManualSeal.open(sealedManual, context: app, contentKey: Self.companySecret,
                                                              revision: manualRow.revision))
    }
}
