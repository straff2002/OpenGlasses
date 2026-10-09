import XCTest
@testable import OpenGlasses

/// Plan FP P1 — what the capture-time redaction does, and what it provably does not.
///
/// `SecretPatterns` carries eight credential patterns and exactly two PII ones: an email address
/// and a dash-grouped IRD number. That is the whole of it. These tests pin both halves: the two
/// identifiers that are masked are masked and named, and a customer's name and street address go
/// straight through — asserted, not assumed, so nobody reads "redacted at capture" as "safe to
/// publish". That gap is why the tool speaks the standing rule with every filing and why review,
/// not redaction, is where a name is caught.
@MainActor
final class TeamLearningRedactionTests: XCTestCase {

    private var root: URL!
    private var sessions: FieldSessionService!
    private var store: LearningCandidateStore!
    private var tool: TeamLearningTool!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLearningRedaction-\(UUID().uuidString)", isDirectory: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant(tier: .team)
        VaultRegistry.shared.resetCache()
        sessions = FieldSessionService(sessionsRoot: root.appendingPathComponent("sessions", isDirectory: true))
        store = LearningCandidateStore(directory: root.appendingPathComponent("store", isDirectory: true))
        let service = LearningCandidateService(store: store, sessions: sessions)
        service.authorName = { "Sam Tane" }
        tool = TeamLearningTool(service: service)
    }

    override func tearDown() {
        tool = nil
        store = nil
        sessions = nil
        try? FileManager.default.removeItem(at: root)
        if let previousEnabled { UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled") }
        else { UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled") }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    private static let email = "jo.bloggs@example.com"
    private static let ird = "123-456-789"

    func testAnEmailAddressAndAnIRDNumberAreMaskedAndNamed() async throws {
        try sessions.startSession(vaultId: "refrigeration", assetId: nil)
        let spoken = try await tool.execute(args: [
            "action": "note",
            "finding": "The rep at \(Self.email) confirmed account \(Self.ird) has the board that fails when the tubing sweats"
        ])

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertFalse(candidate.finding.contains(Self.email))
        XCTAssertFalse(candidate.finding.contains(Self.ird))
        XCTAssertEqual(candidate.finding.components(separatedBy: SecretPatterns.redactionPlaceholder).count - 1, 2)
        XCTAssertTrue(candidate.finding.hasSuffix("has the board that fails when the tubing sweats"),
                      "redaction masks the match and leaves the rest of the sentence as it was")
        XCTAssertEqual(candidate.redactions, ["email", "nz_ird"], "the patterns' names, in SecretPatterns order")

        // The technician hears what was kept, which is the masked text — and what was masked.
        XCTAssertTrue(spoken.contains(SecretPatterns.redactionPlaceholder), spoken)
        XCTAssertFalse(spoken.contains(Self.email), spoken)
        XCTAssertFalse(spoken.contains(Self.ird), spoken)
        XCTAssertTrue(spoken.contains("I masked an email address and an IRD number."), spoken)

        // The names, never the matched text: not on the record, not in the file on disk.
        let onDisk = try String(contentsOf: store.fileLocation, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(Self.email))
        XCTAssertFalse(onDisk.contains(Self.ird))
        XCTAssertTrue(onDisk.contains("\"nz_ird\""))
    }

    func testSymptomAndFixAreRedactedAndTheNamesAreUnioned() async throws {
        try sessions.startSession(vaultId: "refrigeration", assetId: nil)
        _ = try await tool.execute(args: [
            "action": "note",
            "finding": "Account \(Self.ird) unit trips on a cold start",
            "symptom": "Lockout reported by \(Self.email)",
            "fix": "Ask \(Self.email) for the warranty"
        ])
        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(candidate.redactions, ["email", "nz_ird"],
                       "each pattern once, in SecretPatterns order, whichever field it fired in")
        XCTAssertFalse((candidate.symptom ?? "").contains(Self.email))
        XCTAssertFalse((candidate.fix ?? "").contains(Self.email))

        // An amendment is redacted again, and the record names what fires in what is now stored.
        _ = try await tool.execute(args: ["action": "amend", "finding": "Unit trips on a cold start",
                                          "symptom": "Lockout on first call", "fix": "Re-route the tubing"])
        XCTAssertEqual(store.candidates.first?.redactions, [])
    }

    /// The gap, pinned. A customer's name and a street address are not secrets and not one of the
    /// two PII shapes `SecretPatterns` knows, so they survive capture word for word. This is the
    /// reason the tool says "no customer names or addresses" every time, and the reason the
    /// supervisor's review — not this pass — is the privacy control.
    func testACustomerNameAndAStreetAddressSurviveRedaction() async throws {
        try sessions.startSession(vaultId: "refrigeration", assetId: nil)
        let customer = "Mrs Aroha Henderson"
        let address = "14 Kowhai Street, Ponsonby"
        let spoken = try await tool.execute(args: [
            "action": "note",
            "finding": "\(customer) at \(address) has the 090 whose tubing sweats on a cold start"
        ])

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertTrue(candidate.finding.contains(customer),
                      "redaction is a floor, not a privacy control: it does not know what a name is")
        XCTAssertTrue(candidate.finding.contains(address),
                      "nor a street address — review is where these are removed")
        XCTAssertEqual(candidate.redactions, [], "nothing fired, and the record says so rather than implying it was cleaned")
        XCTAssertTrue(spoken.contains(TeamLearningTool.standingRule),
                      "because redaction cannot catch this, the rule is spoken with every filing")
        XCTAssertTrue(TeamLearningTool().description.contains("Never put customer names, addresses"),
                      "and the model is told the same rule before it ever writes a finding")
    }
}
