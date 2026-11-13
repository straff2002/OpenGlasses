import XCTest
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto // swift-crypto: the same API on Linux (the service's containers)
#endif
@testable import LicenceIssuance

/// Plan LR — the company vault contract: the profile's pointer, the signed catalog, the sealed
/// manual, the limits and the seat renewal's installed vaults. The golden fixtures under
/// `Contracts/fixtures/company-vaults-v1/` are read here and by the app's `CompanyVaultContractTests`.
final class CompanyVaultTests: XCTestCase {

    // MARK: - Fixtures

    /// Invented, public labels: the keys derived from them have no authority anywhere.
    static let packKeyLabel = "Avenkin public fixture pack-catalog key v1"
    static let secretLabel = "Avenkin public fixture company secret v1"
    static let profileId = "fixture-company"
    static let issued = Date(timeIntervalSince1970: 1_800_000_000)

    static var packKey: Curve25519.Signing.PrivateKey {
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(packKeyLabel.utf8))))
    }
    static var publicKey: String { packKey.publicKey.rawRepresentation.base64EncodedString() }
    static var companySecret: Data { Data(SHA256.hash(data: Data(secretLabel.utf8))) }

    static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contracts/fixtures/company-vaults-v1", isDirectory: true)
    }

    func fixture(_ name: String) throws -> Data { try Data(contentsOf: Self.fixtures.appendingPathComponent(name)) }

    func vault(_ vaultId: String = "fixture_rtu", version: String = "1.0.0", size: Int = 2_048) -> CompanyVaultContract.Vault {
        .init(id: "com.openglasses.vault." + vaultId, vaultId: vaultId, version: version, name: "Fixture Rooftop Units",
              sizeBytes: size, downloadURL: "https://licence.example.test/c/opaque/\(vaultId)-\(version).zip",
              sha256: String(repeating: "a", count: 64), packSignature: "c2lnbmF0dXJl")
    }

    func manual(_ fileName: String = "RTU Wiring.md", vaultId: String = "fixture_rtu", size: Int = 100,
                kind: CompanyVaultContract.ManualKind = .md) -> CompanyVaultContract.Manual {
        .init(vaultId: vaultId, fileName: fileName, revision: String(repeating: "b", count: 64), sizeBytes: size,
              sealedSha256: String(repeating: "c", count: 64), downloadURL: "https://licence.example.test/c/opaque/m/1",
              kind: kind)
    }

    func catalog(generation: Int = 7, vaults: [CompanyVaultContract.Vault]? = nil,
                 manuals: [CompanyVaultContract.Manual]? = nil, profileId: String = profileId) -> CompanyVaultContract.Catalog {
        .init(profileId: profileId, generation: generation, issued: Self.issued, vaults: vaults ?? [vault()],
              manuals: manuals ?? [manual()])
    }

    func signed(_ catalog: CompanyVaultContract.Catalog) throws -> Data {
        try CompanyVaultContract.sign(catalog, signer: Self.packKey.signature(for:))
    }

    // MARK: - The pointer

    func testAProfileWithoutCompanyVaultsIsTheBytesItWas() throws {
        let input = ProfileContract.Input(profileId: "p", organizationName: "Fixture Ltd", leaseDays: 30)
        let document = ProfileContract.document(input, keyId: "k", issued: Self.issued, adminPasscode: nil)
        let bytes = String(decoding: try IssuanceWire.encoder(profile: true).encode(document), as: UTF8.self)
        XCTAssertFalse(bytes.contains("companyVaults"))
        XCTAssertEqual(bytes, #"{"format":"openglasses.org-profile","issued":"2027-01-15T08:00:00Z","keyId":"k","leaseDays":30,"organizationName":"Fixture Ltd","profileId":"p","schemaVersion":1,"settings":{}}"#)

        var withVaults = input
        withVaults.companyVaults = .init(catalog: "https://licence.example.test/c/opaque/vaults.json", generation: 7, minAppBuild: 680)
        try ProfileContract.check(withVaults, adminPasscode: false, now: Self.issued)
        let pointed = String(decoding: try IssuanceWire.encoder(profile: true).encode(
            ProfileContract.document(withVaults, keyId: "k", issued: Self.issued, adminPasscode: nil)), as: UTF8.self)
        XCTAssertTrue(pointed.contains(#""companyVaults":{"catalog":"https://licence.example.test/c/opaque/vaults.json","generation":7,"minAppBuild":680}"#), pointed)
        XCTAssertEqual(try JSONDecoder().decode(ProfileContract.CompanyVaults.self, from: try fixture("pointer-v1.json")),
                       withVaults.companyVaults)
    }

    func testThePointerIsHeldToHTTPSAndAPositiveGeneration() {
        for bad in [ProfileContract.CompanyVaults(catalog: "http://licence.example.test/v.json", generation: 1),
                    .init(catalog: "https://user:pw@licence.example.test/v.json", generation: 1),
                    .init(catalog: "https://licence.example.test/v.json#x", generation: 1),
                    .init(catalog: "https://licence.example.test/v.json", generation: 0),
                    .init(catalog: "https://licence.example.test/v.json", generation: 1, minAppBuild: 0)] {
            XCTAssertThrowsError(try ProfileContract.checkCompanyVaults(bad), "\(bad)")
        }
    }

    // MARK: - The catalog

    func testASignedCatalogOpensForItsCompanyAndNoOther() throws {
        let envelope = try signed(catalog())
        let opened = try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                   highWater: 6, profileGeneration: 7)
        XCTAssertEqual(opened, catalog())
        XCTAssertThrowsError(try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: "another")) {
            XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .otherCompany)
        }
        let stranger = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try CompanyVaultContract.open(envelope, publicKeyBase64: stranger, profileId: Self.profileId)) {
            XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .badSignature)
        }
    }

    func testAnOlderGenerationIsAReplayAndALaggingHostIsNamed() throws {
        let envelope = try signed(catalog(generation: 5))
        XCTAssertThrowsError(try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                           highWater: 6)) {
            XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .replayed(generation: 5, highWater: 6))
        }
        XCTAssertThrowsError(try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                           highWater: 4, profileGeneration: 6)) {
            XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .behindProfile(generation: 5, profileGeneration: 6))
        }
        XCTAssertNoThrow(try CompanyVaultContract.open(envelope, publicKeyBase64: Self.publicKey, profileId: Self.profileId,
                                                       highWater: 5, profileGeneration: 5), "the same generation again is not a replay")
    }

    /// The pack-catalog key also signs the public vault-pack catalog, over its payload alone. The
    /// domain keeps either document's signature from verifying as the other's.
    func testTheCatalogSignatureIsDomainSeparated() throws {
        let payload = try CompanyVaultContract.encoder().encode(catalog())
        let undomained = try Self.packKey.signature(for: payload)
        let forged = try CompanyVaultContract.encoder().encode(
            CompanyVaultContract.Envelope(payload: payload.base64EncodedString(), signature: undomained.base64EncodedString()))
        XCTAssertThrowsError(try CompanyVaultContract.open(forged, publicKeyBase64: Self.publicKey, profileId: Self.profileId)) {
            XCTAssertEqual($0 as? CompanyVaultContract.Refusal, .badSignature)
        }
        XCTAssertEqual(CompanyVaultContract.catalogDomain, "openglasses.company-vault-catalog.v1\n")
    }

    func testTheServiceRefusesWhatThePhoneWouldRefuse() {
        let cases: [(CompanyVaultContract.Catalog, String)] = [
            (catalog(vaults: [vault(size: CompanyVaultContract.Limits.vaultCoreBytes + 1)]), "limit is"),
            (catalog(manuals: [manual("Big.pdf", size: CompanyVaultContract.Limits.pdfBytes + 1, kind: .pdf)]), "at most"),
            (catalog(manuals: [manual("Notes.docx", size: CompanyVaultContract.Limits.wordBytes + 1, kind: .docx)]), "at most"),
            (catalog(manuals: [manual("Notes.md", size: CompanyVaultContract.Limits.textBytes + 1)]), "at most"),
            (catalog(manuals: [manual("Wiring.pdf")]), "not a md file"),
            (catalog(manuals: [manual("../escape.md")]), "not a file name"),
            (catalog(manuals: [manual(".hidden.md")]), "not a file name"),
            (catalog(manuals: [manual(vaultId: "elsewhere")]), "not a vault in this catalog"),
            (catalog(manuals: [manual(), manual()]), "listed twice"),
            (catalog(vaults: [vault(), vault()]), "listed twice"),
            (catalog(generation: 0), "generation"),
            (catalog(manuals: [manual("A.pdf", size: CompanyVaultContract.Limits.pdfBytes, kind: .pdf),
                               manual("B.pdf", size: CompanyVaultContract.Limits.pdfBytes, kind: .pdf),
                               manual("C.pdf", size: CompanyVaultContract.Limits.pdfBytes, kind: .pdf)]), "limit"),
        ]
        for (bad, expected) in cases {
            XCTAssertThrowsError(try CompanyVaultContract.check(bad, companyTotalBytes: 300 * 1_048_576)) { error in
                guard case .invalid(let message)? = error as? CompanyVaultContract.Refusal else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(expected), message)
            }
        }
        XCTAssertNoThrow(try CompanyVaultContract.check(catalog()))
        var url = vault()
        url = .init(id: url.id, vaultId: url.vaultId, version: url.version, name: url.name, sizeBytes: url.sizeBytes,
                    downloadURL: "http://licence.example.test/x.zip", sha256: url.sha256, packSignature: url.packSignature)
        XCTAssertNotNil(CompanyVaultContract.problem(with: url))
        XCTAssertThrowsError(try CompanyVaultContract.checkPackFiles(["a.md": CompanyVaultContract.Limits.vaultCoreFileBytes + 1]))
        XCTAssertNoThrow(try CompanyVaultContract.checkPackFiles(["a.md": 10, "b.md": 20]))
    }

    func testTheLimitsAreDecisionTwos() {
        XCTAssertEqual(CompanyVaultContract.Limits.pdfBytes, 134_217_728)
        XCTAssertEqual(CompanyVaultContract.Limits.wordBytes, 104_857_600)
        XCTAssertEqual(CompanyVaultContract.Limits.textBytes, 20_971_520)
        XCTAssertEqual(CompanyVaultContract.Limits.vaultCoreBytes, 262_144_000)
        XCTAssertEqual(CompanyVaultContract.Limits.vaultCoreFileBytes, 20_971_520)
        XCTAssertEqual(CompanyVaultContract.Limits.companyTotalBytes, 1_073_741_824)
    }

    // MARK: - The manual seal

    func context(_ data: Data, fileName: String = "RTU Wiring.md") -> CompanyVaultContract.ManualSeal.Context {
        .init(profileId: Self.profileId, vaultId: "fixture_rtu", fileName: fileName,
              revision: CompanyVaultContract.ManualSeal.digest(data))
    }

    func testAManualSealsInChunksAndOpensOnlyInItsOwnPlace() throws {
        let seal = CompanyVaultContract.ManualSeal.self
        let plain = Data((0..<(2 * seal.chunkSize + 1_000)).map { UInt8($0 % 251) })
        let sealed = try seal.seal(plain, context: context(plain), companySecret: Self.companySecret)
        XCTAssertEqual(sealed.count, seal.sealedLength(plaintextBytes: plain.count))
        XCTAssertEqual(sealed.count, 9 + plain.count + 3 * 28)
        XCTAssertEqual(try seal.open(sealed, context: context(plain), companySecret: Self.companySecret), plain)

        let elsewhere = [
            CompanyVaultContract.ManualSeal.Context(profileId: "another", vaultId: "fixture_rtu", fileName: "RTU Wiring.md", revision: context(plain).revision),
            .init(profileId: Self.profileId, vaultId: "other_vault", fileName: "RTU Wiring.md", revision: context(plain).revision),
            .init(profileId: Self.profileId, vaultId: "fixture_rtu", fileName: "Other.md", revision: context(plain).revision),
            .init(profileId: Self.profileId, vaultId: "fixture_rtu", fileName: "RTU Wiring.md", revision: String(repeating: "0", count: 64)),
        ]
        for wrong in elsewhere {
            XCTAssertThrowsError(try seal.open(sealed, context: wrong, companySecret: Self.companySecret), "\(wrong)")
        }
        XCTAssertThrowsError(try seal.open(sealed, context: context(plain), companySecret: ProfileContract.Credential.newSecret()))

        // Cut at a chunk boundary: the new last chunk was sealed as a middle one.
        let truncated = sealed.prefix(9 + 2 * (seal.chunkSize + 28))
        XCTAssertThrowsError(try seal.open(Data(truncated), context: context(plain), companySecret: Self.companySecret))
        // Two chunks swapped.
        let first = sealed.subdata(in: 9..<(9 + seal.chunkSize + 28))
        let second = sealed.subdata(in: (9 + seal.chunkSize + 28)..<(9 + 2 * (seal.chunkSize + 28)))
        var swapped = sealed.prefix(9)
        swapped.append(second); swapped.append(first); swapped.append(sealed.suffix(from: 9 + 2 * (seal.chunkSize + 28)))
        XCTAssertThrowsError(try seal.open(Data(swapped), context: context(plain), companySecret: Self.companySecret))
        // One bit.
        var flipped = sealed
        flipped[flipped.count - 30] ^= 1
        XCTAssertThrowsError(try seal.open(flipped, context: context(plain), companySecret: Self.companySecret))
        XCTAssertThrowsError(try seal.seal(Data(), context: context(Data()), companySecret: Self.companySecret))
        XCTAssertThrowsError(try seal.seal(plain, context: context(Data("other".utf8)), companySecret: Self.companySecret),
                             "the revision is the plaintext's hash")
    }

    func testSealingAFileStreamsToTheSameFormat() throws {
        let seal = CompanyVaultContract.ManualSeal.self
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompanyVaultTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = Data((0..<(seal.chunkSize + 17)).map { UInt8($0 % 13) })
        let input = directory.appendingPathComponent("in.pdf"), output = directory.appendingPathComponent("out.sealed")
        try plain.write(to: input)
        let row = try seal.sealFile(at: input, to: output, profileId: Self.profileId, vaultId: "fixture_rtu",
                                    fileName: "Wiring.pdf", companySecret: Self.companySecret)
        let sealed = try Data(contentsOf: output)
        XCTAssertEqual(row.sizeBytes, plain.count)
        XCTAssertEqual(row.revision, seal.digest(plain))
        XCTAssertEqual(row.sealedSha256, seal.digest(sealed))
        XCTAssertEqual(sealed.count, seal.sealedLength(plaintextBytes: plain.count))
        XCTAssertEqual(try seal.open(sealed, context: context(plain, fileName: "Wiring.pdf"), companySecret: Self.companySecret), plain)
    }

    // MARK: - Golden fixtures

    func testTheGoldenFixturesOpen() throws {
        let keys = try JSONSerialization.jsonObject(with: try fixture("fixture-keys.json")) as? [String: Any]
        XCTAssertEqual(keys?["packCatalogPublicKey"] as? String, Self.publicKey)
        XCTAssertEqual(keys?["packCatalogKeyLabel"] as? String, Self.packKeyLabel)
        XCTAssertEqual(keys?["companySecretLabel"] as? String, Self.secretLabel)

        let catalog = try CompanyVaultContract.open(try fixture("catalog-v7.json"), publicKeyBase64: Self.publicKey,
                                                    profileId: Self.profileId, highWater: nil, profileGeneration: 7)
        XCTAssertEqual(catalog.generation, 7)
        XCTAssertFalse(catalog.manualsOnAnyNetwork)
        XCTAssertEqual(catalog.vaults.map(\.vaultId), ["fixture_rtu"])
        let pack = try fixture("fixture_rtu-1.0.0.zip")
        XCTAssertEqual(catalog.vaults[0].sha256, IssuanceWire.digest(pack))
        XCTAssertEqual(catalog.vaults[0].sizeBytes, pack.count)
        XCTAssertNoThrow(try CompanyVaultContract.check(catalog))

        let row = try XCTUnwrap(catalog.manuals.first)
        let sealed = try fixture("RTU Wiring.md.sealed")
        XCTAssertEqual(row.sealedSha256, IssuanceWire.digest(sealed))
        let plain = try CompanyVaultContract.ManualSeal.open(sealed, context: .init(profileId: Self.profileId, manual: row),
                                                             companySecret: Self.companySecret)
        XCTAssertEqual(plain, try fixture("RTU Wiring.md"))
        XCTAssertEqual(row.sizeBytes, plain.count)

        let renew = try fixture("seat-renew-v1.json")
        let decoded = try SeatWire.decoder().decode(SeatRenewRequest.self, from: renew)
        XCTAssertEqual(decoded.vaults, [SeatInstalledVault(vaultId: "fixture_rtu", version: "1.0.0")])
        XCTAssertEqual(try SeatWire.encoder().encode(decoded), renew.prefix(while: { $0 != 0x0A }))
    }

    /// The sealed fixture's nonces are derived from its chunk index, so it regenerates to the same
    /// bytes; the catalog's signature does not (Ed25519 here is randomised), so the committed
    /// envelope is verified rather than compared. Set `REGENERATE_COMPANY_VAULT_FIXTURES=1` to
    /// write them again.
    func testRegenerateFixtures() throws {
        guard ProcessInfo.processInfo.environment["REGENERATE_COMPANY_VAULT_FIXTURES"] == "1" else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.fixtures, withIntermediateDirectories: true)
        func write(_ data: Data, _ name: String) throws { try data.write(to: Self.fixtures.appendingPathComponent(name)) }
        func json(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) + Data("\n".utf8)
        }
        try write(json(["fixtureOnly": true,
                        "packCatalogKeyLabel": Self.packKeyLabel,
                        "packCatalogPublicKey": Self.publicKey,
                        "companySecretLabel": Self.secretLabel,
                        "derivation": "private key and company secret are SHA-256 of the UTF-8 label",
                        "profileId": Self.profileId]), "fixture-keys.json")
        try write(Data(#"{"catalog":"https://licence.example.test/c/opaque/vaults.json","generation":7,"minAppBuild":680}"#.utf8) + Data("\n".utf8),
                  "pointer-v1.json")

        // The pack: an EG pack, signed by the fixture key over pack.json and every file's digest.
        let manifest = #"{"documents":[],"files":["safety.md","fault_codes.md"],"gating":{"iap":"com.openglasses.vault.fixture_rtu"},"id":"fixture_rtu","name":"Fixture Rooftop Units","prompt_rules":["Invented fixture content. Never use it on a real unit.","Never fabricate a value.","Cite the source file for every claim."],"version":"1.0.0"}"#
        let files: [String: Data] = [
            "manifest.json": Data(manifest.utf8),
            "safety.md": Data("# Safety\n\nInvented fixture: isolate the unit before opening any panel.\n".utf8),
            "fault_codes.md": Data("# Fault codes\n\n| Code | Meaning |\n|---|---|\n| FX1 | Invented fixture fault |\n".utf8),
        ]
        let packJSON = Data(#"{"id":"com.openglasses.vault.fixture_rtu","licensePack":"fixture_rtu","name":"Fixture Rooftop Units","vaultId":"fixture_rtu","version":"1.0.0"}"#.utf8)
        var message = packJSON
        for path in files.keys.sorted() { message.append(Data("\nsha256(\(path))=\(IssuanceWire.digest(files[path]!))".utf8)) }
        let packSignature = try Self.packKey.signature(for: message).base64EncodedString()
        var entries = files
        entries["pack.json"] = packJSON
        let zip = Self.storedZip(entries)
        try write(zip, "fixture_rtu-1.0.0.zip")

        let text = Data("""
        # RTU wiring (invented fixture)

        Page 1

        This manual is invented for a test. Terminal R feeds the contactor coil through the fixture interlock.
        Never use anything here on a real unit.

        """.utf8)
        try write(text, "RTU Wiring.md")
        let revision = IssuanceWire.digest(text)
        let sealContext = CompanyVaultContract.ManualSeal.Context(profileId: Self.profileId, vaultId: "fixture_rtu",
                                                                  fileName: "RTU Wiring.md", revision: revision)
        let sealed = try CompanyVaultContract.ManualSeal.seal(text, context: sealContext, companySecret: Self.companySecret) { index in
            try AES.GCM.Nonce(data: Data(SHA256.hash(data: Data("Avenkin public fixture nonce \(index)".utf8))).prefix(12))
        }
        try write(sealed, "RTU Wiring.md.sealed")

        let catalog = CompanyVaultContract.Catalog(
            profileId: Self.profileId, generation: 7, issued: Self.issued, manualsOnAnyNetwork: false,
            vaults: [.init(id: "com.openglasses.vault.fixture_rtu", vaultId: "fixture_rtu", version: "1.0.0",
                           name: "Fixture Rooftop Units", summary: "Invented fixture vault.", minAppBuild: 680,
                           sizeBytes: zip.count, downloadURL: "https://licence.example.test/c/opaque/v/fixture_rtu-1.0.0.zip",
                           sha256: IssuanceWire.digest(zip), packSignature: packSignature)],
            manuals: [.init(vaultId: "fixture_rtu", fileName: "RTU Wiring.md", revision: revision, sizeBytes: text.count,
                            sealedSha256: IssuanceWire.digest(sealed),
                            downloadURL: "https://licence.example.test/c/opaque/m/rtu-wiring", kind: .md)])
        try write(try signed(catalog), "catalog-v7.json")

        let renew = SeatRenewRequest(build: "680", lease: "fixture.lease", vaults: [.init(vaultId: "fixture_rtu", version: "1.0.0")])
        try write(try SeatWire.encoder().encode(renew) + Data("\n".utf8), "seat-renew-v1.json")
    }

    /// A stored (uncompressed) zip, enough for the app's reader.
    static func storedZip(_ entries: [String: Data]) -> Data {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                var c = (crc ^ UInt32(byte)) & 0xFF
                for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
                crc = c ^ (crc >> 8)
            }
            return crc ^ 0xFFFFFFFF
        }
        var body = Data(), central = Data()
        for name in entries.keys.sorted() {
            let data = entries[name]!, nameBytes = Array(name.utf8), offset = UInt32(body.count), crc = crc32(data)
            body.append(contentsOf: le32(0x04034B50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                        + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0))
            body.append(contentsOf: nameBytes); body.append(data)
            central.append(contentsOf: le32(0x02014B50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                           + le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count)
                           + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset))
            central.append(contentsOf: nameBytes)
        }
        var zip = body
        let centralOffset = UInt32(zip.count)
        zip.append(central)
        zip.append(contentsOf: le32(0x06054B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
                   + le32(UInt32(central.count)) + le32(centralOffset) + le16(0))
        return zip
    }

    // MARK: - The seat renewal

    func testARenewalWithoutVaultsIsTheBytesItWas() throws {
        let bytes = String(decoding: try SeatWire.encoder().encode(SeatRenewRequest(build: "660", lease: "l")), as: UTF8.self)
        XCTAssertEqual(bytes, #"{"build":"660","lease":"l"}"#)
        let with = String(decoding: try SeatWire.encoder().encode(
            SeatRenewRequest(build: "680", lease: "l", vaults: [.init(vaultId: "fixture_rtu", version: "4")])), as: UTF8.self)
        XCTAssertEqual(with, #"{"build":"680","lease":"l","vaults":[{"vaultId":"fixture_rtu","version":"4"}]}"#)
    }

    func testTheFleetViewCountsHeldSeatsByVersion() {
        let now = Self.issued
        func seat(_ key: String, _ vaults: [SeatInstalledVault]?, freed: Bool = false) -> SeatRecord {
            SeatRecord(profileId: Self.profileId, deviceKeyHash: key, devicePublicKey: "k", enrolmentId: "e",
                       claimedAt: now, leaseNotAfter: now.addingTimeInterval(SeatWire.leaseLength), lastSeenAt: now,
                       build: "680", freedAt: freed ? now : nil, vaults: vaults)
        }
        let seats = [seat("a", [.init(vaultId: "fixture_rtu", version: "4")]),
                     seat("b", [.init(vaultId: "fixture_rtu", version: "4")]),
                     seat("c", [.init(vaultId: "fixture_rtu", version: "3"), .init(vaultId: "../bad", version: "1")]),
                     seat("d", nil),
                     seat("e", [.init(vaultId: "fixture_rtu", version: "4")], freed: true)]
        XCTAssertEqual(SeatPolicy.fleetVersions(seats, profileId: Self.profileId, now: now), ["fixture_rtu": ["4": 2, "3": 1]])
    }

    func testARenewalKeepsWhatThePhoneReported() throws {
        let now = Self.issued
        let licence = SeatLicence(licenseIDHash: "l", seats: 2, seatCheck: true, expires: nil)
        let seat = SeatRecord(profileId: Self.profileId, deviceKeyHash: "a", devicePublicKey: "k", enrolmentId: "e",
                              claimedAt: now, leaseNotAfter: now.addingTimeInterval(SeatWire.leaseLength), lastSeenAt: now, build: "670")
        let lease = SeatLeasePayload(deviceKeyHash: "a", enrolmentId: "e", issued: now, licenseIDHash: "l",
                                     notAfter: now.addingTimeInterval(SeatWire.leaseLength))
        let reported = Array(repeating: SeatInstalledVault(vaultId: "fixture_rtu", version: "4"), count: 20)
        guard case .grant(let renewed, _) = SeatPolicy.renew(lease, build: "680", profileId: Self.profileId, licence: licence,
                                                              seats: [seat], now: now, vaults: reported) else { return XCTFail() }
        XCTAssertEqual(renewed.vaults?.count, SeatInstalledVault.maximumPerRenewal)
        guard case .grant(let unchanged, _) = SeatPolicy.renew(lease, build: "680", profileId: Self.profileId, licence: licence,
                                                               seats: [seat], now: now) else { return XCTFail() }
        XCTAssertNil(unchanged.vaults)
    }
}
