import XCTest
import CryptoKit
@testable import OpenGlasses

/// Plan BX P2 — signed catalog parsing, the zip → install pipeline over fixture bytes, hardware
/// gating, and settings-as-schema substitution.
@MainActor
final class SkillPackCatalogTests: XCTestCase {

    /// A real zip built with `zip -X`: `skillpack.json` (Barista Coach, one prompt action using
    /// `{{setting.roast_level}}`, one select setting) + `prompts/persona.md`. Exercises the actual
    /// `ZipArchiveReader`, not a stand-in.
    private static let fixtureZipBase64 = """
        UEsDBBQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAc2tpbGxwYWNrLmpzb25NkM1OwzAQhO88xcrnEgHH3ADxAkicUBVt7FVj\
        6j95Ny1VlHdn3VCpN3vn88x6FuOd6Y3NsaNfjCVQN2L1LGh25kSVfU6qP3cv3ZNOEkbS69uGwHtGO+mY5xixXlT54FKJOYPz\
        GB59gsPsHSZLSqEVdWPTfy83o0YNPg08ZVHCEdvqi2yhX0xwniiBTAQzU4UzJmGYKJSrv08H0Aj6z+zUoWBVZ9HFTb8YuZSW\
        kscfss2/1Fyoiqer2kIH8ZGGezjNcaRq1nXdmdEnpyFNPepRVXWIpVkJaVko7cWrO3ldNSdAWJY713UFJpuTgzYElCaTiFp2\
        NSPLEOhEQbHrrdPQvZa5EVtPR2qt3sEteluUKWy/CjjqvDefjYIblcutbRP8YWpgJOfn2HrGejT7db8+/AFQSwMECgAAAAAA\
        967/XAAAAAAAAAAAAAAAAAgAAABwcm9tcHRzL1BLAwQKAAAAAAD3rv9ccHp5iBgAAAAYAAAAEgAAAHByb21wdHMvcGVyc29u\
        YS5tZFlvdSBhcmUgYSBiYXJpc3RhIGNvYWNoLlBLAQIeAxQAAAAIAPeu/1yV9I+SMgEAAAACAAAOAAAAAAAAAAEAAACkgQAA\
        AABza2lsbHBhY2suanNvblBLAQIeAwoAAAAAAPeu/1wAAAAAAAAAAAAAAAAIAAAAAAAAAAAAEADtQV4BAABwcm9tcHRzL1BL\
        AQIeAwoAAAAAAPeu/1xwenmIGAAAABgAAAASAAAAAAAAAAEAAACkgYQBAABwcm9tcHRzL3BlcnNvbmEubWRQSwUGAAAAAAMA\
        AwCyAAAAzAEAAAAA
        """

    private var fixtureZip: Data { Data(base64Encoded: Self.fixtureZipBase64)! }

