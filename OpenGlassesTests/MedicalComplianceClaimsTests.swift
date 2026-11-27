import XCTest
@testable import OpenGlasses

/// Plan NJ §8 — Medical Compliance says only what the app does: no secure deletion, no blanket
/// "no clinical data to the cloud", agreements that name Canada and limit Local Only to AI
/// providers, the audit log on this phone while the mode is on, no New Zealand registration, My
/// Health Record registration only for those who connect, Promoting Interoperability by its
/// name, the egress wording with the record-system exception, "Medical mode" on the lock screen,
/// and the paywall's disclaimer kept.
final class MedicalComplianceClaimsTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var everyClaim: [String] {
        MedicalSafeguard.allCases.map(\.detail) + MedicalFramework.allCases.flatMap(\.organisationalRequirements)
            + MedicalFramework.allCases.map(\.summary)
    }

    func testTheRemovedClaimsAppearNowhere() {
        for claim in everyClaim {
            for gone in ["secure deletion", "overwrite before removal", "Health agency registration",
                         "Meaningful use attestation", "All data access events", "No clinical data is sent to cloud providers",
                         "to prevent clinical data from leaving the device"] {
                XCTAssertFalse(claim.localizedCaseInsensitiveContains(gone), "\(gone) in: \(claim)")
            }
        }
    }

    func testTheBareOPCDutyIsGone() {
        XCTAssertFalse(everyClaim.contains("Privacy breach reporting to OPC"))
    }

    func testDeletionSaysWhatItReaches() {
        XCTAssertTrue(MedicalSafeguard.dataRetention.detail.contains(
            "Files are deleted; flash storage cannot be overwritten; backups and shared copies are not reached."))
    }

    func testTheAuditLogIsOnThisPhoneWhileTheModeIsOn() {
        XCTAssertTrue(MedicalSafeguard.auditLog.detail.contains("on this phone, while Medical mode is on"))
        XCTAssertTrue(MedicalSafeguard.breachNotification.detail.contains("on this phone"))
    }

    func testAgreementsNameCanadaAndLimitLocalOnlyToAIProviders() {
        let detail = MedicalSafeguard.baa.detail
        XCTAssertTrue(detail.contains("Canada"))
        XCTAssertTrue(detail.contains("no AI provider receives clinical data"))
        XCTAssertTrue(detail.contains("Agreements with your record system and any other service that receives patient data still apply"))
        XCTAssertFalse(detail.contains("to avoid this requirement"))
        let baa = MedicalFramework.hipaa.organisationalRequirements[0]
        XCTAssertTrue(baa.contains("any other service that receives PHI"), baa)
    }

    func testTheRegistrationDutiesAreOnlyWhereTheyApply() {
        XCTAssertFalse(MedicalFramework.nzHIPC.organisationalRequirements.contains { $0.contains("registration") })
        let mhr = MedicalFramework.myHealthRecords.organisationalRequirements[0]
        XCTAssertTrue(mhr.contains("only if you connect to My Health Record"), mhr)
        XCTAssertTrue(MedicalFramework.hitech.organisationalRequirements.contains { $0.contains("Promoting Interoperability") })
    }

    func testTheLocalOnlyFooterSaysWhereDataStillGoes() throws {
        let view = try source("OpenGlasses/Sources/App/Views/HIPAASettingsView.swift")
        XCTAssertFalse(view.contains("No clinical data is sent to cloud providers"))
        XCTAssertTrue(view.contains("No clinical data is sent to an AI provider; it leaves the phone only to your own record system."))
        XCTAssertTrue(view.contains("on this phone, while Medical mode is on"))
    }

    func testTheEgressRefusalExceptsTheRecordSystem() {
        let refusal = MedicalEgressRefusal(route: NetworkRoute.allCases[0])
        XCTAssertTrue(refusal.description.hasSuffix("may leave this device, except to your own record system."), refusal.description)
    }

    func testTheLockScreenSaysMedicalModeNotHIPAAProtected() throws {
        let lock = try source("OpenGlasses/Sources/App/Views/BiometricLockView.swift")
        XCTAssertFalse(lock.contains("HIPAA Protected"))
        XCTAssertTrue(lock.contains("Text(\"Medical mode\")"))
    }

    func testThePaywallKeepsItsDisclaimer() throws {
        let paywall = try source("OpenGlasses/Sources/App/Views/MedicalCompliancePaywallView.swift")
        XCTAssertTrue(paywall.contains("A subscription does not certify legal compliance or clinical accuracy"))
    }

    /// CMS's Promoting Interoperability Programs page: the Medicare programme (hospitals and CAHs)
    /// and the MIPS category (clinicians) were preceded by the EHR Incentive Programs; the
    /// Medicaid programme ended on 31 December 2021. It does not call them a rename.
    func testHITECHNamesTheCurrentProgrammesAsCMSDoes() {
        let duty = MedicalFramework.hitech.organisationalRequirements
            .first { $0.contains("Promoting Interoperability") } ?? ""
        XCTAssertTrue(duty.contains("Medicare Promoting Interoperability"), duty)
        XCTAssertTrue(duty.contains("MIPS"), duty)
        XCTAssertFalse(duty.localizedCaseInsensitiveContains("meaningful use"), duty)
    }

    /// The log has no per-user or per-patient-record field, so it says neither.
    func testTheAuditLogSaysItNamesNoUserOrPatient() {
        XCTAssertTrue(MedicalSafeguard.auditLog.detail.contains("names no user or patient"))
    }

    func testTheFrameworkFooterDoesNotClaimCompliance() throws {
        let view = try source("OpenGlasses/Sources/App/Views/HIPAASettingsView.swift")
        XCTAssertFalse(view.contains("implements the technical safeguards required by these frameworks"))
        XCTAssertTrue(view.contains("It does not certify compliance."))
    }

    /// The cloud warning covers every service that holds clinical data, not only the AI provider.
    func testTheCloudWarningCoversEveryServiceThatHoldsClinicalData() throws {
        let view = try source("OpenGlasses/Sources/App/Views/HIPAASettingsView.swift")
        XCTAssertFalse(view.contains("(BAA, DPA, or equivalent) with your provider.\")"))
        XCTAssertTrue(view.contains("with your provider, and with any other service that holds clinical data for you."))
    }
}
