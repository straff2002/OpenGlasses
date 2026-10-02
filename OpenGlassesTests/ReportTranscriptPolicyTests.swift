import XCTest
@testable import OpenGlasses

/// Plan HD — who a job report is for, and what of the conversation it carries. Every row of the
/// plan's table, decided from values.
final class ReportTranscriptPolicyTests: XCTestCase {

    private let office = ["office@northbridge.example", "+64 21 000 000"]

    private func decide(_ channel: DeliveryChannel, _ recipients: [String],
                        carriesFiles: Bool = true,
                        organisation: ReportTranscriptPolicy.Organisation = .init(),
                        choice: ReportTranscriptPolicy.Choice = .standard) -> ReportTranscriptPolicy.Decision {
        ReportTranscriptPolicy.decide(
            channel: channel, recipients: recipients, carriesFiles: carriesFiles,
            context: .init(officeAddresses: office, organisation: organisation), choice: choice)
    }

    // MARK: - Audience

    func testTheConfiguredOfficeAddressIsTheOffice() {
        let decision = decide(.email, ["office@northbridge.example"])
        XCTAssertEqual(decision.audience, .office)
        XCTAssertEqual(decision.source, .configuredAddresses)
        XCTAssertTrue(decision.jsonIncludesTranscript)
        XCTAssertNil(decision.omittedReason)
        XCTAssertEqual(decision.transcriptPDF, .available(on: false), "the PDF is off until asked for")
        XCTAssertFalse(decision.offersOfficeOptIn, "nothing to opt into — it is already the office")
    }

    func testAddressesCompareWithoutCaseAndNumbersByTheirDigits() {
        XCTAssertEqual(decide(.email, ["  Office@Northbridge.EXAMPLE "]).audience, .office)
        XCTAssertEqual(decide(.messages, ["+6421000000"]).audience, .office)
        XCTAssertEqual(decide(.messages, ["+64 (21) 000-000"]).audience, .office)
    }

    func testOneUnknownAddressMakesTheWholeReportACustomers() {
        let decision = decide(.email, ["office@northbridge.example", "dave@customer.example"])
        XCTAssertEqual(decision.audience, .customer)
        XCTAssertEqual(decision.source, .unknownAddress)
        XCTAssertFalse(decision.jsonIncludesTranscript)
        XCTAssertEqual(decision.omittedReason, .customerDestination)
        XCTAssertEqual(decision.transcriptPDF, .unavailable(reason: ReportTranscriptPolicy.customerReason))
        XCTAssertFalse(decision.transcriptPDF.isEditable)
        XCTAssertTrue(decision.transcriptPDF.isShown, "shown disabled, with the reason")
    }

    func testNobodyChosenIsACustomer() {
        let decision = decide(.email, [])
        XCTAssertEqual(decision.audience, .customer)
        XCTAssertEqual(decision.source, .noRecipient)
    }

    func testTheShareSheetIsACustomerUnlessTheTechnicianSaysOtherwise() {
        let unknown = decide(.shareSheet, [])
        XCTAssertEqual(unknown.audience, .customer)
        XCTAssertEqual(unknown.source, .shareSheet)
        XCTAssertTrue(unknown.offersOfficeOptIn)
        XCTAssertNotNil(unknown.officeOptInFooter)

        let marked = decide(.shareSheet, [], choice: .init(markedAsOffice: true))
        XCTAssertEqual(marked.audience, .office)
        XCTAssertEqual(marked.source, .markedByTechnician)
        XCTAssertTrue(marked.jsonIncludesTranscript)
        XCTAssertEqual(marked.transcriptPDF, .available(on: false))
        XCTAssertTrue(marked.offersOfficeOptIn, "still offered, so it can be taken back")
    }

    func testTheEndpointIsTheOfficeAndCarriesNoFile() {
        let decision = decide(.endpoint, [], carriesFiles: false)
        XCTAssertEqual(decision.audience, .office)
        XCTAssertEqual(decision.source, .endpoint)
        XCTAssertFalse(decision.transcriptPDF.isShown)
        XCTAssertNil(decision.dataFileLine, "no JSON travels to describe")
        XCTAssertEqual(decision.auditTranscript, [], "the endpoint takes the work record, which has no transcript")
    }

