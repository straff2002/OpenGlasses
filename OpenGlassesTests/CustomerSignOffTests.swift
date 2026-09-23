import PDFKit
import XCTest
@testable import OpenGlasses

/// Customer sign-off at the end of a job (Plan FO P2c).
///
/// A real `FieldSessionService` in a temp directory throughout, because what is being asserted is
/// mostly about *what lands on the record and on disk* — and a fake service would prove nothing
/// about either. The PDF assertions read the produced document with PDFKit and `CGPDFDocument`,
/// the way `EvidenceExportTests` does: a test that counted draw calls would pass just as happily
/// if the signature never reached the page.
@MainActor
final class CustomerSignOffTests: XCTestCase {

    private static let vaultId = "refrigeration"

    /// Tokens that appear **only** in the job's internal content. Asserting on these rather than on
    /// a query word is the point: "note" or "fault" would match a task title by accident, and the
    /// test would pass for the wrong reason.
    private enum Internal {
        static let why = "ZQCANDIDATEPRESSURESWITCH"
        static let completionNote = "ZQTECHNICIANNOTE"
        static let citation = "ZQCITATIONSOURCE"
        static let page = "ZQPAGEVERIFIED"
        static let escalation = "ZQESCALATIONREASON"
        static let photoCaption = "ZQPHOTOCAPTION"
        /// Stands in for a debrief item until Plan FO P3b adds one — written into the same field a
        /// debrief addendum would extend, so the assertion keeps its meaning when it does.
        static let debrief = "ZQDEBRIEFFORBASE"
        static let all = [why, completionNote, citation, page, escalation, photoCaption, debrief]
    }

    private var sessionsRoot: URL!
    private var service: FieldSessionService!
    private var previousEntitlement: FieldAssistEntitlementProvider!
    private var previousEnabled: Any?
    private var previousRequired: Any?

