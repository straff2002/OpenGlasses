import XCTest
@testable import OpenGlasses

/// Plan HA C5 — on a managed phone the device owner's authentication is not the administrator's:
/// only the organisation's admin card or passcode opens the administrator view, and without one the
/// entry point is not offered. Pure, plus the gate.
final class AdministratorAccessPolicyTests: XCTestCase {

    private typealias Policy = AdministratorAccessPolicy

    private let passcode = AdminCredentials.Passcode(salt: Data("salt".utf8), iterations: 100_000,
                                                     hash: Data(repeating: 1, count: 32))
    private let digest = Data(repeating: 2, count: 32)

    private func edition(passcode: Bool, card: Bool) -> AdminPolicy {
        AdminPolicy(edition: .fieldAssist,
                    credentials: AdminCredentials(passcode: passcode ? self.passcode : nil,
                                                  cardDigest: card ? digest : nil))
    }

    func testTheDeviceOwnerIsNeverTheAdministrator() {
        for (hasPasscode, hasCard) in [(false, false), (true, false), (false, true), (true, true)] {
            XCTAssertFalse(Policy.accepts(.deviceOwner, policy: edition(passcode: hasPasscode, card: hasCard)),
                           "passcode \(hasPasscode), card \(hasCard)")
        }
        XCTAssertFalse(Policy.accepts(.deviceOwner, policy: nil))
    }

    func testOnlyTheCredentialsTheProfileIssuedAreAccepted() {
        XCTAssertTrue(Policy.accepts(.card, policy: edition(passcode: false, card: true)))
        XCTAssertFalse(Policy.accepts(.passcode, policy: edition(passcode: false, card: true)))
        XCTAssertTrue(Policy.accepts(.passcode, policy: edition(passcode: true, card: false)))
        XCTAssertFalse(Policy.accepts(.card, policy: edition(passcode: true, card: false)))
        XCTAssertFalse(Policy.accepts(.card, policy: nil), "an unmanaged phone has no administrator view")
        XCTAssertFalse(Policy.accepts(.passcode, policy: nil))
    }

    func testTheEntryPointIsOfferedOnlyToTheTechnicianWithACredentialToCheck() {
        XCTAssertFalse(Policy.offersUnlock(policy: edition(passcode: false, card: false), restricted: true),
                       "no card, no passcode: nothing the technician could not also pass")
        XCTAssertTrue(Policy.offersUnlock(policy: edition(passcode: false, card: true), restricted: true))
        XCTAssertTrue(Policy.offersUnlock(policy: edition(passcode: true, card: false), restricted: true))
        XCTAssertFalse(Policy.offersUnlock(policy: edition(passcode: true, card: true), restricted: false),
                       "already the administrator's view")
        XCTAssertFalse(Policy.offersUnlock(policy: nil, restricted: false), "unmanaged")
    }

    func testTheReviewSaysAProfileWithoutACredentialHasNoAdministratorView() {
        XCTAssertEqual(AdminCredentials().method, .notIssued)
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org",
                                    issued: Date(timeIntervalSince1970: 1_790_000_000), leaseDays: 30)
        var result = ProfileApplier.Result()
        result.adminPolicy = edition(passcode: false, card: false)
        let lines = OrgProfileReview(document: "", source: .office, profile: profile, result: result,
                                     replacesCurrent: false).adminLines
        XCTAssertEqual(lines.last, "No admin card or passcode, so administrator settings don't open on this phone")
        XCTAssertFalse(lines.contains { $0.contains("Anyone who can unlock this phone") })
    }

    /// Whatever owner gate the person passes, what Settings draws is the visibility policy's: the
    /// technician's view stays in force, so locked settings stay hidden.
    @MainActor
    func testAProfileWithoutACredentialKeepsTheTechnicianViewAndItsLocks() {
        var seams = AdminGate.Seams()
        let policy = edition(passcode: false, card: false)
        seams.policy = { policy }
        seams.loadFailures = { 0 }
        seams.saveFailures = { _ in }
        seams.loadWaitUntil = { nil }
        seams.saveWaitUntil = { _ in }
        seams.loadCardSecret = { nil }
        seams.saveCardSecret = { _ in }
        let gate = AdminGate(seams: seams)
        XCTAssertFalse(gate.offersUnlock)
        XCTAssertTrue(gate.isRestricted)
        XCTAssertEqual(gate.tryPasscode("anything"), .notApplicable)
        XCTAssertEqual(gate.tryCard("og-admin:AAAA"), .notApplicable)
        XCTAssertTrue(gate.isRestricted)
        XCTAssertEqual(gate.presentation(.category(.intelligence)), .hidden)
        XCTAssertEqual(gate.presentation(.area(.ownerControls)), .hidden)
    }
}
