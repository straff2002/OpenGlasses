import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// Check-in, renewal and removal on the phone, headless: the real pairing gate and organisation
/// manager, the in-memory transport, and the Go golden fixtures as the office's side.
@MainActor
final class OfficeCheckInServiceTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private static let day: TimeInterval = 86_400

    private let vendor = Curve25519.Signing.PrivateKey()
    private let licensor = Curve25519.Signing.PrivateKey()
    private let clock = CommissionTestClock(Date(timeIntervalSince1970: TimeInterval(OfficeCheckInFixtures.now)))
    private var keychainItems: [String] = []
    private var departures: [OrgDeparture.Reason] = []
    private var bindingChanges = 0

    override func tearDown() async throws {
        for item in keychainItems { try? KeychainService.deleteItem(item) }
    }

    private func at(_ seconds: Int64) { clock.now = Date(timeIntervalSince1970: TimeInterval(F.now + seconds)) }

    /// A ledger kept in memory, so a second service over it is the app launched again.
    private final class LedgerBox: @unchecked Sendable {
        var ledger = OfficeCheckInService.Ledger()
    }

    private struct World {
        let manager: OrgProfileManager
        let pairing: OfficePairingService
        let highWater: OfficePeerHighWaterStore
        let approved: OfficeApprovedPeerStore
        let folders: OfficeManagedFolderMemoryTransport
        let box: LedgerBox
        let service: OfficeCheckInService
        let challengeID: String
        let removalID: String
        let makeService: @MainActor () -> OfficeCheckInService
    }

    /// The fixture phone: enrolled with the fixture organisation ten days ago, paired with the
    /// fixture office under the golden generation-1 binding, its managed folders open.
    private func world(policyExpiryDays: Double = 90) async throws -> World {
        let enrolled = Date(timeIntervalSince1970: TimeInterval(F.now)).addingTimeInterval(-10 * Self.day)
        let expiry = Date(timeIntervalSince1970: TimeInterval(F.now)).addingTimeInterval(policyExpiryDays * Self.day)
        let code = try LicenseService.makeCode(payload: .init(
            feature: "field_assist", licensee: "Fixture", issued: enrolled.addingTimeInterval(-Self.day),
            expires: expiry, organizationID: "fixture-organisation", profileID: "fixture-profile"),
            privateKeyBase64: licensor.rawRepresentation.base64EncodedString())
        let profile = ConfigProfile(
            keyId: "vendor-test", profileId: "fixture-profile", organizationName: "Fixture",
            issued: enrolled.addingTimeInterval(-Self.day), policyExpiry: expiry,
            leaseDays: 30, licenceCode: code, officeAuthority: .init(
                organizationID: "fixture-organisation",
                administratorPublicKey: try F.administrator().publicKey.rawRepresentation.base64EncodedString(),
                transportPolicy: "privateLan"), schemaVersion: 2)
        let document = try ProfileVerification.makeDocument(
            profile, privateKeyBase64: vendor.rawRepresentation.base64EncodedString())
        let vendorKeys = ["vendor-test": vendor.publicKey.rawRepresentation.base64EncodedString()]
        let licenceKey = licensor.publicKey.rawRepresentation.base64EncodedString()

        var seams = OrgProfileManager.Seams()
        seams.now = { [clock] in clock.now }
        seams.verificationKeys = vendorKeys
        seams.licenceKey = licenceKey
        seams.resolvableVaultIds = { [] }
        seams.saveRecord = { _ in }
        seams.activateLicence = { _ in }
        seams.installEnvelope = { _, _ in }
        seams.clearEnvelope = {}
        seams.withholdLicence = { _ in }
        seams.forgetAdminCard = {}
        seams.activeJobId = { nil }
        seams.newEnrolmentId = { "fixture-enrolment" }
        seams.beginDeparture = { [unowned self] reason, _, _ in self.departures.append(reason) }
        let manager = OrgProfileManager(seams: seams)
        clock.now = enrolled
        let review = try manager.review(document: document, source: .office, enteredLicence: code).get()
        try manager.apply(review).get()
        at(0)

        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        let phoneTransportID = try XCTUnwrap(binding["phoneTransportID"] as? String)
        let phoneKey = try F.phone()
        let highWaterPrefix = "office.checkin.tests.highwater.\(UUID().uuidString)."
        let approvedPrefix = "office.checkin.tests.approved.\(UUID().uuidString)."
        let scope = try OfficePeerHighWaterStore.scopeID(organizationID: "fixture-organisation",
                                                         enrolmentID: "fixture-enrolment")
        keychainItems += [highWaterPrefix + scope, approvedPrefix + scope]
        let highWater = OfficePeerHighWaterStore(keyPrefix: highWaterPrefix)
        let approved = OfficeApprovedPeerStore(keyPrefix: approvedPrefix)
        let pairing = OfficePairingService(
            manager: manager, currentLicence: { code },
            transportID: { phoneTransportID },
            phoneApplicationKey: { phoneKey.publicKey.rawRepresentation },
            highWater: highWater, approvedPeerStore: approved,
            profileKeys: vendorKeys, licenceKey: licenceKey, clock: { [clock] in clock.now },
            startManagedOffice: { _, _, _ in }, stopManagedOffice: {})
        _ = try await pairing.approve(
            F.data("office-check-in-binding-v1"),
            reviewedOffice: .init(officeID: XCTUnwrap(binding["officeID"] as? String),
                                  transportID: XCTUnwrap(binding["officeTransportID"] as? String),
                                  applicationPublicKey: F.office().publicKey.rawRepresentation),
            lanHint: "192.168.1.24:22000")
        let folders = OfficeManagedFolderMemoryTransport()
        try await pairing.openFoldersWithApprovedOffice(folders)

        // The golden check-in's own signature for the golden payload (CryptoKit's signatures are
        // randomised, so the fixture's bytes are only reproduced by its own); the fixture phone
        // key for anything else.
        let goldenPayload = try F.payload("office-check-in-v1")
        let goldenSignature = try XCTUnwrap(Data(base64Encoded: F.envelope(F.data("office-check-in-v1")).signature))
        let box = LedgerBox()
        let makeService: @MainActor () -> OfficeCheckInService = { [clock, unowned self] in
            var seams = OfficeCheckInService.Seams.app(transport: folders, pairing: { pairing },
                                                       manager: manager, ledgerFile: nil)
            seams.signCheckIn = { payload in
                guard OfficeCheckIn.checkInPayload(payload) != nil else { throw OfficePhoneIdentity.Refusal.invalidCheckIn }
                if payload == goldenPayload { return goldenSignature }
                return try phoneKey.signature(for: OfficeCheckIn.checkInDomain + payload)
            }
            seams.signRemovalReceipt = { payload in
                guard OfficeCheckIn.removalReceiptPayload(payload) != nil else {
                    throw OfficePhoneIdentity.Refusal.invalidRemovalReceipt
                }
                return try phoneKey.signature(for: OfficeCheckIn.removalReceiptDomain + payload)
            }
            seams.appVersion = { "1.0.0" }
            seams.appBuild = { "100" }
            seams.clock = { clock.now }
            seams.bindingChanged = { self.bindingChanges += 1 }
            seams.load = { box.ledger }
            seams.save = { box.ledger = $0 }
            return OfficeCheckInService(seams: seams)
        }
        let challenge = try F.fields(F.payload("office-check-in-challenge-v1"))
        let removal = try F.fields(F.payload("office-removal-v1"))
        return World(manager: manager, pairing: pairing, highWater: highWater, approved: approved,
                     folders: folders, box: box, service: makeService(),
                     challengeID: try XCTUnwrap(challenge["challengeID"] as? String),
                     removalID: try XCTUnwrap(removal["removalID"] as? String), makeService: makeService)
    }

    /// The office sets the golden challenge, and the transport offers the golden check-in for it.
    private func setGoldenChallenge(_ w: World) async throws {
        await w.folders.put(challenge: try F.data("office-check-in-challenge-v1"), id: w.challengeID)
        await w.folders.offer(checkInPayload: try F.payload("office-check-in-v1"), for: w.challengeID)
    }

    private func generation(_ w: World) async throws -> Int64? {
        try await w.highWater.read(organizationID: "fixture-organisation", enrolmentID: "fixture-enrolment")?.generation
    }

    // MARK: - The exchange

    func testTheFixtureExchangeRenewsTheBindingAndTheLease() async throws {
        let w = try await world()
        let leaseBefore = try XCTUnwrap(w.manager.record?.lastRenewedAt)
        try await setGoldenChallenge(w)
        at(60)
        let answered = try await w.service.sweep()
        XCTAssertEqual(answered, .answered)
        // What was published is the golden check-in, byte for byte.
        let published = await w.folders.checkIns[w.challengeID]
        XCTAssertEqual(published, try F.data("office-check-in-v1"))
        XCTAssertEqual(w.service.state, .checkedIn)
        XCTAssertEqual(w.service.ledger.waiting?.nonce, "-_5H8uT1t4XtGy-Vcv1zCXUD0iEGCfVft_ZQ4rXjeVA")
        // A check-in alone renews nothing.
        XCTAssertEqual(w.manager.record?.lastRenewedAt, leaseBefore)

        await w.folders.put(result: try F.data("office-check-in-result-v1"), id: w.challengeID)
        at(200)
        let renewed = try await w.service.sweep()
        XCTAssertEqual(renewed, .renewed)
        // In the contract's order: the high-water mark, the saved binding, then the lease, from
        // this phone's own clock.
        let generationAfter = try await generation(w)
        XCTAssertEqual(generationAfter, 2)
        let current = try await w.pairing.currentApprovedPeer()
        XCTAssertEqual(current.binding.payload.generation, 2)
        XCTAssertEqual(current.lanHint, "tcp://192.168.1.24:22000", "the route hint is kept across a renewal")
        XCTAssertEqual(w.manager.record?.lastRenewedAt, clock.now)
        XCTAssertEqual(w.manager.lease, .live(renewBy: clock.now.addingTimeInterval(30 * Self.day)))
        XCTAssertEqual(bindingChanges, 1)
        // The nonce is forgotten.
        XCTAssertNil(w.service.ledger.waiting)
        XCTAssertEqual(w.service.state, .idle)

        // The folders start again under the new generation, with the new binding's digest.
        await w.folders.stop()
        try await w.pairing.openFoldersWithApprovedOffice(w.folders)
        let starts = await w.folders.starts
        let handed = try F.fields(Data(XCTUnwrap(starts.last?.bindingJSON).utf8))
        XCTAssertEqual(handed["generation"] as? Int, 2)
        XCTAssertEqual(handed["bindingSHA256"] as? String, current.binding.payloadSHA256)
        XCTAssertEqual(handed["profileID"] as? String, "fixture-profile")
        XCTAssertEqual(handed["administratorKey"] as? String,
                       try F.administrator().publicKey.rawRepresentation.base64EncodedString())
    }

    func testAReplayedResultChangesNothing() async throws {
        let w = try await world()
        try await setGoldenChallenge(w)
        at(60)
        try await w.service.sweep()
        await w.folders.put(result: try F.data("office-check-in-result-v1"), id: w.challengeID)
        at(200)
        try await w.service.sweep()
        let renewedAt = try XCTUnwrap(w.manager.record?.lastRenewedAt)

        // The result and the used challenge are still in the folder a day later, and after a
        // relaunch: nothing is renewed, and the used challenge is not answered again.
        at(200 + 86_400)
        for service in [w.service, w.makeService()] {
            let outcome = try await service.sweep()
            XCTAssertEqual(outcome, .nothing)
        }
        let generationAfter = try await generation(w)
        XCTAssertEqual(generationAfter, 2)
        XCTAssertEqual(w.manager.record?.lastRenewedAt, renewedAt)
        XCTAssertEqual(bindingChanges, 1)
        let publishes = await w.folders.checkInPublishes
        XCTAssertEqual(publishes, 1)
        // The used challenge names the generation before: recorded once, however often it is seen.
        XCTAssertEqual(w.box.ledger.refused.count, 1)
    }

    func testAChallengeIsAnsweredOnceAndTheSameBytesArePublishedAgain() async throws {
        let w = try await world()
        await w.folders.put(challenge: try F.data("office-check-in-challenge-v1"), id: w.challengeID)
        at(60)
        try await w.service.sweep()
        let first = await w.folders.checkIns[w.challengeID]
        let kept = try XCTUnwrap(w.service.ledger.waiting)
        XCTAssertEqual(kept.challengeSHA256, OfficeCheckIn.digest(try F.data("office-check-in-challenge-v1")))
        XCTAssertEqual(kept.checkInSHA256, first.map(OfficeCheckIn.digest))
        // The office reads it as this phone's answer to that challenge.
        let read = try OfficeCheckIn.checkIn(XCTUnwrap(first), phoneApplicationKey: F.phone().publicKey.rawRepresentation)
        XCTAssertEqual(read.nonce, kept.nonce)
        XCTAssertEqual(read.appVersion, "1.0.0")
        // Thirty days from the enrolment ten days ago: informational, for the office's list.
        XCTAssertEqual(read.leaseRenewBy, F.now + 20 * 86_400)

        for _ in 0..<3 {
            let outcome = try await w.service.sweep()
            XCTAssertEqual(outcome, .nothing)
        }
        // After a relaunch the same bytes are published again, not a second check-in.
        let relaunched = w.makeService()
        try await relaunched.sweep()
        let again = await w.folders.checkIns[w.challengeID]
        let publishes = await w.folders.checkInPublishes
        XCTAssertEqual(again, first)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(relaunched.ledger.waiting, kept)

        // A transport that lost its record offers another check-in for the same challenge, with
        // another nonce. This phone signs nothing for it.
        await w.folders.loseCheckIn(for: w.challengeID)
        let afterLoss = w.makeService()
        do {
            try await afterLoss.sweep()
            XCTFail("a second check-in was made for one challenge")
        } catch {
            XCTAssertEqual(error as? OfficeCheckInService.Failure, .notWhatWasAskedFor)
        }
        let secondCheckIn = await w.folders.checkIns[w.challengeID]
        XCTAssertNil(secondCheckIn)
        XCTAssertEqual(afterLoss.ledger.waiting?.nonce, kept.nonce)

        // Once the challenge has expired the check-in is forgotten.
        at(OfficeCheckIn.maximumChallengeLifetime)
        await w.folders.withdraw(challenge: w.challengeID)
        try await afterLoss.sweep()
        XCTAssertNil(afterLoss.ledger.waiting)
    }

    func testAPhoneWhoseLeaseOrPairingNoLongerHoldsAnswersNoChallenge() async throws {
        let w = try await world()
        // The lease ran from the enrolment ten days ago, so twenty-one days on it has run out. The
        // binding has a week left, and the office has set a challenge that is live.
        at(21 * 86_400)
        let late = try F.changed("office-check-in-challenge-v1", domain: OfficeCheckIn.challengeDomain,
                                 by: F.office()) {
            $0["issuedAt"] = F.now + 21 * 86_400 - 60
            $0["expiresAt"] = F.now + 22 * 86_400
        }
        await w.folders.put(challenge: late, id: w.challengeID)
        do {
            try await w.service.sweep()
            XCTFail("a challenge was answered on a lapsed lease")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        let published = await w.folders.checkIns
        XCTAssertTrue(published.isEmpty)
        XCTAssertNil(w.service.ledger.waiting)
    }

    // MARK: - A foreign result

    func testAForeignResultChangesNothing() async throws {
        let administrator = try F.administrator()
        let goldenBinding = String(decoding: try F.data("office-check-in-binding-v1"), as: UTF8.self)
        /// A binding the administrator signed, changed from the golden generation-1 payload.
        func binding(_ change: (inout [String: Any]) -> Void) throws -> String {
            String(decoding: try F.changed("office-check-in-binding-v1", domain: OfficePeerBinding.domain,
                                           by: administrator, change), as: UTF8.self)
        }
        func result(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try F.changed("office-check-in-result-v1", domain: OfficeCheckIn.resultDomain, by: administrator, change)
        }
        let cases: [(String, Data)] = [
            ("signed by the office application key",
             try F.signed(F.payload("office-check-in-result-v1"), domain: OfficeCheckIn.resultDomain, by: F.office())),
            ("for another check-in", try result { $0["checkInSHA256"] = String(repeating: "0", count: 64) }),
            ("for another enrolment", try result { $0["enrolmentID"] = "another-enrolment" }),
            ("for another phone", try result {
                $0["phoneTransportID"] = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"
            }),
            ("carrying the binding already held", try result { $0["peerBinding"] = goldenBinding }),
            ("carrying a binding for another office key", try result {
                $0["peerBinding"] = try! binding {
                    $0["generation"] = 2
                    $0["officeApplicationKey"] = administrator.publicKey.rawRepresentation.base64EncodedString()
                }
            }),
            ("carrying a binding for another phone key", try result {
                $0["peerBinding"] = try! binding {
                    $0["generation"] = 2
                    $0["phoneApplicationKey"] = administrator.publicKey.rawRepresentation.base64EncodedString()
                }
            }),
            ("carrying a binding for another profile", try result {
                $0["peerBinding"] = try! binding {
                    $0["generation"] = 2
                    $0["profileID"] = "another-profile"
                }
            }),
            ("carrying a binding the office application key signed", try result {
                var fields = try! F.fields(F.payload("office-check-in-binding-v1"))
                fields["generation"] = 2
                $0["peerBinding"] = String(decoding: try! F.signed(
                    JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                    domain: OfficePeerBinding.domain, by: F.office()), as: UTF8.self)
            }),
        ]
        for (name, foreign) in cases {
            bindingChanges = 0
            let w = try await world()
            try await setGoldenChallenge(w)
            at(60)
            try await w.service.sweep()
            let leaseBefore = w.manager.record?.lastRenewedAt
            await w.folders.put(result: foreign, id: w.challengeID)
            at(200)
            for _ in 0..<2 {
                let outcome = try await w.service.sweep()
                XCTAssertEqual(outcome, .nothing, name)
            }
            let generationAfter = try await generation(w)
            XCTAssertEqual(generationAfter, 1, name)
            let current = try await w.pairing.currentApprovedPeer()
            XCTAssertEqual(current.binding.payload.generation, 1, name)
            XCTAssertEqual(w.manager.record?.lastRenewedAt, leaseBefore, name)
            XCTAssertEqual(bindingChanges, 0, name)
            // Left where it is, and recorded once with a bounded reason.
            XCTAssertEqual(w.box.ledger.refused.count, 1, name)
            XCTAssertLessThanOrEqual(w.box.ledger.refused.first?.reason.count ?? .max, 200, name)
            // The check-in is still waiting, so the real result still renews.
            XCTAssertNotNil(w.service.ledger.waiting, name)
            await w.folders.put(result: try F.data("office-check-in-result-v1"), id: w.challengeID)
            let outcome = try await w.service.sweep()
            XCTAssertEqual(outcome, .renewed, name)
        }
    }

    func testARenewedBindingThatOutlivesTheProfilesTermWaitsAndRenewsNothing() async throws {
        // The golden renewal ends thirty days and two minutes on; this profile's term ends first.
        let w = try await world(policyExpiryDays: 30)
        try await setGoldenChallenge(w)
        at(60)
        try await w.service.sweep()
        let leaseBefore = w.manager.record?.lastRenewedAt
        await w.folders.put(result: try F.data("office-check-in-result-v1"), id: w.challengeID)
        at(200)
        let outcome = try await w.service.sweep()
        XCTAssertEqual(outcome, .nothing)
        let generationAfter = try await generation(w)
        XCTAssertEqual(generationAfter, 1)
        XCTAssertEqual(w.manager.record?.lastRenewedAt, leaseBefore)
        XCTAssertTrue(w.box.ledger.refused.isEmpty, "not valid on this phone is not remembered as refused")
    }

    func testACrashBetweenTheCommitStepsIsRepairedByTheSameResult() async throws {
        let w = try await world()
        try await setGoldenChallenge(w)
        at(60)
        try await w.service.sweep()
        let waiting = try F.waiting()
        at(200)
        try await w.pairing.renew(withResult: F.data("office-check-in-result-v1"), waiting: waiting)
        // As if the app had stopped after the high-water mark and before the saved binding: the
        // generation-1 binding is what is saved, and the mark is already 2.
        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        try await w.approved.save(
            F.data("office-check-in-binding-v1"), organizationID: "fixture-organisation",
            enrolmentID: "fixture-enrolment", officeID: XCTUnwrap(binding["officeID"] as? String),
            officeTransportID: XCTUnwrap(binding["officeTransportID"] as? String),
            officeApplicationKey: F.office().publicKey.rawRepresentation, lanHint: "192.168.1.24:22000")
        do {
            _ = try await w.pairing.currentApprovedPeer()
            XCTFail("a binding below the high-water mark opened a connection")
        } catch {
            XCTAssertEqual(error as? OfficePeerBinding.Refusal, .rollback)
        }
        // The same result, taken in again while the check-in is still kept, finishes the commit.
        at(260)
        await w.folders.put(result: try F.data("office-check-in-result-v1"), id: w.challengeID)
        let outcome = try await w.service.sweep()
        XCTAssertEqual(outcome, .renewed)
        let current = try await w.pairing.currentApprovedPeer()
        XCTAssertEqual(current.binding.payload.generation, 2)
        XCTAssertEqual(w.manager.record?.lastRenewedAt, clock.now)
        // And a second binding at the generation already retained is a conflict, not a renewal.
        let conflicting = try F.changed("office-check-in-result-v1", domain: OfficeCheckIn.resultDomain,
                                        by: F.administrator()) {
            $0["peerBinding"] = String(decoding: try! F.changed(
                "office-check-in-binding-v1", domain: OfficePeerBinding.domain, by: try! F.administrator()) {
                    $0["generation"] = 2
                    $0["issuedAt"] = F.now + 100
                    $0["expiresAt"] = F.now + 100 + 86_400
                }, as: UTF8.self)
        }
        try await w.approved.save(
            F.data("office-check-in-binding-v1"), organizationID: "fixture-organisation",
            enrolmentID: "fixture-enrolment", officeID: XCTUnwrap(binding["officeID"] as? String),
            officeTransportID: XCTUnwrap(binding["officeTransportID"] as? String),
            officeApplicationKey: F.office().publicKey.rawRepresentation)
        do {
            try await w.pairing.renew(withResult: conflicting, waiting: waiting)
            XCTFail("a second binding at one generation was accepted")
        } catch {
            XCTAssertEqual(error as? OfficePeerHighWaterStore.Refusal, .generationConflict)
        }
    }

    // MARK: - Removal

    func testARemovalRevokesAsASignedRevocationDoesAndIsReceipted() async throws {
        let w = try await world()
        try await setGoldenChallenge(w)
        at(60)
        try await w.service.sweep()
        XCTAssertNotNil(w.service.ledger.waiting)

        let removal = try F.data("office-removal-v1")
        await w.folders.put(removal: removal, id: w.removalID)
        at(86_460)
        let outcome = try await w.service.sweep()
        XCTAssertEqual(outcome, .removed)
        // Exactly what a signed revocation from a hosted profile does.
        XCTAssertEqual(w.manager.record?.revoked, true)
        XCTAssertEqual(w.manager.lease, .revoked)
        XCTAssertTrue(w.manager.contentLocked)
        XCTAssertEqual(departures, [.revoked])
        XCTAssertEqual(w.service.state, .removed(reason: "removed"))
        XCTAssertEqual(OfficeCheckInService.status(w.service.state)?.title, "Removed by your organisation")
        XCTAssertNil(w.service.ledger.waiting, "a removed phone waits on no check-in")

        // The receipt is this phone's, for exactly that removal, and says when it acted.
        let held = try F.held()
        let verified = try OfficeCheckIn.removal(
            removal, administratorKey: held.administratorKey, organizationID: held.organizationID,
            profileID: held.profileID, enrolmentID: held.enrolmentID, phoneTransportID: held.phoneTransportID)
        let published = await w.folders.removalReceipts[w.removalID]
        let receipt = try OfficeCheckIn.removalReceipt(XCTUnwrap(published),
                                                       phoneApplicationKey: held.phoneApplicationKey,
                                                       removal: verified)
        XCTAssertEqual(receipt.actedAt, F.now + 86_460)
        // With the fixture's clock the payload is the golden receipt's, byte for byte.
        let payloads = await w.folders.removalReceiptPayloads
        XCTAssertEqual(payloads[w.removalID], try F.payload("office-removal-receipt-v1"))

        // No further managed connection opens for that enrolment.
        do {
            _ = try await w.pairing.currentApprovedPeer()
            XCTFail("a removed phone's pairing still verified")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        await w.folders.stop()
        do {
            try await w.pairing.openFoldersWithApprovedOffice(w.folders)
            XCTFail("the folders opened for a removed enrolment")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        let open = await w.folders.isOpen
        XCTAssertFalse(open)

        // An exact repeat changes nothing, here or after a relaunch.
        for service in [w.service, w.makeService()] {
            let again = try await service.sweep()
            XCTAssertEqual(again, .removed)
        }
        XCTAssertEqual(departures, [.revoked])
        XCTAssertEqual(w.box.ledger.removal?.receiptPublished, true)
    }

    func testARevokedReasonChangesOnlyTheSentence() async throws {
        let w = try await world()
        let removal = try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain, by: F.administrator()) {
            $0["reason"] = "revoked"
        }
        await w.folders.put(removal: removal, id: w.removalID)
        at(60)
        let outcome = try await w.service.sweep()
        XCTAssertEqual(outcome, .removed)
        XCTAssertEqual(w.manager.record?.revoked, true)
        XCTAssertEqual(departures, [.revoked])
        XCTAssertEqual(w.service.state, .removed(reason: "revoked"))
        XCTAssertNotEqual(OfficeCheckInService.status(.removed(reason: "revoked"))?.detail,
                          OfficeCheckInService.status(.removed(reason: "removed"))?.detail)
        let published = await w.folders.removalReceipts[w.removalID]
        XCTAssertNotNil(published)
    }

    func testAForeignRemovalRemovesNothing() async throws {
        let cases: [(String, Data)] = [
            ("signed by the office application key",
             try F.signed(F.payload("office-removal-v1"), domain: OfficeCheckIn.removalDomain, by: F.office())),
            ("for another enrolment", try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain,
                                                    by: F.administrator()) { $0["enrolmentID"] = "another-enrolment" }),
            ("for another profile", try F.changed("office-removal-v1", domain: OfficeCheckIn.removalDomain,
                                                  by: F.administrator()) { $0["profileID"] = "another-profile" }),
            ("a result under a removal's name", try F.data("office-check-in-result-v1")),
        ]
        for (name, foreign) in cases {
            departures = []
            let w = try await world()
            await w.folders.put(removal: foreign, id: w.removalID)
            at(60)
            for _ in 0..<2 {
                let outcome = try await w.service.sweep()
                XCTAssertEqual(outcome, .nothing, name)
            }
            XCTAssertNotEqual(w.manager.record?.revoked, true, name)
            XCTAssertEqual(departures, [], name)
            XCTAssertEqual(w.service.state, .idle, name)
            XCTAssertEqual(w.box.ledger.refused.count, 1, name)
            let receipts = await w.folders.removalReceipts
            XCTAssertTrue(receipts.isEmpty, name)
            _ = try await w.pairing.currentApprovedPeer()
        }
    }

    func testARemovalForAnEarlierEnrolmentDoesNotFollowThePhoneIntoANewOne() async throws {
        let w = try await world()
        w.box.ledger.removal = .init(enrolmentID: "an-earlier-enrolment", removalID: w.removalID,
                                     removalSHA256: String(repeating: "0", count: 64), reason: "removed",
                                     actedAt: F.now, signature: nil, receiptPublished: true)
        let service = w.makeService()
        XCTAssertEqual(service.state, .removed(reason: "removed"))
        at(60)
        let outcome = try await service.sweep()
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(service.state, .idle)
    }
}