    func testAChannelThatCarriesNoFileHidesTheToggleWithItsReason() {
        let whatsapp = decide(.whatsapp, ["+6421000000"], carriesFiles: false,
                              choice: .init(attachTranscript: true))
        XCTAssertEqual(whatsapp.transcriptPDF,
                       .hidden(reason: "WhatsApp can't carry a file, so only the summary goes."))
        XCTAssertFalse(whatsapp.attachesTranscriptPDF)
        XCTAssertFalse(whatsapp.offersOfficeOptIn)

        let messages = decide(.messages, ["+6421000000"], carriesFiles: false)
        XCTAssertEqual(messages.transcriptPDF.note,
                       "This phone can't attach a file to a message, so only the summary goes.")
    }

    // MARK: - The technician's choice

    func testTheTranscriptPDFGoesOnlyWhenAskedForAndOnlyToTheOffice() {
        let office = decide(.email, ["office@northbridge.example"], choice: .init(attachTranscript: true))
        XCTAssertTrue(office.attachesTranscriptPDF)
        XCTAssertEqual(office.auditTranscript, ["json", "pdf"])
        XCTAssertEqual(office.transcriptPDF.note, ReportTranscriptPolicy.attachedNote)

        let customer = decide(.email, ["dave@customer.example"], choice: .init(attachTranscript: true))
        XCTAssertFalse(customer.attachesTranscriptPDF, "a stale choice never sends it to a customer")
        XCTAssertFalse(customer.carriesTranscript)
        XCTAssertEqual(customer.auditTranscript, [])
    }

    // MARK: - The organisation

    func testAlwaysAttachesTheTranscriptToTheOfficeAndLocksTheToggle() {
        let decision = decide(.email, ["office@northbridge.example"],
                              organisation: .init(internalRule: .always))
        XCTAssertEqual(decision.transcriptPDF, .lockedOn(reason: ReportTranscriptPolicy.alwaysReason))
        XCTAssertTrue(decision.attachesTranscriptPDF)
        XCTAssertTrue(decision.jsonIncludesTranscript)

        let customer = decide(.email, ["dave@customer.example"], organisation: .init(internalRule: .always))
        XCTAssertFalse(customer.attachesTranscriptPDF, "always means the office, never a customer")
    }

    func testNeverKeepsTheTranscriptOutEvenForTheOffice() {
        let decision = decide(.email, ["office@northbridge.example"],
                              organisation: .init(internalRule: .never),
                              choice: .init(attachTranscript: true))
        XCTAssertEqual(decision.audience, .office)
        XCTAssertFalse(decision.jsonIncludesTranscript)
        XCTAssertEqual(decision.omittedReason, .organisationPolicy)
        XCTAssertEqual(decision.transcriptPDF, .lockedOff(reason: ReportTranscriptPolicy.neverReason))
        XCTAssertFalse(decision.carriesTranscript)
    }

    func testForbiddingCustomerTranscriptsWithdrawsTheOfficeOptIn() {
        let forbid = ReportTranscriptPolicy.Organisation(forbidsCustomerTranscript: true)
        let decision = decide(.shareSheet, [], organisation: forbid,
                              choice: .init(markedAsOffice: true, attachTranscript: true))
        XCTAssertEqual(decision.audience, .customer, "only configured destinations count")
        XCTAssertFalse(decision.offersOfficeOptIn)
        XCTAssertTrue(decision.officeOptInWithdrawn)
        XCTAssertEqual(decision.officeOptInFooter,
                       "Your organisation sends transcripts only to the office addresses it set up.")
        XCTAssertFalse(decision.carriesTranscript)

        let configured = decide(.email, ["office@northbridge.example"], organisation: forbid)
        XCTAssertEqual(configured.audience, .office, "the configured office is unaffected")
        XCTAssertFalse(configured.officeOptInWithdrawn)
    }

    func testWithoutAProfileTheOfficeGetsItAndTheCustomerDoesNot() {
        XCTAssertTrue(decide(.email, ["office@northbridge.example"]).jsonIncludesTranscript)
        XCTAssertFalse(decide(.email, ["dave@customer.example"]).jsonIncludesTranscript)
    }

    // MARK: - Archive and copy

    func testAnArchiveExportIsTheOfficesUnderThePolicy() {
        let plain = ReportTranscriptPolicy.archive(context: .init())
        XCTAssertTrue(plain.jsonIncludesTranscript)
        XCTAssertFalse(plain.attachesTranscriptPDF)

        let never = ReportTranscriptPolicy.archive(
            context: .init(organisation: .init(internalRule: .never)))
        XCTAssertFalse(never.jsonIncludesTranscript)
        XCTAssertEqual(never.omittedReason, .organisationPolicy)
    }