    /// Byte-for-byte copy of the committed `skillpacks/catalog.json`.
    static let committedCatalog = #"{"payload":"eyJ2ZXJzaW9uIjoxLCJwYWNrcyI6W3siaWQiOiJjb20ub3BlbmdsYXNzZXMuYmFyaXN0YSIsInZlcnNpb24iOiIxLjAuMCIsIm5hbWUiOiJCYXJpc3RhIENvYWNoIiwic3VtbWFyeSI6IkVzcHJlc3NvIGRpYWwtaW4gZ3VpZGFuY2UgdGhyb3VnaCB0aGUgZ2xhc3NlcyIsInNpemVCeXRlcyI6MTIzOCwiaGFyZHdhcmUiOlt7InR5cGUiOiJjYW1lcmEiLCJsZXZlbCI6Im9wdGlvbmFsIn1dLCJkb3dubG9hZFVSTCI6Imh0dHBzOi8vc3RyYWZmMjAwMi5naXRodWIuaW8vT3BlbkdsYXNzZXMvc2tpbGxwYWNrcy9wYWNrcy9jb20ub3BlbmdsYXNzZXMuYmFyaXN0YS0xLjAuMC56aXAiLCJzaGEyNTYiOiIwMGRkMDdkZWZiZGI5MzEyYmQ2ZmIxOGMyNzc2ZGQ3Nzk5NDI5ODM3ZDkzNDIzY2E0N2I5NGJmNDFhMThmYmMzIiwicGFja1NpZ25hdHVyZSI6InVzYk1ObUcrVmtzNUpkWVlqeEdtSTdDTDdMOUNkMTZHVFBENnNmUDRMdjg3bVZiNUVSU29aZml0dkdSVnpxUzQwb1k1c1VDbHJkRzQ0RE9abGhZVUNBPT0ifSx7ImlkIjoiY29tLm9wZW5nbGFzc2VzLmZvY3VzIiwidmVyc2lvbiI6IjEuMC4wIiwibmFtZSI6IkZvY3VzIFNlc3Npb25zIiwic3VtbWFyeSI6IlBvbW9kb3JvLXN0eWxlIGZvY3VzIHRpbWVycyBieSB2b2ljZSIsInNpemVCeXRlcyI6NTkzLCJoYXJkd2FyZSI6W10sImRvd25sb2FkVVJMIjoiaHR0cHM6Ly9zdHJhZmYyMDAyLmdpdGh1Yi5pby9PcGVuR2xhc3Nlcy9za2lsbHBhY2tzL3BhY2tzL2NvbS5vcGVuZ2xhc3Nlcy5mb2N1cy0xLjAuMC56aXAiLCJzaGEyNTYiOiJlNDU0MGI4ZGU2ZGUzOTdkZTEzZjk3OTlmZTNhNzQ3YmFjY2ZjNjJlY2E1YzBjMDc4MjA2NWZhYzlmMDVmZTM2IiwicGFja1NpZ25hdHVyZSI6Imt0ZC84RzV4NVM3c0ljOWV6WS8zdVdKQ1JmTDl2Uzh5TENtYmxUY1IyS2hWVDExNGl3T1F1V0JZdUpwWlpNaW1vVHF2Ni90NHRwcmxNM3hPVnI3TUJBPT0ifV19Cg==","signature":"mwt3yfUILyxAvbweZWWjda9cP\/T9X5nDYVQIAXEvk09Q8UmTXOtil00sMJTCRj7hI4mzq8CQNDWktlz0BkahCA=="}"#

    /// The committed, published pack zips (`skillpacks/packs/…`), embedded so tests prove the
    /// real artifacts install — not stand-ins.
    private var baristaZip: Data { Data(base64Encoded: Self.baristaZipBase64)! }
    private var focusZip: Data { Data(base64Encoded: Self.focusZipBase64)! }

    private static let baristaZipBase64 = """
        UEsDBAoAAAAAADxVAV0AAAAAAAAAAAAAAAAIAAAAcHJvbXB0cy9QSwMEFAAAAAgAPFUBXUcaG2ldAAAAbwAAABAAAABwcm9tcHRz\
        L25vdGVzLm1kTc27DcMwDAXAVV7vzwAB3GaAbKCYNEBAEWHyKbG3N9ylvuKeplXQnJoPpPcYtpJcehONSQ9GWaky4m2kxpDVf4t/\
        /23Gq9Acq/fGxBb+gcQJ8VTQUW3vJjjvaL4AUEsDBBQAAAAIADxVAV2bNNLRMwMAAIIHAAAOAAAAc2tpbGxwYWNrLmpzb261VcGO\
        3DYMve9XEL4kBRxjN0WAYHso0CZIckmBNDktFgONxbGVsSVHlNedDAzkI/KF/ZKStD3r2bZACjSXGYkSycfHR+t4AZA5m11DVoa2\
        CB36qjFESMXWREfJZLlcucNILni5d1VcFpeT1ZsWxfTLdBV+DaaspyPq29bEg5y+pC4iUQDrTPPEeah6Z40vEVIdQ1/V/I8wp528\
        axPtYKIEvzlm6dBpmpLTRQYEWYN32IgpdIlhmSYbb9XRlLIn8eMtwFF/V1AFw8b5DdUhaS49tUhldBpLLn0ghKFGr8B6wgiD8Ymg\
        xqbTKpyvgAvBpbI/v3wFiQjRsFMIsDOUIESgJgw5JN4hAYU+inHrUsKYy5ITHKBFL5mhis5bIPcZc7CBUG8cHDa2uIfamcilsL8U\
        uZTH9oWksP2I5X1p4hG5rTE5PPeQJjHkTXItbvToFMP37RajEP2AmNdhgCZw8ULMUnAuVBCWwVvKxnydQAs/C02Ji6z+JbRLE1X2\
        WrnKT0xtTSOCsTkMaPbZeMqxrE5psy1zKBnOyNmzUZIwFW13Rk7CtmuMgszeL9129I9d5hYZOB4JU+KjIgbGulEpjiPoroDfhRSh\
        9Fpu3vM7jjTrQA50MY4FvDexwgRPnz358ZJgx/02cHX9lGllXjjarBiVU4vG0yySnfOoJ6IT6DsWmqvq1Bx+mjlbxHfmVQYTaeVn\
        w+ALeOXuEH57+xKow9LtXAnGfuwpiSxZzJDiATz+kXKVphVTzYF3hgPtdpOEeVZzWbEQUuiK7GLdnrk5f5vFbcRho5X+h0k0tCc2\
        mTRNhtSiIRTpxKbSuOrbNEtYVAU8eqM7C1fPmRPTclM0Fneq52BvoOub5udH32fcJPOm+rZJe8Gkl0wv4tQq+WwK3rX2V0kjfupd\
        RBH5zZLn9v+cjRcKgli7U/RxrL5pHt7xd6FlJVm+Ordn6ttS0EPRw2NeFs/AqbKmMJJY9f0DazAxIj2auAOG6HxzyLnl9vQplfN5\
        qAauLwwPJcm/04sxo189Gdke9d1a1SMNOn3BsNGO8ytkttMr9E5Bnm5Oj5JGzBS2GFu0rm+10ybus1tFcDFe/AVQSwECHgMKAAAA\
        AAA8VQFdAAAAAAAAAAAAAAAACAAAAAAAAAAAABAA7UEAAAAAcHJvbXB0cy9QSwECHgMUAAAACAA8VQFdRxobaV0AAABvAAAAEAAA\
        AAAAAAABAAAApIEmAAAAcHJvbXB0cy9ub3Rlcy5tZFBLAQIeAxQAAAAIADxVAV2bNNLRMwMAAIIHAAAOAAAAAAAAAAEAAACkgbEA\
        AABza2lsbHBhY2suanNvblBLBQYAAAAAAwADALAAAAAQBAAAAAA=
        """

