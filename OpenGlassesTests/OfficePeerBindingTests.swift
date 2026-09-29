import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// A phone must never accept an office key merely because a QR code or a transport peer supplied it.
@MainActor
final class OfficePeerBindingTests: XCTestCase {
    private let now: Int64 = 1_800_000_000
    private let vendor = Curve25519.Signing.PrivateKey()
    private let administrator = Curve25519.Signing.PrivateKey()
    private let officeKey = Curve25519.Signing.PrivateKey()
    private let phoneKey = Curve25519.Signing.PrivateKey()

    private var vendorKeys: [String: String] {
        ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()]
    }

    private func profile(schema: Int = 2, includeAuthority: Bool = true,
                         authority: ConfigProfile.OfficeAuthority? = nil,
                         expiry: Date? = nil) -> ConfigProfile {
        ConfigProfile(keyId: "vendor-test", profileId: "northbridge-field",
                      organizationName: "Northbridge", issued: Date(timeIntervalSince1970: 1_790_000_000),
                      policyExpiry: expiry, leaseDays: 30,
                      officeAuthority: includeAuthority ? (authority ?? .init(
                        organizationID: "northbridge",
                        administratorPublicKey: administrator.publicKey.rawRepresentation.base64EncodedString(),
                        transportPolicy: "privateLan")) : nil, schemaVersion: schema)
    }

    private func root(_ profile: ConfigProfile? = nil) throws -> OfficePeerBinding.VendorRoot {
        let document = try ProfileVerification.makeDocument(
            profile ?? self.profile(), privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        return try OfficePeerBinding.vendorRoot(profileDocument: document, vendorKeys: vendorKeys,
                                                now: Date(timeIntervalSince1970: TimeInterval(now)))
    }

    private func expected(minimumGeneration: Int64 = 1) -> OfficePeerBinding.ExpectedPeer {
        .init(enrolmentID: "phone-1", officeID: "office-1", officeTransportID: "transport-office-1",
              officeApplicationKey: officeKey.publicKey.rawRepresentation,
              phoneTransportID: "transport-phone-1",
              phoneApplicationKey: phoneKey.publicKey.rawRepresentation,
              minimumGeneration: minimumGeneration)
    }

    private func payload() -> OfficePeerBinding.Payload {
        .init(version: 1, kind: "avenkin.office-peer-binding", organizationID: "northbridge",
              profileID: "northbridge-field", enrolmentID: "phone-1", officeID: "office-1",
              generation: 4, officeTransportID: "transport-office-1",
              officeApplicationKey: officeKey.publicKey.rawRepresentation.base64EncodedString(),
              phoneTransportID: "transport-phone-1",
              phoneApplicationKey: phoneKey.publicKey.rawRepresentation.base64EncodedString(),
              issuedAt: now - 60, expiresAt: now + 3_600)
    }

    private func envelope(_ payload: OfficePeerBinding.Payload,
                          signer: Curve25519.Signing.PrivateKey? = nil,
                          domain: Data = OfficePeerBinding.domain) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try envelope(encoder.encode(payload), signer: signer, domain: domain)
    }

    private func envelope(_ bytes: Data, signer: Curve25519.Signing.PrivateKey? = nil,
                          domain: Data = OfficePeerBinding.domain) throws -> Data {
        let signature = try (signer ?? administrator).signature(for: domain + bytes)
        return try JSONEncoder().encode(OfficePeerBinding.Envelope(
            payload: bytes.base64EncodedString(), signature: signature.base64EncodedString()))
    }

    private func refusal(_ payload: OfficePeerBinding.Payload, expected refusal: OfficePeerBinding.Refusal,
                         peer: OfficePeerBinding.ExpectedPeer? = nil) throws {
        let data = try envelope(payload)
        XCTAssertThrowsError(try OfficePeerBinding.verify(data, root: root(), expected: peer ?? expected(), now: now)) {
            XCTAssertEqual($0 as? OfficePeerBinding.Refusal, refusal)
        }
    }

    func testVerifiedBindingUsesVendorAdministratorAndExactDeviceIdentities() throws {
        let data = try envelope(payload())
        let verified = try OfficePeerBinding.verify(data, root: root(), expected: expected(), now: now)
        XCTAssertEqual(verified.payload.generation, 4)
        XCTAssertEqual(verified.payloadSHA256.count, 64)
        XCTAssertEqual(verified.payload.officeApplicationKey, officeKey.publicKey.rawRepresentation.base64EncodedString())
    }

    func testUntrustedOrExpiredVendorProfileCannotCreateRoot() throws {
        let document = try ProfileVerification.makeDocument(
            profile(), privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        XCTAssertThrowsError(try OfficePeerBinding.vendorRoot(
            profileDocument: document, vendorKeys: ["vendor-test": Curve25519.Signing.PrivateKey()
                .publicKey.rawRepresentation.base64EncodedString()], now: Date(timeIntervalSince1970: TimeInterval(now)))) {
            XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .untrustedProfile)
        }
        XCTAssertThrowsError(try root(profile(schema: 1, includeAuthority: false))) {
            XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .untrustedProfile)
        }
        XCTAssertThrowsError(try root(profile(expiry: Date(timeIntervalSince1970: TimeInterval(now))))) {
            XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .profileExpired)
        }
    }

    func testAdministratorSignatureAndDomainAreIndependentOfTransportAndVendor() throws {
        for data in [try envelope(payload(), signer: officeKey),
                     try envelope(payload(), signer: vendor),
                     try envelope(payload(), domain: Data("another-purpose\0".utf8))] {
            XCTAssertThrowsError(try OfficePeerBinding.verify(data, root: root(), expected: expected(), now: now)) {
                XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .badSignature)
            }
        }
        var data = try envelope(payload())
        data[data.count - 5] ^= 1
        XCTAssertThrowsError(try OfficePeerBinding.verify(data, root: root(), expected: expected(), now: now))
    }

    func testForeignOrganizationAndProfileAreRefused() throws {
        var p = payload()
        p = .init(version: p.version, kind: p.kind, organizationID: "another-firm", profileID: p.profileID,
                  enrolmentID: p.enrolmentID, officeID: p.officeID, generation: p.generation,
                  officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
                  phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
                  issuedAt: p.issuedAt, expiresAt: p.expiresAt)
        try refusal(p, expected: .wrongOrganizationOrProfile)
    }

    func testWrongPhoneOfficeAndTransportAreRefused() throws {
        var peer = expected()
        peer = .init(enrolmentID: "another-phone", officeID: peer.officeID,
                     officeTransportID: peer.officeTransportID, officeApplicationKey: peer.officeApplicationKey,
                     phoneTransportID: peer.phoneTransportID, phoneApplicationKey: peer.phoneApplicationKey,
                     minimumGeneration: peer.minimumGeneration)
        try refusal(payload(), expected: .wrongPeer, peer: peer)
        let otherPeers: [OfficePeerBinding.ExpectedPeer] = [
            .init(enrolmentID: "phone-1", officeID: "another-office", officeTransportID: "transport-office-1",
                  officeApplicationKey: officeKey.publicKey.rawRepresentation,
                  phoneTransportID: "transport-phone-1", phoneApplicationKey: phoneKey.publicKey.rawRepresentation,
                  minimumGeneration: 1),
            .init(enrolmentID: "phone-1", officeID: "office-1", officeTransportID: "transport-office-2",
                  officeApplicationKey: officeKey.publicKey.rawRepresentation,
                  phoneTransportID: "transport-phone-1", phoneApplicationKey: phoneKey.publicKey.rawRepresentation,
                  minimumGeneration: 1),
            .init(enrolmentID: "phone-1", officeID: "office-1", officeTransportID: "transport-office-1",
                  officeApplicationKey: phoneKey.publicKey.rawRepresentation,
                  phoneTransportID: "transport-phone-1", phoneApplicationKey: phoneKey.publicKey.rawRepresentation,
                  minimumGeneration: 1),
            .init(enrolmentID: "phone-1", officeID: "office-1", officeTransportID: "transport-office-1",
                  officeApplicationKey: officeKey.publicKey.rawRepresentation,
                  phoneTransportID: "transport-phone-2", phoneApplicationKey: phoneKey.publicKey.rawRepresentation,
                  minimumGeneration: 1),
            .init(enrolmentID: "phone-1", officeID: "office-1", officeTransportID: "transport-office-1",
                  officeApplicationKey: officeKey.publicKey.rawRepresentation,
                  phoneTransportID: "transport-phone-1", phoneApplicationKey: officeKey.publicKey.rawRepresentation,
                  minimumGeneration: 1),
        ]
        for peer in otherPeers { try refusal(payload(), expected: .wrongPeer, peer: peer) }
    }

    func testValidityAndGenerationBoundaries() throws {
        try refusal(payload(), expected: .rollback, peer: expected(minimumGeneration: 5))
        let p = payload()
        let future = OfficePeerBinding.Payload(
            version: p.version, kind: p.kind, organizationID: p.organizationID, profileID: p.profileID,
            enrolmentID: p.enrolmentID, officeID: p.officeID, generation: p.generation,
            officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
            phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
            issuedAt: now + 1, expiresAt: now + 3_600)
        try refusal(future, expected: .notCurrentlyValid)
        let tooLong = OfficePeerBinding.Payload(
            version: p.version, kind: p.kind, organizationID: p.organizationID, profileID: p.profileID,
            enrolmentID: p.enrolmentID, officeID: p.officeID, generation: p.generation,
            officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
            phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
            issuedAt: p.issuedAt, expiresAt: p.issuedAt + 31 * 86_400)
        try refusal(tooLong, expected: .invalidFields)
        let boundedRoot = try root(profile(expiry: Date(timeIntervalSince1970: TimeInterval(now + 100))))
        XCTAssertThrowsError(try OfficePeerBinding.verify(envelope(p), root: boundedRoot,
                                                           expected: expected(), now: now)) {
            XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .notCurrentlyValid)
        }
    }

    func testSignedAmbiguousJSONIsStillMalformed() throws {
        let valid = try JSONEncoder().encode(payload())
        let text = try XCTUnwrap(String(data: valid, encoding: .utf8))
        for malformed in [text.replacingOccurrences(of: "{", with: "{\"kind\":\"avenkin.office-peer-binding\",", range: text.startIndex..<text.endIndex),
                          text.replacingOccurrences(of: "{", with: "{\"surprise\":1,", range: text.startIndex..<text.endIndex),
                          text.replacingOccurrences(of: "\"generation\":4", with: "\"generation\":4.0")] {
            let data = try envelope(Data(malformed.utf8))
            XCTAssertThrowsError(try OfficePeerBinding.verify(data, root: root(), expected: expected(), now: now)) {
                XCTAssertEqual($0 as? OfficePeerBinding.Refusal, .malformed)
            }
        }
    }

    func testAcceptedGenerationSurvivesStoreRecreationAndRejectsConflict() async throws {
        let prefix = "office.peer.binding.tests.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "northbridge", enrolmentID: "phone-1")
        defer { try? KeychainService.deleteItem(prefix + scope) }
        let store = OfficePeerHighWaterStore(keyPrefix: prefix)
        let original = try OfficePeerBinding.verify(envelope(payload()), root: root(),
                                                    expected: expected(), now: now)
        let firstDecision = try await store.accept(original)
        XCTAssertEqual(firstDecision, .accepted(.init(
            scopeID: scope, generation: 4, payloadSHA256: original.payloadSHA256)))

        let reopened = OfficePeerHighWaterStore(keyPrefix: prefix)
        let persisted = try await reopened.read(organizationID: "northbridge", enrolmentID: "phone-1")
        XCTAssertEqual(persisted?.generation, 4)
        let repeatDecision = try await reopened.accept(original)
        XCTAssertEqual(repeatDecision, .replay(.init(
            scopeID: scope, generation: 4, payloadSHA256: original.payloadSHA256)))

        let p = payload()
        let old = OfficePeerBinding.Payload(
            version: p.version, kind: p.kind, organizationID: p.organizationID, profileID: p.profileID,
            enrolmentID: p.enrolmentID, officeID: p.officeID, generation: 3,
            officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
            phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
            issuedAt: p.issuedAt, expiresAt: p.expiresAt)
        let rollback = try OfficePeerBinding.verify(envelope(old), root: root(), expected: expected(), now: now)
        do {
            _ = try await reopened.accept(rollback)
            XCTFail("an older signed generation was accepted")
        } catch {
            XCTAssertEqual(error as? OfficePeerHighWaterStore.Refusal, .rollback)
        }
        let changed = OfficePeerBinding.Payload(
            version: p.version, kind: p.kind, organizationID: p.organizationID, profileID: p.profileID,
            enrolmentID: p.enrolmentID, officeID: p.officeID, generation: p.generation,
            officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
            phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
            issuedAt: p.issuedAt + 1, expiresAt: p.expiresAt)
        let conflict = try OfficePeerBinding.verify(envelope(changed), root: root(), expected: expected(), now: now)
        do {
            _ = try await reopened.accept(conflict)
            XCTFail("a different signed binding at the accepted generation was accepted")
        } catch {
            XCTAssertEqual(error as? OfficePeerHighWaterStore.Refusal, .generationConflict)
        }

        let rotated = OfficePeerBinding.Payload(
            version: p.version, kind: p.kind, organizationID: p.organizationID, profileID: p.profileID,
            enrolmentID: p.enrolmentID, officeID: p.officeID, generation: 5,
            officeTransportID: p.officeTransportID, officeApplicationKey: p.officeApplicationKey,
            phoneTransportID: p.phoneTransportID, phoneApplicationKey: p.phoneApplicationKey,
            issuedAt: p.issuedAt, expiresAt: p.expiresAt)
        let next = try OfficePeerBinding.verify(envelope(rotated), root: root(),
                                                expected: expected(minimumGeneration: 4), now: now)
        let updated = try await reopened.accept(next)
        XCTAssertEqual(updated, .accepted(.init(scopeID: scope, generation: 5,
                                                payloadSHA256: next.payloadSHA256)))
        let afterUpdate = OfficePeerHighWaterStore(keyPrefix: prefix)
        let saved = try await afterUpdate.read(organizationID: "northbridge", enrolmentID: "phone-1")
        XCTAssertEqual(saved?.generation, 5)
    }
}
