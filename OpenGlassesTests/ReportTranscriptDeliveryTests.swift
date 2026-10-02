import PDFKit
import XCTest
@testable import OpenGlasses

/// Plan HD — what a report actually carries of the conversation, asserted against the produced
/// files: the work-order PDF's text, the JSON record, the transcript PDF and the attachment list.
@MainActor
final class ReportTranscriptDeliveryTests: XCTestCase {

    private var tempRoot: URL!
    private var previousEntitlement: FieldAssistEntitlementProvider!

    private let technicianWords = "I see error code E5 on the display"
    private let assistantWords = "E5 is a compressor motor lock on Daikin units."
    private let officeContext = ReportTranscriptPolicy.Context(
        officeAddresses: ["office@northbridge.example", "+6421000000"])

    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(true, forKey: "fieldAssistEnabled")
        previousEntitlement = EntitlementTestScope.grant()
        VaultRegistry.shared.resetCache()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportTranscript-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        UserDefaults.standard.removeObject(forKey: "fieldAssistEnabled")
        EntitlementTestScope.restore(previousEntitlement)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// A finished job with one exchange on it, and optionally clips of the given sizes.
    private func makeJob(clipBytes: [Int] = []) throws
        -> (service: FieldSessionService, session: FieldSession, directory: URL) {
        let service = FieldSessionService(sessionsRoot: tempRoot)
        service.reportTranscriptContext = { [officeContext] in officeContext }
        _ = try service.startSession(vaultId: "refrigeration", assetId: "Unit 47B",
                                               mode: .aiOnly, jobReference: "1005")
        service.logUserMessage(technicianWords)
        service.logAssistantMessage(assistantWords, citations: ["error_codes.md"])
        if !clipBytes.isEmpty {
            let task = try service.addOperatorTask(title: "Compressor", why: "E5")
            _ = try service.startTask(id: task.id)
            for (index, bytes) in clipBytes.enumerated() {
                _ = service.attachClip(Data(repeating: UInt8(index + 1), count: bytes), posterJPEG: nil,
                                   caption: "clip \(index + 1)", durationSeconds: 10,
                                   filterWasOn: true, cutShort: false)
            }
            _ = try service.completeTask(id: task.id, note: "Reset.")
            var selection = service.evidenceSelection()
            selection.includeAll()
            service.setEvidenceSelection(selection.confirmed())
        }
        let finished = try service.endSession(outcome: .resolved)
        return (service, finished, tempRoot.appendingPathComponent(finished.id, isDirectory: true))
    }

    private func text(ofPDF url: URL) throws -> String {
        try XCTUnwrap(PDFDocument(url: url)?.string).replacingOccurrences(of: "\n", with: " ")
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func attachment(_ delivery: FieldSessionService.ReportDelivery,
                            _ kind: DeliveryRequest.Attachment.Kind) -> DeliveryRequest.Attachment? {
        delivery.attachments.first { $0.kind == kind }
    }

    // MARK: - The work order

    func testTheWorkOrderPDFCarriesNoTranscriptForAnybody() throws {
        let job = try makeJob()
        for recipients in [["office@northbridge.example"], ["dave@customer.example"]] {
            let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                      recipients: recipients,
                                                      transcriptChoice: .init(attachTranscript: true))
            let workOrder = try XCTUnwrap(attachment(delivery, .pdf))
            let text = try text(ofPDF: workOrder.url)
            XCTAssertTrue(text.contains("Field Assist Session Record"), "it is the work order")
            XCTAssertTrue(text.contains("Sources Cited"), "sources cited stay")
            XCTAssertFalse(text.contains("E5 on the display"), "no technician line: \(recipients)")
            XCTAssertFalse(text.contains("compressor motor lock"), "no assistant line: \(recipients)")
            XCTAssertFalse(text.contains("Technician:"))
            XCTAssertFalse(text.contains("Transcript"), "no Transcript heading")
        }
    }

    // MARK: - The JSON record