    func testTheDataFileLineSaysWhatTheJSONCarries() {
        XCTAssertEqual(decide(.email, ["office@northbridge.example"]).dataFileLine,
                       "The work order never includes what was said. The data file (JSON) does, for your office.")
        XCTAssertEqual(decide(.email, ["dave@customer.example"]).dataFileLine,
                       "Neither the work order nor the data file includes what was said.")
    }

    func testNoPlanLettersInTheCopy() {
        let decisions = [decide(.email, ["office@northbridge.example"]), decide(.shareSheet, []),
                         decide(.endpoint, [], carriesFiles: false),
                         decide(.email, ["x@y.example"], organisation: .init(forbidsCustomerTranscript: true))]
        for decision in decisions {
            let copy = [decision.audienceLine, decision.officeOptInFooter ?? "",
                        decision.dataFileLine ?? "", decision.transcriptPDF.note].joined(separator: " ")
            XCTAssertFalse(copy.contains("Plan "), copy)
        }
    }
}

/// The organisation's two keys, through the real applier and the envelope `Config` reads.
final class ReportTranscriptProfileTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PolicyEnvelope.clear()
    }

    override func tearDown() {
        PolicyEnvelope.clear()
        super.tearDown()
    }

    private func apply(_ settings: [String: RawSetting]) -> ProfileApplier.Result {
        let profile = ConfigProfile(keyId: "k", profileId: "p", organizationName: "Northbridge Mechanical",
                                    issued: Date(), leaseDays: 30, settings: settings)
        return ProfileApplier.apply(profile: profile, resolvableVaultIds: [])
    }

    func testTheInternalRuleIsProfileOwnedAndTakesOnlyItsTwoValues() {
        XCTAssertEqual(SettingKey.organizationReportTranscriptInternal.kind, .profileOwned(.string))
        for raw in ["always", "never"] {
            let result = apply(["organizationReportTranscriptInternal": RawSetting(.string(raw), .default)])
            XCTAssertEqual(result.owned[.organizationReportTranscriptInternal], .string(raw))
            XCTAssertTrue(result.drops.isEmpty, raw)
        }
        let result = apply(["organizationReportTranscriptInternal": RawSetting(.string("sometimes"), .default)])
        XCTAssertNil(result.owned[.organizationReportTranscriptInternal])
        XCTAssertEqual(result.drops, [.init(key: "organizationReportTranscriptInternal",
                                            reason: .invalidValue("not one of always or never"))])
    }

    func testForbiddingCustomerTranscriptsIsACeilingPinnedOn() {
        XCTAssertEqual(SettingKey.organizationForbidsCustomerTranscript.kind, .ceiling(pinnedTo: true))
        let widened = apply(["organizationForbidsCustomerTranscript": RawSetting(.bool(false), .ceiling)])
        XCTAssertEqual(widened.drops, [.init(key: "organizationForbidsCustomerTranscript",
                                             reason: .wrongDirection)])
    }

    func testConfigReadsBothThroughTheEnvelope() {
        XCTAssertNil(Config.organizationReportTranscriptInternal)
        XCTAssertFalse(Config.organizationForbidsCustomerTranscript)

        PolicyEnvelope.install(apply([
            "organizationReportTranscriptInternal": RawSetting(.string("never"), .default),
            "organizationForbidsCustomerTranscript": RawSetting(.bool(true), .ceiling)
        ]), organizationName: "Northbridge Mechanical")

        XCTAssertEqual(Config.organizationReportTranscriptInternal, .never)
        XCTAssertTrue(Config.organizationForbidsCustomerTranscript)
        let context = ReportTranscriptPolicy.Context.current(
            settings: DeliverySettings(emailRecipients: ["office@northbridge.example"]))
        XCTAssertEqual(context.organisation, .init(internalRule: .never, forbidsCustomerTranscript: true))
        XCTAssertTrue(context.officeAddresses.contains("office@northbridge.example"))
    }

    func testTheReviewSheetNamesBothKeys() {
        XCTAssertNotEqual(SettingKey.organizationReportTranscriptInternal.ownedDescription,
                          "organizationReportTranscriptInternal")
        XCTAssertNotEqual(SettingKey.organizationForbidsCustomerTranscript.ceilingDescription,
                          "organizationForbidsCustomerTranscript")
    }
}
