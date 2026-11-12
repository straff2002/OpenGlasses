import CryptoKit
import XCTest
@testable import OpenGlasses

/// Plan LR P0 — the phone's half of the company vault contract, held to the licence core's
/// (`CompanyVaultContract`, compiled into this bundle) and to the golden fixtures both sides read.
final class CompanyVaultContractTests: XCTestCase {

    static let profileId = "fixture-company"
    static let packKey = try! Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(SHA256.hash(data: Data("Avenkin public fixture pack-catalog key v1".utf8))))
    static let companySecret = Data(SHA256.hash(data: Data("Avenkin public fixture company secret v1".utf8)))
    static var publicKey: String { packKey.publicKey.rawRepresentation.base64EncodedString() }

    static func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: CompanyVaultContractTests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "company-vaults-v1", withExtension: nil))
        return try Data(contentsOf: url.appendingPathComponent(name))
    }

    // MARK: - Identifiers and limits

    func testTheDomainsAndLimitsAreTheCoresOwn() {
        XCTAssertEqual(CompanyVaultCatalog.signingDomain, Data(CompanyVaultContract.catalogDomain.utf8))
        XCTAssertEqual(CompanyVaultCatalog.formatId, CompanyVaultContract.catalogFormat)
        XCTAssertEqual(CompanyVaultCatalog.supportedVersion, CompanyVaultContract.catalogVersion)
        XCTAssertEqual(CompanyVaultCatalog.maximumEnvelopeBytes, CompanyVaultContract.Limits.catalogEnvelopeBytes)
        XCTAssertEqual(CompanyManualSeal.sealingDomain, CompanyVaultContract.ManualSeal.domain)
        XCTAssertEqual(CompanyManualSeal.sealingDomain, "openglasses.company-manual.v1",
                       "Changing it stops every manual already delivered from opening.")
        XCTAssertEqual(CompanyManualSeal.header, CompanyVaultContract.ManualSeal.header())
        XCTAssertEqual(CompanyManualSeal.chunkSize, CompanyVaultContract.ManualSeal.chunkSize)
        for size in [1, 1_048_576, 1_048_577, 134_217_728] {
            XCTAssertEqual(CompanyManualSeal.sealedLength(plaintextBytes: size),
                           CompanyVaultContract.ManualSeal.sealedLength(plaintextBytes: size))
        }
        XCTAssertEqual(CompanyVaultLimits.pdfBytes, CompanyVaultContract.Limits.pdfBytes)
        XCTAssertEqual(CompanyVaultLimits.wordBytes, CompanyVaultContract.Limits.wordBytes)
        XCTAssertEqual(CompanyVaultLimits.textBytes, CompanyVaultContract.Limits.textBytes)
        XCTAssertEqual(CompanyVaultLimits.vaultCoreBytes, CompanyVaultContract.Limits.vaultCoreBytes)
        XCTAssertEqual(CompanyVaultLimits.vaultCoreFileBytes, CompanyVaultContract.Limits.vaultCoreFileBytes)
        XCTAssertEqual(CompanyVaultLimits.vaultsPerCatalog, CompanyVaultContract.Limits.vaultsPerCatalog)
        XCTAssertEqual(CompanyVaultLimits.manualsPerCatalog, CompanyVaultContract.Limits.manualsPerCatalog)
        XCTAssertEqual(Set(CompanyVaultCatalog.ManualKind.allCases.map(\.rawValue)),
                       Set(CompanyVaultContract.ManualKind.allCases.map(\.rawValue)))
        for kind in CompanyVaultCatalog.ManualKind.allCases {
            XCTAssertEqual(kind.extensions, CompanyVaultContract.ManualKind(rawValue: kind.rawValue)?.extensions)
        }
        XCTAssertEqual(CompanyVaultContract.packIdPrefix, VaultPackManifest.productPrefix)
    }

    // MARK: - The pointer

    func testAProfileWithoutCompanyVaultsAppliesAndEncodesExactlyAsBefore() throws {
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let settings: [String: RawSetting] = ["fieldAssistEnabled": RawSetting(.bool(true), .default)]
        let without = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Fixture Ltd", issued: issued,
                                    leaseDays: 30, settings: settings)
        var with = without
        with.companyVaults = .init(catalog: "https://licence.example.test/c/opaque/vaults.json", generation: 7, minAppBuild: 680)
        XCTAssertEqual(ProfileApplier.apply(profile: without, resolvableVaultIds: []),
                       ProfileApplier.apply(profile: with, resolvableVaultIds: []),
                       "the pointer changes nothing the applier writes")
        let encoded = String(decoding: try ProfileVerification.encoder.encode(without), as: UTF8.self)
        XCTAssertFalse(encoded.contains("companyVaults"))
        // Field for field the core's pointer.
        let core = try JSONDecoder().decode(ProfileContract.CompanyVaults.self, from: try Self.fixture("pointer-v1.json"))
        let app = try JSONDecoder().decode(ConfigProfile.CompanyVaultsReference.self, from: try Self.fixture("pointer-v1.json"))
        XCTAssertEqual(app.catalog, core.catalog)
        XCTAssertEqual(app.generation, core.generation)
        XCTAssertEqual(app.minAppBuild, core.minAppBuild)
        XCTAssertNotNil(app.catalogURL)

        // A profile minted by the core with the pointer verifies and reads it.
        let key = Curve25519.Signing.PrivateKey()
        var input = ProfileContract.Input(profileId: "p", organizationName: "Fixture Ltd", leaseDays: 30)
        input.companyVaults = core
        let document = try IssuanceWire.profile(ProfileContract.document(input, keyId: "k", issued: issued, adminPasscode: nil),
                                                signer: key.signature(for:))
        guard case .profile(let profile) = try ProfileVerification.verify(
            document, keys: ["k": key.publicKey.rawRepresentation.base64EncodedString()]) else { return XCTFail("not a profile") }
        XCTAssertEqual(profile.companyVaults?.generation, 7)
        XCTAssertEqual(profile.companyVaults?.catalogURL?.host, "licence.example.test")
    }

    func testAMalformedPointerNeverRefusesTheProfile() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for pointer in [#"7"#, #"{"catalog":7,"generation":"x"}"#, #"{"catalog":"http://plain.test/v.json","generation":3}"#] {
            let json = #"{"companyVaults":"# + pointer + #","format":"openglasses.org-profile","issued":"2027-01-15T08:00:00Z","keyId":"k","leaseDays":30,"organizationName":"O","profileId":"p","schemaVersion":1,"settings":{}}"#
            let profile = try decoder.decode(ConfigProfile.self, from: Data(json.utf8))
            XCTAssertNil(profile.companyVaults?.catalogURL, pointer)
        }
    }

    // MARK: - The catalog

    func testTheGoldenCatalogVerifiesOnThePhone() throws {
        let envelope = try Self.fixture("catalog-v7.json")
        let verified = try CompanyVaultCatalog.verify(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                      highWater: nil, profileGeneration: 7).get()
        XCTAssertEqual(verified.generation, 7)
        XCTAssertEqual(verified.problems, [:])
        XCTAssertEqual(verified.vaults.map(\.vaultId), ["fixture_rtu"])
        XCTAssertEqual(verified.vaults[0].entry.sha256, VaultPackArchive.sha256Hex(try Self.fixture("fixture_rtu-1.0.0.zip")))
        XCTAssertEqual(verified.manuals.map(\.title), ["RTU Wiring"])
        let core = try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId)
        XCTAssertEqual(core.vaults.map(\.id), verified.vaults.map(\.id))
        XCTAssertEqual(core.manuals.map(\.revision), verified.manuals.map(\.revision))
    }

    func testTheCatalogIsBoundToOneCompanyAndNeverGoesBack() throws {
        func envelope(generation: Int, profileId: String = CompanyVaultContractTests.profileId) throws -> Data {
            try CompanyVaultContract.sign(.init(profileId: profileId, generation: generation, issued: Date(),
                                                vaults: [], manuals: []), signer: Self.packKey.signature(for:))
        }
        XCTAssertEqual(CompanyVaultCatalog.verify(try envelope(generation: 3, profileId: "another"), publicKeyBase64: Self.publicKey,
                                                  profileId: Self.profileId, highWater: nil, profileGeneration: 0),
                       .failure(.otherCompany))
        XCTAssertEqual(CompanyVaultCatalog.verify(try envelope(generation: 3), publicKeyBase64: Self.publicKey,
                                                  profileId: Self.profileId, highWater: 4, profileGeneration: 4),
                       .failure(.replayed(generation: 3, highWater: 4)))
        XCTAssertEqual(CompanyVaultCatalog.verify(try envelope(generation: 3), publicKeyBase64: Self.publicKey,
                                                  profileId: Self.profileId, highWater: 2, profileGeneration: 5),
                       .failure(.behindProfile(generation: 3, profileGeneration: 5)))
        XCTAssertEqual(CompanyVaultCatalog.verify(try envelope(generation: 3),
                                                  publicKeyBase64: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString(),
                                                  profileId: Self.profileId, highWater: nil, profileGeneration: 0),
                       .failure(.badSignature))
        // The public pack catalog's signature (no domain) never verifies as a company catalog.
        let payload = try CompanyVaultContract.encoder().encode(CompanyVaultContract.Catalog(
            profileId: Self.profileId, generation: 3, issued: Date(), vaults: [], manuals: []))
        let undomained = try JSONEncoder().encode(["payload": payload.base64EncodedString(),
                                                   "signature": try Self.packKey.signature(for: payload).base64EncodedString()])
        XCTAssertEqual(CompanyVaultCatalog.verify(undomained, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                  highWater: nil, profileGeneration: 0), .failure(.badSignature))
        XCTAssertNoThrow(try CompanyVaultCatalog.verify(try envelope(generation: 4), publicKeyBase64: Self.publicKey,
                                                        profileId: Self.profileId, highWater: 4, profileGeneration: 4).get(),
                         "the same generation again is a retry, not a replay")
    }

    /// The core refuses an over-limit row before signing; a phone that receives one anyway (a
    /// signed catalog is not a reason to trust a size) leaves it out and names it.
    func testThePhoneEnforcesTheCapsAgain() throws {
        func manual(_ name: String, size: Int, kind: CompanyVaultCatalog.ManualKind) -> CompanyVaultCatalog.Manual {
            .init(vaultId: "fixture_rtu", fileName: name, revision: String(repeating: "b", count: 64), sizeBytes: size,
                  sealedSha256: String(repeating: "c", count: 64), downloadURL: "https://licence.example.test/m", kind: kind)
        }
        let vault = CompanyVaultCatalog.Vault(id: "com.openglasses.vault.fixture_rtu", vaultId: "fixture_rtu", version: "1",
                                              name: "Fixture Rooftop Units", summary: nil, author: nil, minAppBuild: nil,
                                              sizeBytes: 100, downloadURL: "https://licence.example.test/v.zip",
                                              sha256: String(repeating: "a", count: 64), packSignature: "s")
        let big = CompanyVaultCatalog.Vault(id: "com.openglasses.vault.big", vaultId: "big", version: "1", name: "Big",
                                            summary: nil, author: nil, minAppBuild: nil,
                                            sizeBytes: CompanyVaultLimits.vaultCoreBytes + 1,
                                            downloadURL: "https://licence.example.test/b.zip",
                                            sha256: String(repeating: "a", count: 64), packSignature: "s")
        let screened = CompanyVaultCatalog.screen(.init(
            format: CompanyVaultCatalog.formatId, version: 1, profileId: Self.profileId, generation: 2, issued: Date(),
            manualsOnAnyNetwork: false, vaults: [vault, big],
            manuals: [manual("Fine.pdf", size: 10, kind: .pdf),
                      manual("Huge.pdf", size: CompanyVaultLimits.pdfBytes + 1, kind: .pdf),
                      manual("Notes.pdf", size: 10, kind: .md),
                      manual("../x.md", size: 10, kind: .md)]))
        XCTAssertEqual(screened.vaults.map(\.vaultId), ["fixture_rtu"])
        XCTAssertEqual(screened.manuals.map(\.fileName), ["Fine.pdf"])
        XCTAssertNotNil(screened.problems["big"])
        XCTAssertNotNil(screened.problems["fixture_rtu"])
    }

    // MARK: - The seal

    func testTheGoldenManualOpensOnThePhoneAndNowhereElse() throws {
        let envelope = try Self.fixture("catalog-v7.json")
        let row = try XCTUnwrap(try CompanyVaultCatalog.verify(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                               highWater: nil, profileGeneration: 7).get().manuals.first)
        let sealed = try Self.fixture("RTU Wiring.md.sealed")
        XCTAssertEqual(VaultPackArchive.sha256Hex(sealed), row.sealedSha256)
        XCTAssertEqual(sealed.count, CompanyManualSeal.sealedLength(plaintextBytes: row.sizeBytes))
        let plain = try CompanyManualSeal.open(sealed, context: .init(profileId: Self.profileId, manual: row),
                                               companySecret: Self.companySecret)
        XCTAssertEqual(plain, try Self.fixture("RTU Wiring.md"))
        XCTAssertThrowsError(try CompanyManualSeal.open(sealed, context: .init(profileId: "another", manual: row),
                                                        companySecret: Self.companySecret))
        XCTAssertThrowsError(try CompanyManualSeal.open(sealed, context: .init(profileId: Self.profileId, manual: row),
                                                        companySecret: Data(repeating: 7, count: 32)))
        var flipped = sealed
        flipped[flipped.count - 1] ^= 1
        XCTAssertThrowsError(try CompanyManualSeal.open(flipped, context: .init(profileId: Self.profileId, manual: row),
                                                        companySecret: Self.companySecret)) {
            XCTAssertEqual($0 as? CompanyManualSeal.Failure, .tampered)
        }
    }

    func testWhatEitherSideSealsTheOtherOpens() throws {
        let plain = Data((0..<(CompanyManualSeal.chunkSize + 4_000)).map { UInt8($0 % 241) })
        let revision = VaultPackArchive.sha256Hex(plain)
        let appContext = CompanyManualSeal.Context(profileId: Self.profileId, vaultId: "fixture_rtu", fileName: "Wiring.pdf", revision: revision)
        let coreContext = CompanyVaultContract.ManualSeal.Context(profileId: Self.profileId, vaultId: "fixture_rtu",
                                                                  fileName: "Wiring.pdf", revision: revision)
        let fromService = try CompanyVaultContract.ManualSeal.seal(plain, context: coreContext, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyManualSeal.open(fromService, context: appContext, companySecret: Self.companySecret), plain)
        let fromApp = try CompanyManualSeal.seal(plain, context: appContext, companySecret: Self.companySecret)
        XCTAssertEqual(try CompanyVaultContract.ManualSeal.open(fromApp, context: coreContext, companySecret: Self.companySecret), plain)
        let wrongRevision = CompanyManualSeal.Context(profileId: Self.profileId, vaultId: "fixture_rtu", fileName: "Wiring.pdf",
                                                      revision: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try CompanyManualSeal.open(fromService, context: wrongRevision, companySecret: Self.companySecret))
    }
}