    func testTheOfficeJSONKeepsTheTranscript() throws {
        let job = try makeJob()
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                  recipients: ["office@northbridge.example"])
        let record = try json(try XCTUnwrap(attachment(delivery, .json)).url)
        XCTAssertEqual(record["transcript_included"] as? Bool, true)
        XCTAssertNil(record["transcript_omitted_reason"])
        XCTAssertEqual((record["transcript"] as? [Any])?.count, 2)
        let claims = (record["citations"] as? [[String: Any]])?.compactMap { $0["claim"] as? String }
        XCTAssertEqual(claims?.first, assistantWords)
        XCTAssertEqual(delivery.transcript?.audience, .office)
    }

    func testTheCustomerJSONKeepsTheKeyButNotTheWords() throws {
        let job = try makeJob()
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                  recipients: ["dave@customer.example"])
        let url = try XCTUnwrap(attachment(delivery, .json)).url
        let record = try json(url)
        XCTAssertEqual((record["transcript"] as? [Any])?.count, 0, "present and empty, for old readers")
        XCTAssertEqual(record["transcript_included"] as? Bool, false)
        XCTAssertEqual(record["transcript_omitted_reason"] as? String, "customer_destination")
        let citations = try XCTUnwrap(record["citations"] as? [[String: Any]])
        XCTAssertFalse(citations.isEmpty, "the citation itself stays")
        XCTAssertTrue(citations.allSatisfy { $0["claim"] == nil || $0["claim"] is NSNull },
                      "the assistant's answer is not smuggled out in a citation")
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("E5 on the display"))
        XCTAssertFalse(raw.contains("compressor motor lock"))

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExport.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.transcriptIncluded, false)
        XCTAssertEqual(decoded.transcriptOmittedReason, "customer_destination")
    }

    func testARecordWrittenBeforeThisStillDecodes() throws {
        let job = try makeJob()
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(document))
                                   as? [String: Any])
        object.removeValue(forKey: "transcript_included")
        object.removeValue(forKey: "transcript_omitted_reason")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExport.self,
                                         from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.transcriptIncluded)
        XCTAssertEqual(decoded.transcript.count, 2)
    }

    func testAnArchiveExportKeepsTheTranscriptAndSaysSo() throws {
        let job = try makeJob()
        let document = try XCTUnwrap(SessionExporter.buildExport(sessionDir: job.directory))
        XCTAssertEqual(document.transcriptIncluded, true)
        XCTAssertEqual(document.transcript.count, 2)
    }

    // MARK: - The transcript PDF

    func testTheTranscriptPDFGoesOnlyWhenChosenForTheOffice() throws {
        let job = try makeJob()
        let plain = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                               recipients: ["office@northbridge.example"])
        XCTAssertNil(attachment(plain, .transcriptPDF), "off by default")

        let chosen = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                recipients: ["office@northbridge.example"],
                                                transcriptChoice: .init(attachTranscript: true))
        let transcript = try XCTUnwrap(attachment(chosen, .transcriptPDF))
        XCTAssertEqual(transcript.filename, "job-1005-transcript.pdf")
        XCTAssertEqual(transcript.kind.mimeType, "application/pdf")
        let text = try text(ofPDF: transcript.url)
        XCTAssertTrue(text.contains("Job transcript — for the office"))
        XCTAssertTrue(text.contains("speech-to-text"), "labelled as what it is")
        XCTAssertTrue(text.contains("not for the customer"))
        XCTAssertTrue(text.contains("Technician: \(technicianWords)"))
        XCTAssertTrue(text.contains("Assistant: E5 is a compressor motor lock"))

        let customer = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                  recipients: ["dave@customer.example"],
                                                  transcriptChoice: .init(attachTranscript: true))
        XCTAssertNil(attachment(customer, .transcriptPDF), "never to a customer")

        let marked = job.service.reportDelivery(
            for: .shareSheet, sessionId: job.session.id,
            transcriptChoice: .init(markedAsOffice: true, attachTranscript: true))
        XCTAssertNotNil(attachment(marked, .transcriptPDF), "the share sheet, marked as the office")
    }

    func testTheTranscriptPDFLeavesTheAppsOwnPromptsOut() {
        let at = Date(timeIntervalSince1970: 1_000)
        let prompt = TranscriptOriginClassifier.knownAppPrompts.first ?? ""
        let lines = JobTranscriptExport.logLines(from: [
            .init(timestamp: at, kind: .userMessage, text: prompt, payload: nil),
            .init(timestamp: at, kind: .userMessage, text: "  Hello  ", payload: nil),
            .init(timestamp: at, kind: .assistantMessage, text: "Hi.", payload: nil),
            .init(timestamp: at.addingTimeInterval(-5), kind: .escalationRequested, text: "x", payload: nil)
        ])
        XCTAssertEqual(lines.map(\.speaker), [.technician, .assistant])
        XCTAssertEqual(lines.map(\.text), ["Hello", "Hi."], "same instant keeps the logged order")
    }

    // MARK: - The budget

    /// The transcript PDF is a report file, so its stated room comes before any clip — and the
    /// same choice partitions the same way twice.
    func testTheTranscriptPDFIsReservedBeforeTheClipsAndReproducibly() throws {
        let job = try makeJob(clipBytes: [1_800_000])
        let office = ["+6421000000"]
        let without = job.service.reportDelivery(for: .messages, canSendAttachments: true,
                                                 sessionId: job.session.id, recipients: office)
        XCTAssertEqual(without.clipPlan.attached.count, 1, "fits beside the report's own files")

        let with = job.service.reportDelivery(for: .messages, canSendAttachments: true,
                                              sessionId: job.session.id, recipients: office,
                                              transcriptChoice: .init(attachTranscript: true))
        XCTAssertEqual(with.clipPlan.attached.count, 0, "the transcript's room comes first")
        XCTAssertEqual(with.clipPlan.overBudget.count, 1)
        XCTAssertNotNil(attachment(with, .transcriptPDF))

        let again = job.service.reportDelivery(for: .messages, canSendAttachments: true,
                                               sessionId: job.session.id, recipients: office,
                                               transcriptChoice: .init(attachTranscript: true))
        XCTAssertEqual(with.clipPlan, again.clipPlan)
        XCTAssertEqual(with.attachments.map(\.filename), again.attachments.map(\.filename))
    }

    // MARK: - The request and the audit

    func testTheConfirmationAndTheAuditSayWhatWent() throws {
        let job = try makeJob()
        let record = try XCTUnwrap(job.service.workRecord(sessionId: job.session.id))
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                  recipients: ["office@northbridge.example"],
                                                  transcriptChoice: .init(attachTranscript: true))
        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["office@northbridge.example"],
                                           attachments: delivery.attachments,
                                           transcript: delivery.transcript)
        XCTAssertTrue(request.confirmation.contains("The transcript goes with it, for the office."))

        job.service.completeDelivery(request, outcome: .sent)
        let sent = try XCTUnwrap(SessionLogger.readEvents(at: job.directory)
            .last { $0.kind == .reportSent })
        XCTAssertEqual(sent.payload?["audience"]?.value as? String, "office")
        XCTAssertEqual((sent.payload?["transcript"]?.value as? [Any])?.compactMap { $0 as? String },
                       ["json", "pdf"])
        XCTAssertTrue(((sent.payload?["attachments"]?.value as? [Any]) ?? [])
            .contains { ($0 as? String) == "transcript_pdf" })
    }

    func testACustomerReportSaysNothingAboutATranscript() throws {
        let job = try makeJob()
        let record = try XCTUnwrap(job.service.workRecord(sessionId: job.session.id))
        let delivery = job.service.reportDelivery(for: .email, sessionId: job.session.id,
                                                  recipients: ["dave@customer.example"])
        let request = DeliveryRequest.make(record: record, channel: .email,
                                           recipients: ["dave@customer.example"],
                                           attachments: delivery.attachments,
                                           transcript: delivery.transcript)
        XCTAssertFalse(request.confirmation.contains("transcript"))
        XCTAssertEqual(request.transcript?.audience, .customer)
    }
}