    override func setUp() {
        super.setUp()
        sessionsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignOff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        previousEnabled = UserDefaults.standard.object(forKey: "fieldAssistEnabled")
        previousRequired = UserDefaults.standard.object(forKey: "organizationRequiresCustomerSignOff")
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        UserDefaults.standard.removeObject(forKey: "organizationRequiresCustomerSignOff")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        service = FieldSessionService(sessionsRoot: sessionsRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sessionsRoot)
        if let previousEnabled {
            UserDefaults.standard.set(previousEnabled, forKey: "fieldAssistEnabled")
        } else {
            UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        }
        if let previousRequired {
            UserDefaults.standard.set(previousRequired, forKey: "organizationRequiresCustomerSignOff")
        } else {
            UserDefaults.standard.removeObject(forKey: "organizationRequiresCustomerSignOff")
        }
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// One job carrying every kind of internal content there is a field for today, plus the three
    /// things a customer summary is made of: a completed task, a part on it, and time.
    ///
    /// Written through the service's own API, so what the record is derived from is what a real
    /// visit leaves behind rather than a hand-assembled struct.
    @discardableResult
    private func startJobWithInternalContent() throws -> FieldSession {
        let session = try service.startSession(vaultId: Self.vaultId, assetId: nil,
                                               mode: .aiOnly, jobReference: "1005")
        let task = try service.proposeTask(
            title: "Replaced the condensate trap",
            why: Internal.why,
            parts: [TaskPart(number: "14T65", partDescription: "Condensate trap",
                             verified: true, page: Internal.page)],
            citation: Internal.citation)
        _ = try service.decideTask(id: task.id, decision: .accept)
        _ = try service.startTask(id: task.id)
        service.logPageVerified(title: Internal.page, page: 39, source: .extractedText)
        service.attachPhoto(signature(), caption: Internal.photoCaption, origin: .photoLog,
                            filterWasOn: true)
        _ = try service.completeTask(id: task.id, note: Internal.completionNote)

        // A recommendation nobody acted on: internal in a second way — a customer is not being
        // asked to agree to work that did not happen.
        let declined = try service.proposeTask(title: "ZQRECOMMENDEDNOTDONE", why: Internal.debrief,
                                               citation: Internal.citation)
        _ = try service.decideTask(id: declined.id, decision: .decline)
        service.recordEscalation(reason: Internal.escalation)
        return session
    }

    private func record() throws -> WorkRecord {
        try XCTUnwrap(service.workRecord())
    }

    /// A signature picture with two distinct blocks of colour, so a PDF writer cannot fold it into
    /// another embedded image.
    private func signature(_ hue: CGFloat = 0.55) -> Data {
        let size = CGSize(width: 480, height: 160)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: hue, saturation: 0.9, brightness: 0.4, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 40, width: 200, height: 40))
        }
    }

    private func sessionDirectory(_ id: String) -> URL {
        sessionsRoot.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - The summary, and the digest over it

    func testTheDigestIsTakenOverExactlyTheLinesThatWereShown() throws {
        try startJobWithInternalContent()
        let lines = try record().customerSummaryLines
        let signOff = CustomerSignOff(customerName: "Dana Okafor", method: .typed,
                                      summaryLines: lines)

        XCTAssertEqual(signOff.summaryDigest, CustomerSignOff.digest(of: lines))
        XCTAssertTrue(signOff.digestMatchesSummary)
        // And it is genuinely over the text, not over a count or an id.
        XCTAssertNotEqual(CustomerSignOff.digest(of: lines),
                          CustomerSignOff.digest(of: lines + ["and one more thing"]))
        XCTAssertNotEqual(CustomerSignOff.digest(of: ["a", "b"]),
                          CustomerSignOff.digest(of: ["b", "a"]),
                          "the digest must depend on the order the lines were read in")
    }

    /// The whole reason the customer summary is a separate derivation: none of the job's internal
    /// content may reach a page somebody is asked to put their name to.
    func testTheCustomerSummaryLeavesEveryPieceOfInternalContentBehind() throws {
        try startJobWithInternalContent()
        let record = try record()
        let customer = CustomerSummary.text(for: record)
        let whole = record.summary

        for token in Internal.all {
            XCTAssertFalse(customer.contains(token),
                           "\(token) reached the customer summary")
        }
        // The fixture is only worth anything if the internal content is really there: three of
        // these are printed by the work record the customer summary is derived from.
        XCTAssertTrue(whole.contains(Internal.completionNote))
        XCTAssertTrue(whole.contains(Internal.why))
        XCTAssertTrue(whole.contains(Internal.escalation))

        // …and the three things that *do* belong are all present.
        XCTAssertTrue(customer.contains("Replaced the condensate trap"))
        XCTAssertTrue(customer.contains("14T65"))
        XCTAssertTrue(customer.contains("Time on the job"))
        // Work that was recommended and not done is not something to sign off either.
        XCTAssertFalse(customer.contains("ZQRECOMMENDEDNOTDONE"))
    }

    func testAJobBilledInUnitsSignsForUnitsRatherThanMinutes() throws {
        try startJobWithInternalContent()
        var session = try XCTUnwrap(service.activeSession)
        session.billingBasis = .units
        session.minutesPerBillingUnit = 15
        session.billableSeconds = 20 * 60
        let customer = CustomerSummary.text(for: WorkRecord(session: session,
                                                            vaultName: "Refrigeration"))
        XCTAssertTrue(customer.contains("Billable units"))
        XCTAssertFalse(customer.contains("Time on the job"))
    }

    // MARK: - The four answers, recorded honestly

    func testSkippingLeavesNoSignOffOnTheRecordAtAll() throws {
        try startJobWithInternalContent()
        let closed = try service.endSession(outcome: .resolved)
        XCTAssertNil(closed.signOff, "skipping the step must not fabricate an acceptance")
        XCTAssertNil(WorkRecord(session: closed, vaultName: "Refrigeration").signOff)
    }

    func testATypedNameIsRecordedAsTypedAndCarriesNoPicture() throws {
        try startJobWithInternalContent()
        let lines = try record().customerSummaryLines
        let written = try XCTUnwrap(service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", method: .typed, summaryLines: lines)))

        XCTAssertEqual(written.method, .typed)
        XCTAssertNil(written.signatureImageId)
        XCTAssertNil(written.strokeDataId)
        XCTAssertTrue(written.isAccepted)
        XCTAssertEqual(service.activeSession?.signOff, written)
    }

    func testADrawnSignatureIsRecordedAsDrawnAndItsFilesAreUnderTheSession() throws {
        let session = try startJobWithInternalContent()
        let lines = try record().customerSummaryLines
        let written = try XCTUnwrap(service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", method: .drawn, summaryLines: lines),
            pngData: signature(), strokeData: Data("strokes".utf8)))

        XCTAssertEqual(written.method, .drawn)
        let imageId = try XCTUnwrap(written.signatureImageId)
        let strokeId = try XCTUnwrap(written.strokeDataId)
        let photos = service.photosDirectory(sessionId: session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photos.appendingPathComponent(imageId).path),
                      "the signature must be filed under the session's own store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photos.appendingPathComponent(strokeId).path))
        XCTAssertEqual(service.signatureURL(sessionId: session.id, imageId: imageId),
                       photos.appendingPathComponent(imageId))
    }

    /// A signature is not a photograph. It must not appear in the evidence catalogue, where it
    /// would be offered to a customer's report as a picture of the job.
    func testASignatureNeverJoinsTheJobsEvidence() throws {
        try startJobWithInternalContent()
        let before = service.jobMedia.count
        service.recordSignOff(
            CustomerSignOff(customerName: "Dana", method: .drawn,
                            summaryLines: try record().customerSummaryLines),
            pngData: signature())
        XCTAssertEqual(service.jobMedia.count, before)
    }

    func testADeclineIsRecordedAsADeclineWithItsReason() throws {
        try startJobWithInternalContent()
        let written = try XCTUnwrap(service.recordSignOff(
            CustomerSignOff(customerName: "", method: .declined,
                            declinedReason: "The customer had left site.",
                            summaryLines: try record().customerSummaryLines)))

        XCTAssertEqual(written.method, .declined)
        XCTAssertFalse(written.isAccepted)
        XCTAssertEqual(written.declinedReason, "The customer had left site.")
        XCTAssertEqual(written.attributionLine(formatter: Self.fixedFormatter).hasPrefix("No name given"),
                       true, "a decline with no name must not render as a blank signer")
    }

    // MARK: - What the organisation requires

    func testWithNoOrganisationPolicyASignatureIsNeverDemanded() {
        XCTAssertFalse(Config.organizationRequiresCustomerSignOff,
                       "a phone that has never been given a profile asks for nothing")
        XCTAssertEqual(SignOffPolicy.decide(signOff: nil, required: false), .allowed)
    }

    func testRequiredAndUnsignedBlocksTheClose() {
        XCTAssertEqual(SignOffPolicy.decide(signOff: nil, required: true),
                       .blocked(SignOffPolicy.blockedReason))
    }

    func testRequiredIsSatisfiedByASignatureOrATypedName() {
        for method in [CustomerSignOff.Method.drawn, .typed] {
            let signOff = CustomerSignOff(customerName: "Dana", method: method, summaryLines: ["a"])
            XCTAssertEqual(SignOffPolicy.decide(signOff: signOff, required: true), .allowed,
                           "\(method) should satisfy a required sign-off")
        }
    }

    /// A decline is an acceptable answer — but only a stated one. "They refused", with no reason,
    /// is indistinguishable from nobody having asked.
    func testRequiredIsSatisfiedByADeclineOnlyWhenAReasonIsGiven() {
        let bare = CustomerSignOff(customerName: "", method: .declined, summaryLines: ["a"])
        XCTAssertEqual(SignOffPolicy.decide(signOff: bare, required: true),
                       .blocked(SignOffPolicy.blockedReason))
        let blank = CustomerSignOff(customerName: "", method: .declined, declinedReason: "   ",
                                    summaryLines: ["a"])
        XCTAssertEqual(SignOffPolicy.decide(signOff: blank, required: true),
                       .blocked(SignOffPolicy.blockedReason))
        let stated = CustomerSignOff(customerName: "", method: .declined,
                                     declinedReason: "Nobody on site.", summaryLines: ["a"])
        XCTAssertEqual(SignOffPolicy.decide(signOff: stated, required: true), .allowed)
    }

    /// And the rule is enforced where every close goes through, not only where the sheet asks.
    func testTheCloseIsBlockedWhileTheOrganisationRequiresASignature() throws {
        Config.organizationRequiresCustomerSignOff = true
        let store = ConversationStore(directory: sessionsRoot.appendingPathComponent("store"))
        let flow = GuidedJobFlow(sessions: service, store: store)
        let model = JobTabModel(host: service, flow: flow, defaults: .init(
            vaultId: { Self.vaultId }, mode: { .aiOnly },
            vaultName: { _ in "Refrigeration" }, vaultUnlocked: { _ in true }))
        try startJobWithInternalContent()

        XCTAssertThrowsError(try model.closeJob()) { error in
            XCTAssertEqual((error as? FieldSessionError)?.errorDescription,
                           SignOffPolicy.blockedReason)
        }
        XCTAssertNotNil(service.activeSession, "a blocked close must leave the job open")

        service.recordSignOff(CustomerSignOff(customerName: "Dana", method: .typed,
                                              summaryLines: try record().customerSummaryLines))
        let closed = try model.closeJob()
        XCTAssertNotNil(closed.session.endedAt)
    }

    // MARK: - Signing sends nothing

    func testSigningTheJobSendsNothing() throws {
        let session = try startJobWithInternalContent()
        service.recordSignOff(
            CustomerSignOff(customerName: "Dana", method: .drawn,
                            summaryLines: try record().customerSummaryLines),
            pngData: signature(), strokeData: Data("strokes".utf8))

        XCTAssertNil(service.stagedDelivery,
                     "a signature must never put a report in front of anybody")
        let kinds = SessionLogger.readEvents(at: sessionDirectory(session.id)).map(\.kind)
        XCTAssertFalse(kinds.contains(.reportSent))
        XCTAssertFalse(kinds.contains(.reportCancelled))
        XCTAssertFalse(kinds.contains(.reportFailed))
        XCTAssertTrue(kinds.contains(.customerSignOff))
    }

    func testTheAuditLogRecordsTheAnswerAndTheDigestButNotTheSignature() throws {
        let session = try startJobWithInternalContent()
        let lines = try record().customerSummaryLines
        service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", comment: "All good.", method: .drawn,
                            summaryLines: lines),
            pngData: signature())

        let events = SessionLogger.readEvents(at: sessionDirectory(session.id))
        let entry = try XCTUnwrap(events.last { $0.kind == .customerSignOff })
        XCTAssertEqual(entry.payload?["method"]?.value as? String, "drawn")
        XCTAssertEqual(entry.payload?["summary_digest"]?.value as? String,
                       CustomerSignOff.digest(of: lines))
        XCTAssertEqual(entry.payload?["signature"]?.value as? Bool, true)
        let rendered = String(describing: entry.payload ?? [:]) + (entry.text ?? "")
        XCTAssertFalse(rendered.contains("All good."),
                       "the customer's own words belong on the record, not duplicated in the log")
        XCTAssertFalse(rendered.contains("Okafor"))
    }

    func testACancelledHandOverIsRecordedAsHavingBeenAsked() throws {
        let session = try startJobWithInternalContent()
        service.logSignOffCancelled()
        let kinds = SessionLogger.readEvents(at: sessionDirectory(session.id)).map(\.kind)
        XCTAssertTrue(kinds.contains(.customerSignOffCancelled))
        XCTAssertNil(service.activeSession?.signOff, "a cancel records nothing on the job itself")
    }

    // MARK: - Frozen at signing

    /// The point of storing the lines rather than re-deriving them. A later addendum — Plan FO's
    /// debrief, or simply more work on the same visit — must not change what a customer agreed to.
    func testTheSignedSummaryIsUnchangedByLaterWorkOnTheRecord() throws {
        try startJobWithInternalContent()
        let atSigning = try record().customerSummaryLines
        service.recordSignOff(CustomerSignOff(customerName: "Dana", method: .typed,
                                              summaryLines: atSigning))

        // The addendum: a second completed task, which the customer never saw.
        let extra = try service.addOperatorTask(title: "ZQADDENDUMTASK")
        _ = try service.startTask(id: extra.id)
        _ = try service.completeTask(id: extra.id)

        let after = try record()
        let signOff = try XCTUnwrap(after.signOff)
        XCTAssertEqual(signOff.summaryLines, atSigning)
        XCTAssertTrue(signOff.digestMatchesSummary,
                      "the stored digest must still match the stored lines")
        XCTAssertFalse(signOff.summaryLines.joined().contains("ZQADDENDUMTASK"))
        XCTAssertTrue(after.customerSummaryLines.joined().contains("ZQADDENDUMTASK"),
                      "the live summary should move on — that is what makes the frozen one a fact")
        XCTAssertNotEqual(signOff.summaryDigest,
                          CustomerSignOff.digest(of: after.customerSummaryLines))
    }

    // MARK: - The work order and the audit JSON

    func testTheWorkOrderCarriesTheAcceptanceBlockAndTheSignatureExactlyOnce() throws {
        let session = try startJobWithInternalContent()
        service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", comment: "Happy with the work.",
                            method: .drawn, summaryLines: try record().customerSummaryLines),
            pngData: signature())
        _ = try service.endSession(outcome: .resolved)

        let url = try renderPDF(session.id)
        let text = try flattenedText(of: url)
        XCTAssertTrue(text.contains(CustomerSignOff.blockTitle))
        XCTAssertTrue(text.contains("Dana Okafor"))
        XCTAssertTrue(text.contains("Signed on the technician's phone"))
        XCTAssertTrue(text.contains("Customer's note: Happy with the work."))
        XCTAssertTrue(text.contains("not a legal e-signature"))
        XCTAssertEqual(embeddedImageCount(in: url), 1,
                       "the signature should be drawn once — the review was never reached, so no "
                       + "photograph was selected")
        savePage(of: url, named: "fo2c-work-order-acceptance")
    }

    /// The job's own fixture already carries one photograph; this adds a second, selects both, and
    /// signs — so the document should embed exactly three pictures and no more.
    func testAJobWithPicturesAndASignatureDrawsEachExactlyOnce() throws {
        let session = try startJobWithInternalContent()
        service.attachPhoto(signature(0.1), caption: "trap as found", origin: .photoLog,
                            filterWasOn: true)
        service.setEvidenceSelection(service.evidenceSelection().confirmed())
        XCTAssertEqual(service.jobMedia.count, 2)
        service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", method: .drawn,
                            summaryLines: try record().customerSummaryLines),
            pngData: signature(0.8))
        _ = try service.endSession(outcome: .resolved)

        XCTAssertEqual(embeddedImageCount(in: try renderPDF(session.id)), 3,
                       "two selected photographs and one signature")
    }

    func testADeclinedSignOffPrintsTheDeclineAndNoPicture() throws {
        let session = try startJobWithInternalContent()
        service.recordSignOff(CustomerSignOff(customerName: "", method: .declined,
                                              declinedReason: "The customer had left site.",
                                              summaryLines: try record().customerSummaryLines))
        _ = try service.endSession(outcome: .resolved)

        let url = try renderPDF(session.id)
        let text = try flattenedText(of: url)
        XCTAssertTrue(text.contains("The customer declined to sign"))
        XCTAssertTrue(text.contains("Reason given: The customer had left site."))
        XCTAssertEqual(embeddedImageCount(in: url), 0)
    }

    func testAJobThatWasNeverSignedPrintsNoAcceptanceBlock() throws {
        let session = try startJobWithInternalContent()
        _ = try service.endSession(outcome: .resolved)
        let text = try flattenedText(of: try renderPDF(session.id))
        XCTAssertFalse(text.contains(CustomerSignOff.blockTitle))
    }

    /// The JSON carries everything the block does **except** the picture, which is a reference.
    func testTheAuditJSONCarriesTheSignOffAsAFileReference() throws {
        let session = try startJobWithInternalContent()
        let lines = try record().customerSummaryLines
        let written = try XCTUnwrap(service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", method: .drawn, summaryLines: lines),
            pngData: signature()))
        _ = try service.endSession(outcome: .resolved)

        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: sessionDirectory(session.id)))
        let signOff = try XCTUnwrap(document.workRecord?.signOff)
        XCTAssertEqual(signOff.customerName, "Dana Okafor")
        XCTAssertEqual(signOff.summaryLines, lines)
        XCTAssertEqual(signOff.summaryDigest, CustomerSignOff.digest(of: lines))
        XCTAssertEqual(signOff.signatureImageId, written.signatureImageId)

        let json = try XCTUnwrap(String(data: try XCTUnwrap(encode(document)), encoding: .utf8))
        XCTAssertTrue(json.contains("\"sign_off\""))
        XCTAssertTrue(json.contains("\"summary_digest\""))
        XCTAssertTrue(json.contains(try XCTUnwrap(written.signatureImageId)))
        // The bytes stay a file: the reference is a name, and nothing base64-shaped rides along.
        XCTAssertFalse(json.contains("iVBORw0KGgo"), "the picture itself must not be in the JSON")
    }

    // MARK: - Older records

    func testARecordWrittenBeforeSignOffExistedStillDecodes() throws {
        let legacy = """
        {"session_id":"abc","vault":"refrigeration","vault_name":"Refrigeration",
         "started_at":"2026-01-02T03:04:05Z","billable_minutes":12}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WorkRecord.self, from: Data(legacy.utf8))
        XCTAssertNil(record.signOff)
        // And a sign-off written before the method or the digest existed decodes to the honest
        // answer rather than throwing.
        let sparse = """
        {"signed_at":"2026-01-02T03:04:05Z","customer_name":"Dana"}
        """
        let signOff = try decoder.decode(CustomerSignOff.self, from: Data(sparse.utf8))
        XCTAssertEqual(signOff.method, .typed)
        XCTAssertTrue(signOff.summaryLines.isEmpty)
        XCTAssertFalse(signOff.digestMatchesSummary,
                       "an absent digest must not read as a matching one")
    }

    // MARK: - After the close

    func testAFinishedJobCanStillBeSignedUntilItsReportHasGone() throws {
        let session = try startJobWithInternalContent()
        let record = try record()
        _ = try service.endSession(outcome: .resolved)

        XCTAssertTrue(service.signOffIsStillOpen(sessionId: session.id))
        let written = try XCTUnwrap(service.recordSignOff(
            CustomerSignOff(customerName: "Dana Okafor", method: .drawn,
                            summaryLines: record.customerSummaryLines),
            pngData: signature(), sessionId: session.id))

        XCTAssertEqual(service.signOff(sessionId: session.id), written)
        XCTAssertFalse(service.signOffIsStillOpen(sessionId: session.id),
                       "a job that has been signed is no longer waiting to be")
        // It survives a reload, which is what makes it a record rather than a screen state.
        let reloaded = FieldSessionService(sessionsRoot: sessionsRoot)
        XCTAssertEqual(reloaded.signOff(sessionId: session.id)?.summaryDigest,
                       written.summaryDigest)
    }

    func testOnceTheReportHasGoneTheJobCanNoLongerBeSigned() throws {
        let session = try startJobWithInternalContent()
        let record = try record()
        _ = try service.endSession(outcome: .resolved)

        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["office@example.com"], attachments: [])
        service.completeDelivery(request, outcome: .sent)

        XCTAssertTrue(service.reportWasSent(sessionId: session.id))
        XCTAssertFalse(service.signOffIsStillOpen(sessionId: session.id))
        XCTAssertNil(service.recordSignOff(
            CustomerSignOff(customerName: "Too late", method: .typed,
                            summaryLines: record.customerSummaryLines),
            sessionId: session.id),
            "a report that has already gone cannot gain a signature afterwards")
        XCTAssertNil(service.signOff(sessionId: session.id))
    }

    /// A cancelled composer is not a send, so the job is still open for a signature.
    func testACancelledReportLeavesTheJobStillSignable() throws {
        let session = try startJobWithInternalContent()
        let record = try record()
        _ = try service.endSession(outcome: .resolved)
        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["office@example.com"], attachments: [])
        service.completeDelivery(request, outcome: .cancelled)

        XCTAssertFalse(service.reportWasSent(sessionId: session.id))
        XCTAssertTrue(service.signOffIsStillOpen(sessionId: session.id))
    }

    // MARK: - Reading the produced document

    private func renderPDF(_ sessionId: String) throws -> URL {
        let directory = sessionDirectory(sessionId)
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: directory))
        let url = sessionsRoot.appendingPathComponent("\(UUID().uuidString)-work_order.pdf")
        try SessionExporter.writePDF(document, to: url,
                                     photosDirectory: directory.appendingPathComponent("photos"))
        return url
    }

    /// The document's text with every run of whitespace collapsed to one space.
    ///
    /// A sentence drawn into a PDF is wrapped by the layout, and PDFKit reads the wrap back as a
    /// newline — so a phrase that spans a line break is not a substring of the raw extraction. What
    /// is being asserted is that the words are on the page, not where they broke.
    private func flattenedText(of url: URL) throws -> String {
        let raw = try XCTUnwrap(PDFDocument(url: url)?.string)
        return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func encode(_ document: SessionExport) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(document)
    }

    /// Count the image XObjects the document actually embeds.
    private func embeddedImageCount(in url: URL) -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { return -1 }
        var total = 0
        for number in 1...max(1, document.numberOfPages) {
            guard let page = document.page(at: number),
                  let dictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
                  let resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            var count = 0
            CGPDFDictionaryApplyFunction(xobjects, { _, value, info in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Image" else { return }
                info?.assumingMemoryBound(to: Int.self).pointee += 1
            }, &count)
            total += count
        }
        return total
    }

    /// Photograph the last page of a produced work order, when a screenshot pass asked for it.
    ///
    /// The PDF is the one artefact a person cannot look at by walking the app, and the acceptance
    /// block is printed into it — so the pass that photographs the screens photographs this too.
    /// Silent no-op without `OG_SHOT_DIR`, so the assertion above is the test and this is a
    /// by-product of it.
    private func savePage(of url: URL, named name: String) {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["OG_SHOT_DIR"], !directory.isEmpty,
              let document = CGPDFDocument(url as CFURL) else { return }
        // The page the block *starts* on, not the last one — a work order long enough to spill
        // would otherwise be photographed as its own last two lines.
        let readable = PDFDocument(url: url)
        let index = (1...max(1, document.numberOfPages)).first {
            readable?.page(at: $0 - 1)?.string?.contains(CustomerSignOff.blockTitle) == true
        } ?? document.numberOfPages
        guard let page = document.page(at: index) else { return }
        let bounds = page.getBoxRect(.mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.drawPDFPage(page)
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? image.write(to: out)
    }

    private static let fixedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
