import XCTest
@testable import OpenGlasses

/// Plan CT 3b — the edition, the administrator passcode verifier and admin card, and the gate that
/// checks them: backoff across launches, and a session that ends on background or idle.
///
/// The PBKDF2 and card-digest vectors were computed independently (Node's `crypto`), so they pin
/// what `Scripts/make-org-profile.swift` must also produce.
@MainActor
final class AdminGateTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_790_000_000)
    private var failures = 0
    private var waitUntil: Date?
    private var policy: AdminPolicy?

    /// "correct horse" under this salt at 100 000 iterations.
    private let salt = Data(base64Encoded: "b3BlbmdsYXNzZXMtc2FsdA==")!
    private let passcodeHash = Data(base64Encoded: "t3Byn9NtZwgSXo5BLIW88G5uJL/MRsOduKY91xwyFFI=")!
    private let cardBody = "0123456789ABCDEFGHJKMNPQRS"
    private let cardDigestHex = "d0b169d2dc9b382e5292efc628c4e977f1825895f0524e8dce3d49b2956049a2"

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSince1970: 1_790_000_000)
        failures = 0
        waitUntil = nil
        policy = nil
    }

    private func makeGate() -> AdminGate {
        var seams = AdminGate.Seams()
        seams.now = { [unowned self] in self.now }
        seams.policy = { [unowned self] in self.policy }
        seams.loadFailures = { [unowned self] in self.failures }
        seams.saveFailures = { [unowned self] in self.failures = $0 }
        seams.loadWaitUntil = { [unowned self] in self.waitUntil }
        seams.saveWaitUntil = { [unowned self] in self.waitUntil = $0 }
        return AdminGate(seams: seams)
    }

    private func credentials(passcode: Bool = true, card: Bool = true) throws -> AdminCredentials {
        AdminCredentials(passcode: passcode ? .init(salt: salt, iterations: 100_000, hash: passcodeHash) : nil,
                         cardDigest: card ? try AdminSecrets.resolveCard(cardDigestHex).get() : nil)
    }

    // MARK: - The cryptography

    func testPBKDF2MatchesTheKnownVectors() {
        XCTAssertEqual(AdminSecrets.pbkdf2("password", salt: Data("salt".utf8), iterations: 1)?.hexString,
                       "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(AdminSecrets.pbkdf2("password", salt: Data("salt".utf8), iterations: 4096)?.hexString,
                       "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        XCTAssertEqual(AdminSecrets.pbkdf2("correct horse", salt: salt, iterations: 100_000), passcodeHash)
        XCTAssertNil(AdminSecrets.pbkdf2("", salt: salt, iterations: 1))
    }

    func testTheCardDigestAndReadingMatchTheScript() throws {
        XCTAssertEqual(AdminSecrets.cardDigest(secret: cardBody).hexString, cardDigestHex)
        XCTAssertEqual(AdminSecrets.cardSecret(from: "og-admin:\(cardBody.lowercased())\n"), cardBody)
        XCTAssertNil(AdminSecrets.cardSecret(from: cardBody), "no prefix, not a card")
        XCTAssertNil(AdminSecrets.cardSecret(from: "og-admin:SHORT"))
        XCTAssertNil(AdminSecrets.cardSecret(from: "og-admin:0123456789ABCDEFGHJKMNPQRU"), "U is not in the alphabet")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("Scripts/make-org-profile.swift"),
                                encoding: .utf8)
        XCTAssertTrue(script.contains("\"openglasses.admin-card.v1\\n\""))
        XCTAssertTrue(script.contains("\"\(AdminSecrets.cardPrefix)\""))
        XCTAssertTrue(script.contains("static let iterations = 210_000"))
        XCTAssertTrue(AdminSecrets.iterationRange.contains(210_000))
    }

    // MARK: - The profile fields

    private func apply(edition: String?, passcode: ConfigProfile.PasscodeVerifier? = nil,
                       card: String? = nil) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: now,
                                    leaseDays: 30, edition: edition, adminPasscode: passcode, adminCard: card)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testTheFieldAssistEditionWithItsCredentialsResolves() throws {
        let verifier = ConfigProfile.PasscodeVerifier(salt: salt.base64EncodedString(), iterations: 100_000,
                                                      hash: passcodeHash.base64EncodedString())
        let result = apply(edition: "fieldAssist", passcode: verifier, card: cardDigestHex.uppercased())
        XCTAssertEqual(result.adminPolicy, AdminPolicy(edition: .fieldAssist, credentials: try credentials()))
        XCTAssertEqual(result.adminPolicy?.credentials.method, .cardOrPasscode)
        XCTAssertTrue(result.drops.isEmpty)
    }

    func testWhatCannotBeUsedIsANamedDrop() {
        XCTAssertNil(apply(edition: "kiosk").adminPolicy)
        XCTAssertEqual(apply(edition: "kiosk").drops.map(\.key), ["edition"])

        let cheap = ConfigProfile.PasscodeVerifier(salt: salt.base64EncodedString(), iterations: 1_000,
                                                   hash: passcodeHash.base64EncodedString())
        let result = apply(edition: "fieldAssist", passcode: cheap, card: "not-a-digest")
        XCTAssertEqual(Set(result.drops.map(\.key)), ["adminPasscode", "adminCard"])
        XCTAssertEqual(result.adminPolicy?.credentials.method, .deviceOwner,
                       "with neither usable, the device owner's gate is what is left — and the review says so")

        XCTAssertEqual(Set(apply(edition: nil, card: cardDigestHex).drops.map(\.key)), ["adminCard"],
                       "a card with no edition opens nothing")
    }

    func testTheReviewSaysHowAdministratorSettingsOpen() throws {
        let verifier = ConfigProfile.PasscodeVerifier(salt: salt.base64EncodedString(), iterations: 100_000,
                                                      hash: passcodeHash.base64EncodedString())
        func lines(_ result: ProfileApplier.Result) -> [String] {
            let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Org", issued: now, leaseDays: 30)
            return OrgProfileReview(document: "", source: .link, profile: profile, result: result,
                                    replacesCurrent: false).adminLines
        }
        XCTAssertEqual(lines(apply(edition: "fieldAssist")).last,
                       "Anyone who can unlock this phone can open administrator settings")
        XCTAssertEqual(lines(apply(edition: "fieldAssist", passcode: verifier)).last,
                       "Administrator settings open with your organisation's passcode")
        XCTAssertEqual(lines(apply(edition: nil)), [])
    }

    // MARK: - Attempts and backoff

    func testTheRightPasscodeOrCardOpensTheSession() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials())
        let gate = makeGate()
        XCTAssertTrue(gate.isRestricted)
        XCTAssertEqual(gate.tryPasscode("correct horse"), .granted)
        XCTAssertFalse(gate.isRestricted)

        gate.endSession()
        XCTAssertEqual(gate.tryCard("og-admin:\(cardBody)"), .granted)
        XCTAssertTrue(gate.sessionActive)
    }

    func testFiveFreeAttemptsThenAWaitThatDoublesToAnHour() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials())
        let gate = makeGate()
        for _ in 0..<5 { XCTAssertEqual(gate.tryPasscode("wrong one"), .refused(waitUntil: nil)) }
        XCTAssertEqual(gate.tryPasscode("wrong one"), .refused(waitUntil: now.addingTimeInterval(30)))
        XCTAssertEqual(gate.tryPasscode("correct horse"), .waiting(until: now.addingTimeInterval(30)),
                       "nothing is checked during a wait, not even the right passcode")

        now = now.addingTimeInterval(31)
        XCTAssertEqual(gate.tryCard("og-admin:ZZZZZZZZZZZZZZZZZZZZZZZZZZ"), .refused(waitUntil: now.addingTimeInterval(60)),
                       "a wrong card counts the same as a wrong passcode")

        XCTAssertNil(AdminGate.wait(afterFailures: 5))
        XCTAssertEqual(AdminGate.wait(afterFailures: 6), 30)
        XCTAssertEqual(AdminGate.wait(afterFailures: 8), 120)
        XCTAssertEqual(AdminGate.wait(afterFailures: 40), 3_600)
    }

    func testTheBackoffSurvivesARelaunchAndSuccessClearsIt() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials())
        for _ in 0..<6 { _ = makeGate().tryPasscode("wrong one") }
        XCTAssertEqual(makeGate().tryPasscode("correct horse"), .waiting(until: now.addingTimeInterval(30)),
                       "a new gate — a relaunch — reads the same wait")
        now = now.addingTimeInterval(30)
        XCTAssertEqual(makeGate().tryPasscode("correct horse"), .granted)
        XCTAssertEqual(failures, 0)
        XCTAssertNil(waitUntil)
    }

    func testTextThatIsNotACardIsNotAnAttempt() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials())
        let gate = makeGate()
        XCTAssertEqual(gate.tryCard("https://example.com"), .notApplicable)
        XCTAssertEqual(failures, 0)
    }

    func testOnlyTheIssuedMethodsWork() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials(passcode: false))
        let gate = makeGate()
        XCTAssertEqual(gate.tryPasscode("correct horse"), .notApplicable, "card-only: no passcode verifier")
        XCTAssertEqual(gate.deviceOwnerPassed(), .notApplicable, "the device owner is only the fallback")

        policy = AdminPolicy(edition: .fieldAssist, credentials: AdminCredentials())
        XCTAssertEqual(gate.deviceOwnerPassed(), .granted)

        policy = nil
        let unmanaged = makeGate()
        XCTAssertFalse(unmanaged.isRestricted)
        XCTAssertEqual(unmanaged.tryPasscode("anything"), .notApplicable)
    }

    // MARK: - The session

    func testTheSessionEndsOnBackgroundOrAfterTenIdleMinutes() throws {
        policy = AdminPolicy(edition: .fieldAssist, credentials: try credentials())
        let gate = makeGate()
        XCTAssertEqual(gate.tryPasscode("correct horse"), .granted)

        now = now.addingTimeInterval(9 * 60)
        gate.noteActivity()
        now = now.addingTimeInterval(9 * 60)
        XCTAssertFalse(gate.isRestricted, "activity restarts the idle clock")

        now = now.addingTimeInterval(61)
        XCTAssertTrue(gate.isRestricted, "ten idle minutes close it")
        gate.refresh()
        XCTAssertFalse(gate.sessionActive)

        XCTAssertEqual(gate.tryPasscode("correct horse"), .granted)
        gate.handleBackground()
        XCTAssertTrue(gate.isRestricted)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