    private static let focusZipBase64 = """
        UEsDBBQAAAAIAFpVAV2SlW9z0wEAAG8EAAAOAAAAc2tpbGxwYWNrLmpzb261VLFu2zAQ3f0VBy1aXEJpkSVbUaBzgaJTYBiUdJYY\
        S6TKOzkwAgP9iH5hv6Q8UqYdBxk6dJHE47vHx8dHvawACtMWD1A0blRuQtsNmghJ7VwzU7EWwAE9GWcFdacqVaWq1SNK6asA4TuS\
        YJYOmsdR+6NMf3Oja513H4iPA0KkBTZj4IT6CAdnGkxNuuHI8ACPYQjwEp9XKxFrz9vIsKW0XuyMoBap8WbiRegPQnju0QL3CDOh\
        h2dtmUAvCpyHaVEGC9caUHUKys4cEEbM0Hpwzb6UjjIqCBMf72E0dmbMJKWCL84Gp1hWNB48/pyRwkj4G2dbUhexk/ZhTxw8CFrP\
        +wx1Pk5xp65+woYzXjp8OBzPBl93iNeJXcq531jGDn2xfuPLck4whJPmHow9q4M/v34nA/LmCAzB3X1VKRA75QvM7uJo65BsyUD6\
        qIpT1nS6ki0uGI+SsMesdLO6ARa1sa2x3Wsz9qEoktm54dqKHAfkbQzS9WTtZtt+9l3yY9A1DoJNJ3kOzVlrei8y3olb7VHv/yFm\
        O2MN9XhJ2rIoaNvmDFLvQlAidboL72bjTSRuo3D6/y5eElZ8qiqRkH1N7tz4GZ6b9BtA5iAoXunN6rT6C1BLAQIeAxQAAAAIAFpV\
        AV2SlW9z0wEAAG8EAAAOAAAAAAAAAAEAAACkgQAAAABza2lsbHBhY2suanNvblBLBQYAAAAAAQABADwAAAD/AQAAAAA=
        """


