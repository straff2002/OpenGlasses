import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The phone's side of the check-in contract's negative cases (Contracts/office-check-in.md §11)
/// at the pairing gate, against the golden fixtures: what a result or a removal must be before it
/// changes the binding, the generation high-water mark, the lease or the enrolment.
@MainActor
final class PortableOfficeCheckInGateTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    /// A transport identity that is not the fixture phone's (it is the fixture office's).
    private static let otherPhone = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: TimeInterval(OfficeCheckInFixtures.now))
    }

    private struct Gate {
        let manager: OrgProfileManager
        let service: OfficePairingService
        let highWater: OfficePeerHighWaterStore
        let approved: OfficeApprovedPeerStore
        let clock: Clock
        func at(_ seconds: Int64) { clock.now = Date(timeIntervalSince1970: TimeInterval(OfficeCheckInFixtures.now + seconds)) }
        func generation() async throws -> Int64? {
            try await highWater.read(organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment")?.generation
        }
        func savedBinding() async throws -> Data? {
            try await approved.read(organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment")?.signedBinding
        }
    }

    /// The fixture phone, paired under the golden generation-1 binding.
    private func gate(policyExpiryDays: Double = 90) async throws -> Gate {
        let start = Date(timeIntervalSince1970: TimeInterval(F.now))
        let vendor = Curve25519.Signing.PrivateKey()
        let licensor = Curve25519.Signing.PrivateKey()
        let expiry = start.addingTimeInterval(policyExpiryDays * 86_400)
        let code = try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: "Fixture", issued: start.addingTimeInterval(-86_400),
            expires: expiry, organizationID: "fixture-organisation", profileID: "fixture-profile"),
            privateKeyBase64: licensor.rawRepresentation.base64EncodedString())
        let profile = ConfigProfile(
            keyId: "vendor-test", profileId: "fixture-profile", organizationName: "Fixture",
            issued: start.addingTimeInterval(-86_400), policyExpiry: expiry,
            leaseDays: 30, licenceCode: code, officeAuthority: .init(
                organizationID: "fixture-organisation",
                administratorPublicKey: try F.administrator().publicKey.rawRepresentation.base64EncodedString(),
                transportPolicy: "privateLan"), schemaVersion: 2)
        let document = try ProfileVerification.makeDocument(
            profile, privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        let manager = OrgProfileManager()
        manager.profile = profile
        manager.record = OrgEnrolmentRecord(document: document, source: .office,
                                            enrolmentId: "fixture-enrolment", activatedLicenceCode: code,
                                            revoked: false)
        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        let phoneTransportID = try XCTUnwrap(binding["phoneTransportID"] as? String)
        let phoneKey = try F.phone().publicKey.rawRepresentation
        let highWater = OfficePeerHighWaterStore()
        let approved = OfficeApprovedPeerStore()
        let clock = Clock()
        let service = OfficePairingService(
            manager: manager, currentLicence: { code },
            transportID: { phoneTransportID }, phoneApplicationKey: { phoneKey },
            highWater: highWater, approvedPeerStore: approved,
            profileKeys: ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()],
            licenceKey: licensor.publicKey.rawRepresentation.base64EncodedString(), clock: { clock.now })
        _ = try await service.approve(
            F.data("office-check-in-binding-v1"),
            reviewedOffice: .init(officeID: XCTUnwrap(binding["officeID"] as? String),
                                  transportID: XCTUnwrap(binding["officeTransportID"] as? String),
                                  applicationPublicKey: F.office().publicKey.rawRepresentation),
            lanHint: "192.168.1.2:22000")
        return Gate(manager: manager, service: service, highWater: highWater, approved: approved, clock: clock)
    }

    /// A result the administrator signed, changed from the golden one.
    private func result(_ change: (inout [String: Any]) -> Void) throws -> Data {
        try F.changed("office-check-in-result-v1", domain: OfficeCheckIn.resultDomain, by: F.administrator(), change)
    }

    /// A binding envelope changed from the golden generation-1 payload, as a result carries one.
    private func binding(by signer: Curve25519.Signing.PrivateKey? = nil,
                         _ change: (inout [String: Any]) -> Void) throws -> String {
        String(decoding: try F.changed("office-check-in-binding-v1", domain: OfficePeerBinding.domain,
                                       by: signer ?? F.administrator(), change), as: UTF8.self)
    }

    private func assertNothingChanged(_ gate: Gate, generation: Int64 = 1, saved: Data? = nil,
                                      _ name: String, line: UInt = #line) async throws {
        let retained = try await gate.generation()
        let binding = try await gate.savedBinding()
        XCTAssertEqual(retained, generation, name, line: line)
        XCTAssertEqual(binding, try saved ?? F.data("office-check-in-binding-v1"), name, line: line)
        XCTAssertEqual(gate.manager.leaseRenewals, generation == 1 ? [] : [generation], name, line: line)
    }

    // MARK: - Renewal

    func testTheGoldenResultRenewsInTheContractsOrder() async throws {
        let gate = try await gate()
        gate.at(200)
        let approval = try await gate.service.renew(withResult: F.data("office-check-in-result-v1"),
                                                    waiting: F.waiting())
        XCTAssertEqual(approval.binding.payload.generation, 2)
        let retained = try await gate.generation()
        XCTAssertEqual(retained, 2)
        let current = try await gate.service.currentApprovedPeer()
        XCTAssertEqual(current.binding.payload.generation, 2)
        XCTAssertEqual(current.binding.payloadSHA256, approval.binding.payloadSHA256)
        XCTAssertEqual(current.lanHint, "tcp://192.168.1.2:22000")
        XCTAssertEqual(gate.manager.leaseRenewals, [2])

        // The folders then open under the new generation, and the transport is handed what
        // check-in is read against.
        let folders = OfficeManagedFolderMemoryTransport()
        try await gate.service.openFoldersWithApprovedOffice(folders)
        let starts = await folders.starts
        let handed = try F.fields(Data(XCTUnwrap(starts.first?.bindingJSON).utf8))
        XCTAssertEqual(Set(handed.keys), OfficeManagedFolderMemoryTransport.bindingFields)
        XCTAssertEqual(handed["generation"] as? Int, 2)
        XCTAssertEqual(handed["bindingSHA256"] as? String, approval.binding.payloadSHA256)
        XCTAssertEqual(handed["profileID"] as? String, "fixture-profile")
        XCTAssertEqual(handed["administratorKey"] as? String,
                       try F.administrator().publicKey.rawRepresentation.base64EncodedString())
    }

    func testAResultNotTheAdministratorsOrNotForThisExchangeChangesNothing() async throws {
        let waiting = try F.waiting()
        let cases: [(String, Data, OfficeCheckIn.Waiting, OfficeCheckIn.Refusal)] = [
            ("signed by the office application key instead of the administrator key",
             try F.signed(F.payload("office-check-in-result-v1"), domain: OfficeCheckIn.resultDomain, by: F.office()),
             waiting, .badSignature),
            ("under the removal's domain",
             try F.signed(F.payload("office-check-in-result-v1"), domain: OfficeCheckIn.removalDomain, by: F.administrator()),
             waiting, .badSignature),
            ("for another check-in", try F.data("office-check-in-result-v1"),
             .init(challengeID: waiting.challengeID, checkInSHA256: String(repeating: "0", count: 64),
                   generation: 1, bindingSHA256: waiting.bindingSHA256), .wrongBinding),
            ("for a check-in that named another binding", try F.data("office-check-in-result-v1"),
             .init(challengeID: waiting.challengeID, checkInSHA256: waiting.checkInSHA256,
                   generation: 1, bindingSHA256: String(repeating: "0", count: 64)), .notARenewal),
            ("for another phone", try result { $0["phoneTransportID"] = Self.otherPhone }, waiting, .wrongBinding),
            ("for another enrolment", try result { $0["enrolmentID"] = "another-enrolment" }, waiting, .wrongBinding),
            ("for another office", try result { $0["officeID"] = "office-000000000000000000000000" }, waiting, .wrongBinding),
            ("with an extra field", try result { $0["leaseDays"] = 365 }, waiting, .malformed),
            ("with a missing field", try result { $0["outcome"] = nil }, waiting, .malformed),
        ]
        for (name, data, waitingOn, expected) in cases {
            let gate = try await gate()
            gate.at(200)
            do {
                try await gate.service.renew(withResult: data, waiting: waitingOn)
                XCTFail("\(name): renewed")
            } catch {
                XCTAssertEqual(error as? OfficeCheckIn.Refusal, expected, name)
            }
            try await assertNothingChanged(gate, name)
        }
    }

    func testAResultWhoseBindingIsNoRenewalChangesNothing() async throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let golden = String(decoding: try F.data("office-check-in-binding-v1"), as: UTF8.self)
        let cases: [(String, String, Error)] = [
            ("repeats the generation", golden, OfficeCheckIn.Refusal.notARenewal),
            ("changes the office application key",
             try binding { $0["generation"] = 2; $0["officeApplicationKey"] = other }, OfficePeerBinding.Refusal.wrongPeer),
            ("changes the phone application key",
             try binding { $0["generation"] = 2; $0["phoneApplicationKey"] = other }, OfficePeerBinding.Refusal.wrongPeer),
            ("changes the office transport identity",
             try binding { $0["generation"] = 2; $0["officeTransportID"] = $0["phoneTransportID"] }, OfficePeerBinding.Refusal.wrongPeer),
            ("changes the office identifier",
             try binding { $0["generation"] = 2; $0["officeID"] = "office-000000000000000000000000" },
             OfficePeerBinding.Refusal.wrongPeer),
            ("changes the enrolment",
             try binding { $0["generation"] = 2; $0["enrolmentID"] = "another-enrolment" }, OfficePeerBinding.Refusal.wrongPeer),
            ("changes the profile",
             try binding { $0["generation"] = 2; $0["profileID"] = "another-profile" },
             OfficePeerBinding.Refusal.wrongOrganizationOrProfile),
            ("is signed by the office application key",
             try binding(by: F.office()) { $0["generation"] = 2 }, OfficePeerBinding.Refusal.badSignature),
            ("lasts more than thirty days",
             try binding { $0["generation"] = 2; $0["expiresAt"] = F.now + 40 * 86_400 }, OfficePeerBinding.Refusal.invalidFields),
            ("is not yet valid on this phone's clock",
             try binding { $0["generation"] = 2; $0["issuedAt"] = F.now + 3_600; $0["expiresAt"] = F.now + 86_400 },
             OfficePeerBinding.Refusal.notCurrentlyValid),
        ]
        for (name, carried, expected) in cases {
            let gate = try await gate()
            gate.at(200)
            do {
                try await gate.service.renew(withResult: result { $0["peerBinding"] = carried }, waiting: F.waiting())
                XCTFail("\(name): renewed")
            } catch {
                XCTAssertEqual(String(describing: error), String(describing: expected), name)
            }
            try await assertNothingChanged(gate, name)
        }

        // One that outlives the profile's own term: the golden renewal ends thirty days on, this
        // profile in twenty-nine.
        let short = try await gate(policyExpiryDays: 29)
        short.at(200)
        do {
            try await short.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: F.waiting())
            XCTFail("a binding past policyExpiry renewed")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .notCurrentlyValid)
        }
        try await assertNothingChanged(short, "outlives policyExpiry")
    }

    func testAResultThatLowersTheGenerationOrSetsASecondBindingAtItIsRefused() async throws {
        let gate = try await gate()
        gate.at(200)
        let renewed = try await gate.service.renew(withResult: F.data("office-check-in-result-v1"),
                                                   waiting: F.waiting())
        let saved = try await gate.savedBinding()
        // A later check-in, made under generation 2.
        let later = OfficeCheckIn.Waiting(challengeID: try F.waiting().challengeID,
                                          checkInSHA256: try F.waiting().checkInSHA256,
                                          generation: 2, bindingSHA256: renewed.binding.payloadSHA256)
        let golden = String(decoding: try F.data("office-check-in-binding-v1"), as: UTF8.self)
        for (name, carried, expected) in [
            ("lowers the generation", golden, "rollback"),
            ("sets another binding at the generation held",
             try binding { $0["generation"] = 2; $0["issuedAt"] = F.now + 100; $0["expiresAt"] = F.now + 86_400 },
             "notARenewal"),
        ] {
            do {
                try await gate.service.renew(withResult: result { $0["peerBinding"] = carried }, waiting: later)
                XCTFail("\(name): renewed")
            } catch {
                XCTAssertEqual(String(describing: error), expected, name)
            }
            try await assertNothingChanged(gate, generation: 2, saved: saved, name)
        }
    }

    /// The gate renews for a check-in the caller is still waiting on. The same result with the
    /// same check-in is the repair of an interrupted commit; once the caller has forgotten that
    /// check-in, the result fits whatever it waits on next and renews nothing.
    func testAResultTakenInTwiceRenewsOnlyWhileItsCheckInIsStillWaitedOn() async throws {
        let gate = try await gate()
        gate.at(200)
        let waiting = try F.waiting()
        let first = try await gate.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: waiting)
        let saved = try await gate.savedBinding()
        gate.at(300)
        let repeated = try await gate.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: waiting)
        XCTAssertEqual(repeated.binding.payloadSHA256, first.binding.payloadSHA256)
        let retained = try await gate.generation()
        XCTAssertEqual(retained, 2)
        XCTAssertEqual(gate.manager.leaseRenewals, [2, 2])

        gate.at(86_400)
        let next = OfficeCheckIn.Waiting(challengeID: String(repeating: "a", count: 32),
                                         checkInSHA256: String(repeating: "b", count: 64),
                                         generation: 2, bindingSHA256: first.binding.payloadSHA256)
        do {
            try await gate.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: next)
            XCTFail("a stored result renewed a lease later")
        } catch {
            XCTAssertEqual(error as? OfficeCheckIn.Refusal, .wrongBinding)
        }
        let after = try await gate.savedBinding()
        XCTAssertEqual(after, saved)
        XCTAssertEqual(gate.manager.leaseRenewals, [2, 2])
    }

    func testRenewalIsBeforeTheEnd() async throws {
        // The lease has run out.
        let lapsed = try await gate()
        lapsed.at(200)
        lapsed.manager.status = .lapsed
        do {
            try await lapsed.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: F.waiting())
            XCTFail("a lapsed lease was renewed")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        try await assertNothingChanged(lapsed, "lapsed lease")

        // The binding held has run out, twenty-nine days on, though the renewed one is still valid.
        let expired = try await gate()
        expired.at(29 * 86_400)
        do {
            try await expired.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: F.waiting())
            XCTFail("an expired binding was renewed")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .notCurrentlyValid)
        }
        try await assertNothingChanged(expired, "expired binding")
    }

    // MARK: - Removal

    func testOnlyTheAdministratorsRemovalForThisEnrolmentRevokes() async throws {
        let cases: [(String, Data, OfficeCheckIn.Refusal)] = [
            ("signed by the office application key",
             try F.signed(F.payload("office-removal-v1"), domain: OfficeCheckIn.removalDomain, by: F.office()), .badSignature),
            ("under the result's domain",
             try F.signed(F.payload("office-removal-v1"), domain: OfficeCheckIn.resultDomain, by: F.administrator()), .badSignature),
            ("for another enrolment", try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain,
                                                    by: F.administrator()) { $0["enrolmentID"] = "another-enrolment" }, .wrongBinding),
            ("for another profile", try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain,
                                                  by: F.administrator()) { $0["profileID"] = "another-profile" }, .wrongBinding),
            ("for another phone", try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain,
                                                by: F.administrator()) { $0["phoneTransportID"] = Self.otherPhone }, .wrongBinding),
            ("with a nested field", try F.signed(
                Data(String(decoding: F.payload("office-removal-v1"), as: UTF8.self)
                    .replacingOccurrences(of: "\"reason\":\"removed\"", with: "\"reason\":{\"is\":\"removed\"}").utf8),
                domain: OfficeCheckIn.removalDomain, by: F.administrator()), .malformed),
        ]
        for (name, data, expected) in cases {
            let gate = try await gate()
            gate.at(86_460)
            do {
                _ = try await gate.service.remove(withRemoval: data)
                XCTFail("\(name): removed")
            } catch {
                XCTAssertEqual(error as? OfficeCheckIn.Refusal, expected, name)
            }
            XCTAssertEqual(gate.manager.record?.revoked, false, name)
            _ = try await gate.service.currentApprovedPeer()
        }

        let gate = try await gate()
        gate.at(86_460)
        let removal = try await gate.service.remove(withRemoval: F.data("office-removal-v1"))
        XCTAssertEqual(removal.payload.reason, "removed")
        XCTAssertEqual(gate.manager.record?.revoked, true)
        // An exact repeat changes nothing, and no managed connection opens for the enrolment again.
        _ = try await gate.service.remove(withRemoval: F.data("office-removal-v1"))
        do {
            _ = try await gate.service.currentApprovedPeer()
            XCTFail("a removed enrolment's pairing still verified")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        let folders = OfficeManagedFolderMemoryTransport()
        do {
            try await gate.service.openFoldersWithApprovedOffice(folders)
            XCTFail("the folders opened for a removed enrolment")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        // A removed enrolment is not renewed either.
        do {
            try await gate.service.renew(withResult: F.data("office-check-in-result-v1"), waiting: F.waiting())
            XCTFail("a removed enrolment was renewed")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
    }
}
