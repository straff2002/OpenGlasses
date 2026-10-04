import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// A manual the office assigns reaching the vault installer, headless: the in-memory transport,
/// the real assignment verifier and import preflight, and the Go golden fixtures as the office.
@MainActor
final class OfficeManualServiceTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    private typealias Service = OfficeManualService

    private var transport = OfficeManagedFolderMemoryTransport()
    private var saved = Service.Ledger()
    private var now = OfficeCheckInFixtures.now + 60
    private var bulkAllowed = false
    private var policyExpiry: Date?
    private var catalogue: [VaultPublisher] = []
    private var installed: [OfficeManualImport.Prepared] = []
    private var installFailure: Error?
    private var gateFailure: Error?

    private struct Failed: Error {}

    // MARK: - The world

    private func openFolders() async throws {
        let held = try F.held()
        let binding = try F.fields(F.payload("office-check-in-binding-v1"))
        let fields: [String: Any] = [
            "organizationID": held.organizationID, "enrolmentID": held.enrolmentID, "officeID": held.officeID,
            "generation": 1, "officeTransportID": try XCTUnwrap(binding["officeTransportID"]),
            "officeApplicationKey": held.officeApplicationKey.base64EncodedString(),
            "phoneApplicationKey": held.phoneApplicationKey.base64EncodedString(),
            "profileID": held.profileID, "bindingSHA256": held.bindingSHA256,
            "administratorKey": held.administratorKey.base64EncodedString(),
        ]
        try await transport.startFolders(
            bindingJSON: String(decoding: try JSONSerialization.data(withJSONObject: fields), as: UTF8.self),
            policy: "automatic", lanHint: "")
    }

    /// A service over `saved`, so a second one is the app launched again.
    private func makeService() -> Service {
        var seams = Service.Seams(
            transport: transport,
            held: { [unowned self] in
                if let gateFailure = self.gateFailure { throw gateFailure }
                return try F.held()
            },
            install: { [unowned self] prepared in
                if let installFailure = self.installFailure { throw installFailure }
                self.installed.append(prepared)
            })
        seams.policyExpiry = { [unowned self] in self.policyExpiry }
        seams.cataloguePublishers = { [unowned self] in self.catalogue }
        seams.bulkAllowed = { [unowned self] in self.bulkAllowed }
        // The golden receipts' own signatures for the golden payloads (CryptoKit's signatures are
        // randomised); the fixture phone key for anything else.
        seams.sign = { payload in
            guard OfficeBulk.receiptPayload(payload) != nil else {
                throw OfficePhoneIdentity.Refusal.invalidAssignmentReceipt
            }
            for outcome in ["received", "installed"] {
                let golden = try F.data("office-bulk-assignment-receipt-\(outcome)-v1")
                if payload == (try F.payload("office-bulk-assignment-receipt-\(outcome)-v1")) {
                    return try XCTUnwrap(Data(base64Encoded: F.envelope(golden).signature))
                }
            }
            return try F.phone().signature(for: OfficeBulk.receiptDomain + payload)
        }
        seams.clock = { [unowned self] in Date(timeIntervalSince1970: TimeInterval(self.now)) }
        seams.load = { [unowned self] in self.saved }
        seams.save = { [unowned self] in self.saved = $0 }
        return Service(seams: seams)
    }

    private func archive() throws -> Data { try F.file("office-bulk-vault-v1", extension: "zip") }
    private func archiveName() throws -> String { "vaults/\(OfficeBulk.digest(try archive())).zip" }

    private func identifier(_ name: String, _ field: String) throws -> String {
        try XCTUnwrap(F.fields(F.payload(name))[field] as? String)
    }

    private func officeGrants(_ grant: Data? = nil) async throws {
        await transport.put(grant: try grant ?? F.data("office-publisher-grant-v1"),
                            id: try identifier("office-publisher-grant-v1", "grantID"))
    }

    private func officeAssigns(_ assignment: Data? = nil, id: String? = nil) async throws {
        await transport.put(assignment: try assignment ?? F.data("office-bulk-assignment-v1"),
                            id: try id ?? identifier("office-bulk-assignment-v1", "assignmentID"))
    }

    private func officeOffersArchive() async throws {
        await transport.offer(bulk: try archiveName(), try archive())
    }

    private func assignment(_ change: (inout [String: Any]) -> Void,
                            by key: Curve25519.Signing.PrivateKey? = nil) throws -> Data {
        try F.changed("office-bulk-assignment-v1", domain: OfficeManualAssignment.domain,
                      by: key ?? F.office(), change)
    }

    private var assignmentID: String { (try? identifier("office-bulk-assignment-v1", "assignmentID")) ?? "" }

    // MARK: - The exit

    func testAFixtureVaultIsAssignedVerifiedInstalledAndReceipted() async throws {
        try await openFolders()
        let service = makeService()
        try await officeGrants()
        try await officeAssigns()

        // The assignment is committed and receipted before its archive is anywhere.
        try await service.sweep()
        var receipts = await transport.assignmentReceipts
        XCTAssertEqual(receipts["\(assignmentID).received"], try F.data("office-bulk-assignment-receipt-received-v1"),
                       "the golden receipt, byte for byte")
        XCTAssertNil(receipts["\(assignmentID).installed"])
        XCTAssertEqual(service.rows.map(\.state), [.waitingForOffice])
        let wanted = await transport.bulkWanted
        XCTAssertEqual(wanted.map(\.sha256), [OfficeBulk.digest(try archive())], "only the assigned archive is asked for")

        // The office puts it in the folder, and the route is not one large content uses unasked:
        // the folder stays paused and nothing is fetched.
        try await officeOffersArchive()
        try await service.sweep()
        var paused = await transport.bulkPaused
        var taken = await transport.bulkTaken
        XCTAssertTrue(paused)
        XCTAssertTrue(taken.isEmpty, "a paused archive is not fetched")
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(service.rows.map(\.state), [.waitingForWiFi])
        XCTAssertEqual(Service.status(service.rows[0]).detail, "Waiting for Wi-Fi.")

        // On a route that allows it, the archive arrives, verifies under the organisation's own
        // granted publisher, and goes to the existing installer.
        bulkAllowed = true
        now = F.now + 600
        try await service.sweep()
        XCTAssertEqual(installed.count, 1)
        let prepared = try XCTUnwrap(installed.first)
        XCTAssertEqual(prepared.manifest.id, "fixture-organisation-vault")
        XCTAssertEqual(prepared.verification,
                       .signed(publisherId: "org.fixture-organisation", publisherName: "Fixture Organisation"))
        XCTAssertEqual(prepared.archiveSHA256, OfficeBulk.digest(try archive()))
        XCTAssertNotNil(prepared.files["documents/manual.txt"])
        receipts = await transport.assignmentReceipts
        XCTAssertEqual(receipts["\(assignmentID).installed"], try F.data("office-bulk-assignment-receipt-installed-v1"))
        XCTAssertEqual(service.rows.map(\.state), [.installed])
        XCTAssertEqual(Service.status(service.rows[0]).detail, "Ready.")

        // Nothing more is asked of the folder, and another pass, or a relaunch, installs nothing.
        try await service.sweep()
        try await makeService().sweep()
        let stillWanted = await transport.bulkWanted
        paused = await transport.bulkPaused
        taken = await transport.bulkTaken
        XCTAssertTrue(stillWanted.isEmpty)
        XCTAssertTrue(paused)
        XCTAssertTrue(taken.isEmpty)
        XCTAssertEqual(installed.count, 1)
    }

    func testAnUnassignedArchiveIsNeverFetched() async throws {
        try await openFolders()
        let service = makeService()
        bulkAllowed = true
        try await officeGrants()
        try await officeOffersArchive()
        // A grant alone asks for nothing: a publisher is not an assignment.
        try await service.sweep()
        var wanted = await transport.bulkWanted
        XCTAssertTrue(wanted.isEmpty)
        XCTAssertEqual(service.ledger.grants.map(\.publisherID), ["org.fixture-organisation"])
        // An assignment for another phone, signed by the phone itself, or under another
        // generation is not this phone's, and its archive is not asked for.
        let foreign: [(String, Data)] = [
            ("another enrolment", try assignment { $0["enrolmentID"] = "another-enrolment" }),
            ("another generation", try assignment { $0["generation"] = 2 }),
            ("another office", try assignment { $0["officeID"] = "office-000000000000000000000000" }),
            ("signed by the phone", try assignment({ _ in }, by: F.phone())),
            ("over this phone's ceiling", try assignment { $0["archiveBytes"] = 300 * 1_048_576 }),
            ("not an assignment", try F.data("office-publisher-grant-v1")),
        ]
        for (name, data) in foreign {
            try await officeAssigns(data)
            try await service.sweep()
            wanted = await transport.bulkWanted
            XCTAssertTrue(wanted.isEmpty, name)
            XCTAssertTrue(service.ledger.entries.isEmpty, name)
        }
        let taken = await transport.bulkTaken
        let receipts = await transport.assignmentReceipts
        XCTAssertTrue(taken.isEmpty)
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertTrue(installed.isEmpty)
        // Each was recorded once, with a bounded reason.
        XCTAssertEqual(service.ledger.refused.count, foreign.count)
        XCTAssertTrue(service.ledger.refused.allSatisfy { $0.reason.count <= Service.maximumReasonCharacters })
    }

    // MARK: - The organisation's own publisher

    func testWithoutALiveGrantFromTheAdministratorTheVaultIsNotInstalled() async throws {
        let publisherKey = try OfficeBulkTests.publisher().publicKey.rawRepresentation.base64EncodedString()
        let revoked = try F.changed("office-publisher-grant-v1", domain: OfficeBulk.grantDomain, by: F.administrator()) {
            $0["sequence"] = 2
            $0["status"] = "revoked"
        }
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("no grant", {}),
            ("a grant the office signed", { [unowned self] in
                try await self.officeGrants(F.signed(F.payload("office-publisher-grant-v1"),
                                                     domain: OfficeBulk.grantDomain, by: F.office()))
            }),
            ("a grant the publisher signed for itself", { [unowned self] in
                try await self.officeGrants(F.signed(F.payload("office-publisher-grant-v1"),
                                                     domain: OfficeBulk.grantDomain, by: OfficeBulkTests.publisher()))
            }),
            ("a revoked grant", { [unowned self] in try await self.officeGrants(revoked) }),
            ("a grant past the profile's own term", { [unowned self] in
                try await self.officeGrants()
                self.policyExpiry = Date(timeIntervalSince1970: TimeInterval(F.now))
            }),
            // The vendor's catalogue never speaks for an organisation's own prefix, even with
            // the right key.
            ("the same key listed in the catalogue instead", { [unowned self] in
                self.catalogue = [VaultPublisher(id: "org.fixture-organisation", name: "Fixture Organisation",
                                                 publicKey: publisherKey)]
            }),
        ]
        for (name, arrange) in cases {
            // A fresh phone and office for each.
            transport = OfficeManagedFolderMemoryTransport()
            saved = Service.Ledger()
            installed = []
            policyExpiry = nil
            catalogue = []
            try await openFolders()
            bulkAllowed = true
            try await arrange()
            try await officeAssigns()
            try await officeOffersArchive()
            let service = makeService()
            try await service.sweep()
            XCTAssertTrue(installed.isEmpty, name)
            XCTAssertEqual(service.rows.map(\.state),
                           [.notInstalled("The manual isn't signed by a publisher this phone can check.")], name)
            let receipts = await transport.assignmentReceipts
            XCTAssertNotNil(receipts["\(assignmentID).received"], name)
            XCTAssertNil(receipts["\(assignmentID).installed"], "\(name): no receipt says installed")
            // Recorded once: another pass does not try again.
            try await service.sweep()
            XCTAssertTrue(installed.isEmpty, name)
        }
    }

    func testARevocationReplacesAGrantAndTheGrantNeverComesBack() async throws {
        try await openFolders()
        let service = makeService()
        try await officeGrants()
        try await service.sweep()
        XCTAssertEqual(service.ledger.grants.map(\.sequence), [1])
        let revoked = try F.changed("office-publisher-grant-v1", domain: OfficeBulk.grantDomain, by: F.administrator()) {
            $0["sequence"] = 2
            $0["status"] = "revoked"
        }
        try await officeGrants(revoked)
        try await service.sweep()
        XCTAssertEqual(service.ledger.grants.map(\.sequence), [2])
        // The earlier grant is put back in the folder: it does not replace the revocation.
        try await officeGrants()
        try await service.sweep()
        XCTAssertEqual(service.ledger.grants.map(\.sequence), [2])
        XCTAssertEqual(service.ledger.grants.first?.envelope, revoked)
        XCTAssertEqual(service.ledger.refused.count, 1)
    }

    // MARK: - A set only moves forward

    func testALaterAssignmentReplacesOneThatNeverInstalledAndAnEarlierOneIsNeverTakenAgain() async throws {
        try await openFolders()
        let service = makeService()
        bulkAllowed = true
        try await officeGrants()
        // Sequence 2 for the set arrives first.
        let laterID = String(repeating: "b", count: 32)
        let later = try assignment {
            $0["assignmentID"] = laterID
            $0["sequence"] = 2
        }
        try await officeAssigns(later, id: laterID)
        try await service.sweep()
        XCTAssertEqual(service.ledger.entries.map(\.sequence), [2])
        // Then the golden sequence 1: a rollback, refused, and never asked for.
        try await officeAssigns()
        try await service.sweep()
        XCTAssertEqual(service.ledger.entries.map(\.sequence), [2])
        // Other bytes at the sequence already held are a conflict.
        let conflictID = String(repeating: "c", count: 32)
        try await officeAssigns(try assignment {
            $0["assignmentID"] = conflictID
            $0["sequence"] = 2
            $0["vaultVersion"] = "9.9.9"
        }, id: conflictID)
        try await service.sweep()
        XCTAssertEqual(service.ledger.entries.map(\.assignmentID), [laterID])
        XCTAssertEqual(service.ledger.refused.count, 2)

        // Sequence 3 replaces sequence 2, which never installed.
        let newestID = String(repeating: "d", count: 32)
        try await officeAssigns(try assignment {
            $0["assignmentID"] = newestID
            $0["sequence"] = 3
        }, id: newestID)
        try await officeOffersArchive()
        try await service.sweep()
        XCTAssertEqual(service.ledger.entries.map(\.state), [.refused, .installed])
        XCTAssertEqual(installed.count, 1)
        let receipts = await transport.assignmentReceipts
        XCTAssertNotNil(receipts["\(newestID).installed"])
        XCTAssertNil(receipts["\(laterID).installed"])

        // The record of entries is lost, the set's mark is not: the same assignment again is not
        // taken a second time, so a manual the technician removed is not brought back.
        saved.entries = []
        let relaunched = makeService()
        try await relaunched.sweep()
        XCTAssertTrue(relaunched.ledger.entries.isEmpty)
        XCTAssertEqual(installed.count, 1)
    }

    // MARK: - What does not install

    func testAnInstallThatFailsIsRecordedOnceAndGetsNoFurtherReceipt() async throws {
        try await openFolders()
        let service = makeService()
        bulkAllowed = true
        installFailure = Failed()
        try await officeGrants()
        try await officeAssigns()
        try await officeOffersArchive()
        try await service.sweep()
        XCTAssertEqual(service.rows.map(\.state), [.notInstalled("The manual couldn't be installed on this phone.")])
        installFailure = nil
        try await service.sweep()
        XCTAssertTrue(installed.isEmpty, "not retried until the office assigns again")
        let receipts = await transport.assignmentReceipts
        XCTAssertEqual(Array(receipts.keys), ["\(assignmentID).received"])
    }

    func testAnAssignmentThatRunsOutBeforeItsManualArrivesIsNotInstalled() async throws {
        try await openFolders()
        let service = makeService()
        try await officeGrants()
        try await officeAssigns()
        try await service.sweep()
        // Eight days on, the archive finally arrives: the assignment was good for seven.
        bulkAllowed = true
        now = F.now + 8 * 86_400
        try await officeOffersArchive()
        try await service.sweep()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(service.rows.map(\.state), [.notInstalled(
            "The assignment ran out before the manual arrived. The office can assign it again.")])
    }

    func testNothingIsTakenInOnAPairingThatDoesNotVerify() async throws {
        try await openFolders()
        let service = makeService()
        try await officeGrants()
        try await officeAssigns()
        gateFailure = OfficePairingService.Refusal.inactiveLease
        do {
            try await service.sweep()
            XCTFail("an assignment was taken in on a lapsed lease")
        } catch {
            XCTAssertEqual(error as? OfficePairingService.Refusal, .inactiveLease)
        }
        XCTAssertTrue(service.ledger.entries.isEmpty)
        XCTAssertTrue(service.ledger.grants.isEmpty)
        let receipts = await transport.assignmentReceipts
        XCTAssertTrue(receipts.isEmpty)
    }

    func testLargeContentMovesOnlyStraightToTheOfficeOnANetworkThatIsNotMetered() {
        XCTAssertTrue(Service.bulkAllowed(route: .direct, expensive: false))
        XCTAssertFalse(Service.bulkAllowed(route: .direct, expensive: true))
        XCTAssertFalse(Service.bulkAllowed(route: .relay, expensive: false))
        XCTAssertFalse(Service.bulkAllowed(route: .relay, expensive: true))
    }

    func testNothingSaysDeliveredForAFinishedTransfer() {
        let states: [Service.Row.State] = [.waitingForOffice, .waitingForWiFi, .downloading, .installed, .notInstalled("")]
        for state in states {
            let status = Service.status(.init(id: "a", vaultID: "vault", vaultVersion: "1.0", state: state))
            let words = (status.title + " " + (status.detail ?? "")).lowercased()
            for claim in ["delivered", "sent", "missing"] { XCTAssertFalse(words.contains(claim), words) }
        }
    }

    func testTheRecordSurvivesAFileRoundTrip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("manuals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(Service.readLedger(file), Service.Ledger())
        var ledger = Service.Ledger()
        ledger.highWater["scope"] = .init(generation: 1, sequence: 3, payloadSHA256: "abc")
        try Service.writeLedger(ledger, to: file)
        XCTAssertEqual(Service.readLedger(file), ledger)
    }
}