    private func makeStore(
        publicKey: String = SkillPackSignature.productionPublicKeyBase64,
        nativeNames: Set<String> = []
    ) -> SkillPackStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("skillpack-cat-tests-\(UUID().uuidString)", isDirectory: true)
        return SkillPackStore(directory: dir, currentBuild: 330,
                              nativeToolNames: { nativeNames }, publicKeyBase64: publicKey)
    }

    // MARK: - Archive extraction (real zip, real reader)

    func testFixtureZipExtracts() throws {
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: fixtureZip) else {
            return XCTFail("fixture must extract")
        }
        let (manifest, report) = SkillPackManifest.lossyDecode(manifestData)
        XCTAssertEqual(manifest?.id, "com.example.barista")
        XCTAssertTrue(report.isClean)
        XCTAssertEqual(files["prompts/persona.md"], Data("You are a barista coach.".utf8))
        XCTAssertNil(files["skillpack.json"], "the manifest is not a payload file")
        XCTAssertNil(files["prompts/"], "directory entries are skipped")
    }

    func testGarbageAndManifestlessArchivesAreTypedFailures() {
        XCTAssertEqual(SkillPackArchive.extract(zipData: Data("not a zip".utf8)).failureError, .notAZip)
        // An empty-but-valid zip: EOCD only.
        var eocd = Data(count: 22)
        eocd.replaceSubrange(0..<4, with: [0x50, 0x4B, 0x05, 0x06])
        XCTAssertEqual(SkillPackArchive.extract(zipData: eocd).failureError, .missingManifest)
    }

    func testArchiveSizeLimitRunsBeforeZipParsing() {
        let oversized = Data(count: SkillPackArchive.maxArchiveBytes + 1)
        XCTAssertEqual(SkillPackArchive.extract(zipData: oversized).failureError, .archiveTooLarge)
    }

    func testDeclaredOversizeIsRefusedBeforeInflation() throws {
        var archive = fixtureZip
        let central = try firstCentralDirectoryOffset(in: archive)
        writeUInt32(UInt32(SkillPackArchive.maxEntryBytes + 1), to: &archive, at: central + 24)
        let local = Int(readUInt32(from: archive, at: central + 42))
        writeUInt32(UInt32(SkillPackArchive.maxEntryBytes + 1), to: &archive, at: local + 22)
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .entryTooLarge)
    }

    func testTraversalPathRefusesWholeArchive() throws {
        var archive = fixtureZip
        let central = try centralDirectoryOffset(named: "prompts/persona.md", in: archive)
        let replacement = Data("../evil/persona.md".utf8)
        XCTAssertEqual(replacement.count, "prompts/persona.md".utf8.count)
        archive.replaceSubrange((central + 46)..<(central + 46 + replacement.count), with: replacement)
        let local = Int(readUInt32(from: archive, at: central + 42))
        archive.replaceSubrange((local + 30)..<(local + 30 + replacement.count), with: replacement)
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .unsafeEntryPath)
    }

    func testCentralAndLocalNamesMustMatch() throws {
        var archive = fixtureZip
        let central = try firstCentralDirectoryOffset(in: archive)
        let local = Int(readUInt32(from: archive, at: central + 42))
        archive[local + 30] ^= 0x01
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .notAZip)
    }

    func testCentralDirectoryMustEndExactlyAtEOCD() throws {
        var archive = fixtureZip
        let eocd = try XCTUnwrap(archive.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards)?.lowerBound)
        let declaredSize = readUInt32(from: archive, at: eocd + 12)
        writeUInt32(declaredSize - 1, to: &archive, at: eocd + 12)
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .notAZip)
    }

    func testOverlappingPhysicalEntryRangesAreRejected() throws {
        var archive = fixtureZip
        let central = try firstCentralDirectoryOffset(in: archive)
        let local = Int(readUInt32(from: archive, at: central + 42))
        let compressedSize = readUInt32(from: archive, at: central + 20)
        writeUInt32(compressedSize + 4, to: &archive, at: central + 20)
        writeUInt32(compressedSize + 4, to: &archive, at: local + 18)
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .notAZip)
    }

    func testUnixSpecialFilesAndTypeMasqueradingAreRejected() throws {
        for mode: UInt32 in [0x1000, 0x2000, 0x6000, 0xA000, 0xC000] {
            var archive = fixtureZip
            let central = try firstCentralDirectoryOffset(in: archive)
            writeUInt32(mode << 16, to: &archive, at: central + 38)
            XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .unsupportedEntry)
        }

        var directoryAsFile = fixtureZip
        let directory = try centralDirectoryOffset(named: "prompts/", in: directoryAsFile)
        writeUInt32(0x8000 << 16, to: &directoryAsFile, at: directory + 38)
        XCTAssertEqual(SkillPackArchive.extract(zipData: directoryAsFile).failureError, .unsupportedEntry)
    }

    func testCRCMismatchRefusesWholeArchive() throws {
        var archive = fixtureZip
        let payload = Data("You are a barista coach.".utf8)
        let range = try XCTUnwrap(archive.range(of: payload))
        archive[range.lowerBound] ^= 0x01
        XCTAssertEqual(SkillPackArchive.extract(zipData: archive).failureError, .corruptEntry)
    }

    func testSha256HexMatchesKnownVector() {
        XCTAssertEqual(SkillPackArchive.sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func firstCentralDirectoryOffset(in data: Data) throws -> Int {
        try XCTUnwrap(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))?.lowerBound)
    }

    private func centralDirectoryOffset(named name: String, in data: Data) throws -> Int {
        var offset = try firstCentralDirectoryOffset(in: data)
        while offset + 46 <= data.count {
            guard readUInt32(from: data, at: offset) == 0x0201_4B50 else { break }
            let nameLength = Int(readUInt16(from: data, at: offset + 28))
            let extraLength = Int(readUInt16(from: data, at: offset + 30))
            let commentLength = Int(readUInt16(from: data, at: offset + 32))
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            if String(data: nameData, encoding: .utf8) == name { return offset }
            offset += 46 + nameLength + extraLength + commentLength
        }
        throw NSError(domain: "SkillPackCatalogTests", code: 1)
    }

    private func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(readUInt16(from: data, at: offset)) |
            (UInt32(readUInt16(from: data, at: offset + 2)) << 16)
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    // MARK: - Catalog envelope

    private func makeSignedCatalog(entries: [SkillPackCatalogEntry]) throws -> (envelope: Data, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try SkillPackCatalog.makeEnvelope(
            index: .init(version: 1, packs: entries),
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        return (envelope, key.publicKey.rawRepresentation.base64EncodedString())
    }

    private func entry(sha256: String = "", packSignature: String = "") -> SkillPackCatalogEntry {
        SkillPackCatalogEntry(
            id: "com.example.barista", version: "1.2.0", name: "Barista Coach",
            summary: "Espresso dial-in guidance",
            hardware: [.init(type: .camera, level: .optional)],
            downloadURL: "https://packs.example/barista.zip",
            sha256: sha256, packSignature: packSignature)
    }

    func testCatalogRoundTripsThroughSignedEnvelope() throws {
        let (envelope, publicKey) = try makeSignedCatalog(entries: [entry(sha256: "aa")])
        guard case .success(let parsed) = SkillPackCatalog.parse(envelopeData: envelope,
                                                                publicKeyBase64: publicKey) else {
            return XCTFail("valid envelope must parse")
        }
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "com.example.barista")
    }

    func testCatalogRefusesTamperAndForeignKeys() throws {
        let (envelope, publicKey) = try makeSignedCatalog(entries: [entry()])

        // Foreign key.
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: envelope, publicKeyBase64: otherKey).failureError,
                       .badSignature)

        // Payload tampered inside a re-built envelope: flip one byte of the payload.
        var dict = try JSONSerialization.jsonObject(with: envelope) as! [String: Any]
        var payload = Data(base64Encoded: dict["payload"] as! String)!
        payload[payload.count / 2] ^= 0xFF
        dict["payload"] = payload.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: tampered, publicKeyBase64: publicKey).failureError,
                       .badSignature)

        // Not an envelope at all.
        XCTAssertEqual(SkillPackCatalog.parse(envelopeData: Data("[]".utf8), publicKeyBase64: publicKey).failureError,
                       .notAnEnvelope)
    }

    func testCatalogRefusesNewerIndexVersionExplicitly() throws {
        let key = Curve25519.Signing.PrivateKey()
        let envelope = try SkillPackCatalog.makeEnvelope(
            index: .init(version: 99, packs: []),
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        XCTAssertEqual(
            SkillPackCatalog.parse(envelopeData: envelope,
                                   publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()).failureError,
            .unsupportedVersion(99),
            "a newer index is 'update the app', never a partial parse")
    }

    /// The envelope actually committed at `skillpacks/catalog.json` must verify against the
    /// embedded production key. Byte-for-byte copy here: if either the published catalog or
    /// `productionPublicKeyBase64` changes without the other, this fails — the drift this test
    /// exists to catch. Update both together (sign with `Scripts/skillpack-sign.swift`).
    func testCommittedCatalogVerifiesAgainstProductionKey() throws {
        guard case .success(let packs) = SkillPackCatalog.parse(envelopeData: Data(Self.committedCatalog.utf8)) else {
            return XCTFail("the committed catalog must verify against the embedded production key")
        }
        XCTAssertEqual(packs.map(\.id), ["com.openglasses.barista", "com.openglasses.focus"])
        // Every entry's checksum must match the committed zip it points at.
        XCTAssertEqual(packs[0].sha256, SkillPackArchive.sha256Hex(baristaZip))
        XCTAssertEqual(packs[1].sha256, SkillPackArchive.sha256Hex(focusZip))
    }

    /// The PUBLISHED artifacts install: committed zip bytes → extract → validate → signed install
    /// against the production key, with the catalog-carried pack signatures. If this passes, what
    /// is on Pages is what a device can actually install.
    func testPublishedPacksInstallEndToEnd() async throws {
        guard case .success(let entries) = SkillPackCatalog.parse(envelopeData: Data(Self.committedCatalog.utf8)) else {
            return XCTFail()
        }
        let zips = ["com.openglasses.barista": baristaZip, "com.openglasses.focus": focusZip]
        // Production public key — the real trust path — and the native tool the focus pack binds
        // to, as the registry would supply it on device.
        let store = makeStore(nativeNames: ["set_timer"])
        let service = SkillPackCatalogService(
            store: store,
            catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { url in
                guard let zip = zips.first(where: { url.absoluteString.contains($0.key) })?.value else {
                    throw URLError(.fileDoesNotExist)
                }
                return zip
            })
        for entry in entries {
            await service.install(entry)
            guard case .installed(let warnings)? = service.installStates[entry.id] else {
                return XCTFail("published pack \(entry.id) failed to install: \(String(describing: service.installStates[entry.id]))")
            }
            XCTAssertTrue(warnings.isEmpty, "\(entry.id) must install clean, got \(warnings)")
        }
        XCTAssertEqual(store.installedPacks.count, 2)
        XCTAssertTrue(store.installedPacks.allSatisfy(\.signatureVerified))

        // And the focus pack's tool binding actually reaches a native tool with typed args.
        let registry = NativeToolRegistry(locationService: LocationService())
        struct CapturingTimer: NativeTool {
            let name = "set_timer"
            let description = "test"
            var parametersSchema: [String: Any] { ["type": "object"] }
            let onArgs: ([String: Any]) -> Void
            func execute(args: [String: Any]) async throws -> String { onArgs(args); return "ok" }
        }
        nonisolated(unsafe) var captured: [String: Any] = [:]
        registry.register(CapturingTimer(onArgs: { captured = $0 }))
        // A composed binding runs only through the execution authority, so the merge needs one.
        let router = NativeToolRouter(registry: registry)
        registry.registerSkillPackTools(from: store, authority: router)
        let breakTool = try XCTUnwrap(registry.tool(named: "pack_com_openglasses_focus_start_break"))
        _ = try await breakTool.execute(args: [:])
        XCTAssertEqual(captured["seconds"] as? Int, 300,
                       "bound arg \"300\" must coerce to a typed Int for the native tool")
        XCTAssertEqual(captured["label"] as? String, "break")
    }

    // MARK: - Hardware gate

    func testHardwareGateTable() {
        typealias Req = SkillPackManifest.HardwareRequirement
        let camReq = Req(type: .camera, level: .required)
        let camOpt = Req(type: .camera, level: .optional)
        let dispReq = Req(type: .display, level: .required)

        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [], hasCamera: false, hasDisplay: false),
                       .ready, "no requirements — always ready")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camOpt], hasCamera: false, hasDisplay: false),
                       .degraded(missing: ["camera"]), "optional missing = shown, not hidden")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq], hasCamera: false, hasDisplay: false),
                       .blocked(missing: ["camera"]))
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq, dispReq], hasCamera: true, hasDisplay: false),
                       .blocked(missing: ["display"]), "required beats optional in the verdict")
        XCTAssertEqual(SkillPackHardwareGate.availability(requirements: [camReq, dispReq], hasCamera: true, hasDisplay: true),
                       .ready)
    }

    // MARK: - Install pipeline (injected fetch, end to end)

    func testPipelineInstallsFixtureEndToEnd() async throws {
        // Sign the fixture's manifest + payload with an ephemeral key, catalog carries the pack
        // signature and the zip hash — the full P2 path with zero network.
        guard case .success(let (manifestData, files)) = SkillPackArchive.extract(zipData: fixtureZip) else {
            return XCTFail()
        }
        let key = Curve25519.Signing.PrivateKey()
        let packSignature = try SkillPackSignature.sign(
            manifestData: manifestData, payloadFiles: files,
            privateKeyBase64: key.rawRepresentation.base64EncodedString())
        let store = makeStore(publicKey: key.publicKey.rawRepresentation.base64EncodedString())

        var installedFired = false
        let zip = fixtureZip
        let service = SkillPackCatalogService(
            store: store,
            catalogURL: { URL(string: "https://example.test/catalog.json") },
            fetch: { _ in zip },
            onInstalled: { installedFired = true })

        await service.install(entry(sha256: SkillPackArchive.sha256Hex(zip),
                                    packSignature: packSignature))

        guard case .installed(let warnings)? = service.installStates["com.example.barista"] else {
            return XCTFail("pipeline must install, got \(String(describing: service.installStates["com.example.barista"]))")
        }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertTrue(installedFired, "the registry re-merge hook must fire")
        XCTAssertEqual(store.installedPacks.first?.signatureVerified, true)
        // Payload file landed on disk under the pack's version directory.
        XCTAssertEqual(store.activeManifests().first?.settings.first?.key, "roast_level")
    }

    func testPipelineRefusesChecksumMismatchBeforeExtraction() async {
        let store = makeStore()
        let zip = fixtureZip
        let service = SkillPackCatalogService(
            store: store, catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in zip })

        await service.install(entry(sha256: String(repeating: "0", count: 64), packSignature: ""))

        guard case .failed(let reason)? = service.installStates["com.example.barista"] else {
            return XCTFail("hash mismatch must fail")
        }
        XCTAssertTrue(reason.contains("checksum"))
        XCTAssertTrue(store.installedPacks.isEmpty, "nothing partial reaches the store")
    }

    func testPipelineSurfacesDownloadFailure() async {
        struct Offline: Error {}
        let store = makeStore()
        let service = SkillPackCatalogService(
            store: store, catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in throw Offline() })

        await service.install(entry(sha256: "aa", packSignature: ""))
        guard case .failed(let reason)? = service.installStates["com.example.barista"] else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("download failed"))
    }

    func testCatalogLoadRefusesBadSignatureLoudly() async throws {
        // Catalog signed by a key that is NOT the store's — the fleet-attack case. Developer mode
        // must not loosen this.
        Config.setSkillPackDevModeEnabled(true)
        defer { UserDefaults.standard.removeObject(forKey: "skillPackDevModeEnabled") }

        let (envelope, _) = try makeSignedCatalog(entries: [entry()])
        let service = SkillPackCatalogService(
            store: makeStore(), catalogURL: { URL(string: "https://example.test/c.json") },
            fetch: { _ in envelope })   // parse uses the production placeholder key → mismatch

        await service.loadCatalog()
        guard case .failed(let reason) = service.catalogState else {
            return XCTFail("foreign-signed catalog must refuse")
        }
        XCTAssertTrue(reason.contains("signature"))
    }

    // MARK: - Settings-as-schema

    func testSettingSubstitutionReachesBindings() {
        SkillPackSettings.setValue("dark", packId: "com.example.barista", key: "roast_level")
        defer { SkillPackSettings.setValue(nil, packId: "com.example.barista", key: "roast_level") }

        let out = SkillPackToolWrapper.substitute(
            template: "Advise at {{setting.roast_level}} roast for {{shot_time_s}}s.",
            args: ["shot_time_s": 18],
            settings: ["roast_level": "dark"])
        XCTAssertEqual(out, "Advise at dark roast for 18s.")
    }

    func testSettingsValuesReadOnlyDeclaredKeys() {
        let packId = "com.example.pack"
        SkillPackSettings.setValue("yes", packId: packId, key: "declared")
        UserDefaults.standard.set("sneaky", forKey: "skillpack.\(packId).undeclared")
        defer {
            SkillPackSettings.setValue(nil, packId: packId, key: "declared")
            UserDefaults.standard.removeObject(forKey: "skillpack.\(packId).undeclared")
        }
        let values = SkillPackSettings.values(
            packId: packId,
            declarations: [.init(key: "declared", type: "text", label: nil, options: nil)])
        XCTAssertEqual(values, ["declared": "yes"],
                       "only declared keys flow into substitution — the schema is the contract")
    }
}

private extension Result {
    var failureError: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
