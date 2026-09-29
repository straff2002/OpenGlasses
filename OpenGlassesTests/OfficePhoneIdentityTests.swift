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
}
