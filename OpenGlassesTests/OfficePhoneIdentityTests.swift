import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

@MainActor
final class OfficePhoneIdentityTests: XCTestCase {
    func testDeviceOnlyIdentityPersistsAndProvesFreshChallenge() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        let first = OfficePhoneIdentity(account: account)
        let publicKey = try await first.publicKey()
        XCTAssertEqual(publicKey.count, 32)
        let challenge = Data((0..<32).map { UInt8($0) })
        let signature = try await first.signChallenge(challenge)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: OfficePhoneIdentity.possessionDomain + challenge))
        XCTAssertFalse(verifier.isValidSignature(signature, for: challenge))
        XCTAssertFalse(verifier.isValidSignature(signature, for: OfficePhoneIdentity.possessionDomain
                                                + Data(repeating: 9, count: 32)))

        let reopened = OfficePhoneIdentity(account: account)
        let retainedKey = try await reopened.publicKey()
        XCTAssertEqual(retainedKey, publicKey)
    }

    func testOnlyAManagedJobReceiptIsSignedUnderTheReceiptDomain() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        let identity = OfficePhoneIdentity(account: account)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: await identity.publicKey())
        // The exact bytes the transport offers: here, the golden receipt's payload.
        let fixture = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "managed-job-receipt-v1", withExtension: "json")))
        let envelope = try JSONDecoder().decode(OfficeManagedJobReceipt.Envelope.self, from: fixture)
        let payload = try XCTUnwrap(Data(base64Encoded: envelope.payload))
        let signature = try await identity.signManagedJobReceipt(payload)
        XCTAssertTrue(verifier.isValidSignature(signature, for: OfficeManagedJobReceipt.domain + payload))
        XCTAssertFalse(verifier.isValidSignature(signature, for: payload))

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        fields["outcome"] = "accepted"
        let notAReceipt = [try JSONSerialization.data(withJSONObject: fields),
                           Data(#"{"kind":"avenkin.commission-redemption"}"#.utf8),
                           Data(repeating: 7, count: 32)]
        for other in notAReceipt {
            do {
                _ = try await identity.signManagedJobReceipt(other)
                XCTFail("the receipt signer signed something that is not a receipt")
            } catch {
                XCTAssertEqual(error as? OfficePhoneIdentity.Refusal, .invalidReceipt)
            }
        }
    }

    func testCorruptStoredIdentityFailsClosed() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        try KeychainService.upsertDataAtomically(Data(repeating: 0x42, count: 4), for: account,
                                                 accessibility: .afterFirstUnlockThisDeviceOnly)
        let identity = OfficePhoneIdentity(account: account)
        do {
            _ = try await identity.publicKey()
            XCTFail("a damaged identity must not be replaced silently")
        } catch {
            XCTAssertEqual(error as? OfficePhoneIdentity.Refusal, .corruptIdentity)
        }
    }

    private func redemptionInput(phoneKey: Data, kind: String = "avenkin.commission-redemption",
                                 domain: Data = OfficePhoneIdentity.commissionRedemptionDomain) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": 1, "kind": kind, "enrolmentID": "phone-one",
            "phoneApplicationKey": phoneKey.base64EncodedString(),
        ])
        return domain + payload
    }

    func testSignsACommissioningRedemptionPresentingItsOwnKey() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        let identity = OfficePhoneIdentity(account: account)
        let publicKey = try await identity.publicKey()
        let input = try redemptionInput(phoneKey: publicKey)
        XCTAssertTrue(input.starts(with: Data("Avenkin.CommissionRedemption.v1".utf8) + [0]))
        let signature = try await identity.signCommissionRedemption(input)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: input))
        XCTAssertFalse(verifier.isValidSignature(signature, for: input.dropFirst(32)))
    }

    /// The contract's fixture phone key (seed = SHA-256 of its public label) signs the fixture
    /// redemption's exact bytes, and both its signature and the fixture's verify over them.
    func testSignsTheFixtureRedemptionWithTheFixtureKey() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        let keys = try CommissionFixtures.keys()
        let seed = Data(SHA256.hash(data: Data(try XCTUnwrap(keys["phoneKeyLabel"] as? String).utf8)))
        try KeychainService.upsertDataAtomically(seed, for: account, accessibility: .afterFirstUnlockThisDeviceOnly)
        let identity = OfficePhoneIdentity(account: account)
        let publicKey = try await identity.publicKey()
        XCTAssertEqual(publicKey.base64EncodedString(), keys["phoneApplicationKey"] as? String)

        let payload = try CommissionFixtures.payload("commission-redemption-v1.json")
        let input = OfficePhoneIdentity.commissionRedemptionDomain + payload
        let signature = try await identity.signCommissionRedemption(input)
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: input))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(CommissionFixtures.text("commission-redemption-v1.json").utf8)) as? [String: String])
        XCTAssertTrue(verifier.isValidSignature(try XCTUnwrap(Data(base64Encoded: XCTUnwrap(envelope["signature"]))),
                                                for: input))
    }

    func testRefusesToSignAnythingButItsOwnRedemption() async throws {
        let account = "office.phone.identity.tests.\(UUID().uuidString)"
        defer { try? KeychainService.deleteItem(account) }
        let identity = OfficePhoneIdentity(account: account)
        let publicKey = try await identity.publicKey()
        let fixtureKey = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(CommissionFixtures.keys()["phoneApplicationKey"] as? String)))
        let payloadOnly = try redemptionInput(phoneKey: publicKey).dropFirst(OfficePhoneIdentity.commissionRedemptionDomain.count)
        let refused: [(String, Data)] = [
            ("no domain", Data(payloadOnly)),
            ("the domain without its zero byte", Data("Avenkin.CommissionRedemption.v1".utf8) + payloadOnly),
            ("another domain", try redemptionInput(phoneKey: publicKey,
                                                   domain: Data("Avenkin.CommissionApproval.v1\0".utf8))),
            ("the possession domain", try redemptionInput(phoneKey: publicKey, domain: OfficePhoneIdentity.possessionDomain)),
            ("nothing after the domain", OfficePhoneIdentity.commissionRedemptionDomain),
            ("another kind", try redemptionInput(phoneKey: publicKey, kind: "avenkin.commission-approval")),
            ("another phone's key", try redemptionInput(phoneKey: fixtureKey)),
            ("not JSON", OfficePhoneIdentity.commissionRedemptionDomain + Data("not json".utf8)),
            ("too long", OfficePhoneIdentity.commissionRedemptionDomain + Data(repeating: 0x20, count: 4_097)),
        ]
        for (name, input) in refused {
            do {
                _ = try await identity.signCommissionRedemption(input)
                XCTFail("signed \(name)")
            } catch {
                XCTAssertEqual(error as? OfficePhoneIdentity.Refusal, .invalidRedemption, name)
            }
        }
    }
}
