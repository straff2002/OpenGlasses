import CryptoKit
import Foundation
import XCTest
@testable import OpenGlasses

/// The report, its manifest and the office's receipts as the phone writes and reads them, against
/// the Go golden fixtures and the contract's negative cases (Contracts/office-reports.md §10).
final class OfficeReportTests: XCTestCase {
    private typealias F = OfficeCheckInFixtures
    static let otherPhone = "DQB4YVC-VNAIUQE-UNBOI3L-YIZRPME-WG6DM7S-GSGGKBY-BGA7SBN-Q2OHOAZ"

    private func assertRefused<T>(_ expected: OfficeReport.Refusal, _ name: String, line: UInt = #line,
                                  _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), name, line: line) {
            XCTAssertEqual($0 as? OfficeReport.Refusal, expected, name, line: line)
        }
    }

    private func identity() throws -> OfficeReport.Identity {
        let held = try F.held()
        return .init(organizationID: held.organizationID, enrolmentID: held.enrolmentID,
                     officeID: held.officeID, phoneTransportID: held.phoneTransportID)
    }

    private func goldenReport() throws -> OfficeReport.Report {
        try OfficeReport.report(F.data("office-report-v1"), phoneApplicationKey: F.phone().publicKey.rawRepresentation,
                                identity: identity())
    }

    private func goldenAttachments() throws -> [OfficeReport.Attachment] {
        try XCTUnwrap(OfficeReport.manifest(F.data("office-report-manifest-v1")))
    }

    private func readReceipt(_ data: Data, report: OfficeReport.Report? = nil, envelope: Data? = nil,
                             attachments: [OfficeReport.Attachment]? = nil,
                             key: Data? = nil) throws -> (receipt: OfficeReport.Receipt, outcome: OfficeReport.Outcome) {
        try OfficeReport.receipt(
            data, officeApplicationKey: try key ?? F.office().publicKey.rawRepresentation,
            reportEnvelope: try envelope ?? F.data("office-report-v1"), report: try report ?? goldenReport(),
            attachments: try attachments ?? goldenAttachments())
    }

    // MARK: - The golden report, written by the phone

    func testThePhoneWritesTheGoldenReportByteForByte() throws {
        let record = try F.data("office-report-record-v1")
        let attachments = try goldenAttachments()
        XCTAssertEqual(attachments.map(\.role), ["photo", "workOrder", "transcript"], "ascending by digest")
        // The manifest has one spelling, and the phone writes it whatever order it is handed.
        let manifest = try XCTUnwrap(OfficeReport.manifestBytes(attachments.reversed()))
        XCTAssertEqual(manifest, try F.data("office-report-manifest-v1"))

        let report = try XCTUnwrap(OfficeReport.report(
            operationID: "7C9E6679-7425-40DE-944B-E07FC1F90AE7", recordKind: .workRecord,
            recordID: "3F2504E0-4F89-11D3-9A0C-0305E82C3301", revision: 1, identity: identity(),
            jobReference: "JOB-1042", jobID: "job-2031", jobRevision: 2, record: record, manifest: manifest,
            transcript: .attached, createdAt: F.now))
        XCTAssertEqual(report, try goldenReport())
        XCTAssertEqual(report.reportID, OfficeReport.reportID(operationID: report.operationID))
        let payload = try XCTUnwrap(OfficeReport.payloadBytes(report))
        XCTAssertEqual(payload, try F.payload("office-report-v1"))
        XCTAssertEqual(OfficeReport.reportPayload(payload), report)
        XCTAssertTrue(OfficeReport.transcriptAgrees(report, attachments: attachments))
        // The envelope the transport writes around it is the golden file.
        let signature = try XCTUnwrap(Data(base64Encoded: F.envelope(F.data("office-report-v1")).signature))
        XCTAssertEqual(OfficeReport.envelopeBytes(payload: payload, signature: signature), try F.data("office-report-v1"))
    }

    func testAReportIsThePhonesAndForThisPairing() throws {
        let payload = try F.payload("office-report-v1")
        assertRefused(.badSignature, "signed by the office application key") {
            try OfficeReport.report(F.signed(payload, domain: OfficeReport.reportDomain, by: F.office()),
                                    phoneApplicationKey: F.phone().publicKey.rawRepresentation, identity: self.identity())
        }
        assertRefused(.badSignature, "under the receipt's domain") {
            try OfficeReport.report(F.signed(payload, domain: OfficeReport.receiptDomain, by: F.phone()),
                                    phoneApplicationKey: F.phone().publicKey.rawRepresentation, identity: self.identity())
        }
        let other = OfficeReport.Identity(organizationID: "fixture-organisation", enrolmentID: "another-enrolment",
                                          officeID: try identity().officeID, phoneTransportID: try identity().phoneTransportID)
        assertRefused(.wrongReport, "another enrolment") {
            try OfficeReport.report(F.data("office-report-v1"),
                                    phoneApplicationKey: F.phone().publicKey.rawRepresentation, identity: other)
        }
    }

    func testOnlyAClosedReportPayloadWithinTheRulesIsOneThePhoneSigns() throws {
        let golden = try F.payload("office-report-v1")
        XCTAssertNotNil(OfficeReport.reportPayload(golden))
        func changed(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var fields = try F.fields(golden)
            change(&fields)
            return try JSONSerialization.data(withJSONObject: fields)
        }
        let cases: [(String, (inout [String: Any]) -> Void)] = [
            ("an identifier that is not the operation's digest", { $0["reportID"] = String(repeating: "0", count: 64) }),
            ("a record kind v1 does not have", { $0["recordKind"] = "photoUpload" }),
            ("revision zero", { $0["revision"] = 0 }),
            ("an empty record", { $0["recordBytes"] = 0 }),
            ("a record over the cap", { $0["recordBytes"] = OfficeReport.maximumRecordBytes + 1 }),
            ("a transcript state v1 does not have", { $0["transcript"] = "customer" }),
            ("a job reference that needs an escape", { $0["jobReference"] = "JOB \"1042\"" }),
            ("a job revision with no job identifier", { $0["jobID"] = "" }),
            ("a job identifier with no revision", { $0["jobRevision"] = 0 }),
            ("a job identifier that is a path", { $0["jobID"] = "../job" }),
            ("an operation that is a path", { $0["operationID"] = ".."; $0["reportID"] = OfficeReport.reportID(operationID: "..") }),
            ("another kind", { $0["kind"] = "avenkin.office-report-receipt" }),
            ("an extra member", { $0["generation"] = 1 }),
            ("a missing member", { $0["revision"] = nil }),
            ("a nested value", { $0["revision"] = ["n": 1] }),
        ]
        for (name, change) in cases {
            XCTAssertNil(OfficeReport.reportPayload(try changed(change)), name)
        }
        // A job that did not come from a format-2 file names neither.
        XCTAssertNotNil(OfficeReport.reportPayload(try changed { $0["jobID"] = ""; $0["jobRevision"] = 0 }))
        let text = String(decoding: golden, as: UTF8.self)
        for (name, other) in [
            ("a duplicate member", text.replacingOccurrences(of: #"{"version":1,"#, with: #"{"version":1,"version":1,"#)),
            ("a fractional number", text.replacingOccurrences(of: #""revision":1,"#, with: #""revision":1.0,"#)),
            ("trailing data", text + "{}"),
            ("nothing", ""),
        ] {
            XCTAssertNil(OfficeReport.reportPayload(Data(other.utf8)), name)
        }
        // No other message is a report.
        for name in ["office-report-receipt-full-v1", "office-check-in-v1", "office-removal-receipt-v1"] {
            XCTAssertNil(OfficeReport.reportPayload(try F.payload(name)), name)
        }
    }

    // MARK: - The manifest

    func testAManifestHasOneSpellingAndOnlyValidEvidence() throws {
        let good = String(decoding: try F.data("office-report-manifest-v1"), as: UTF8.self)
        let cases: [(String, String, String)] = [
            ("whitespace", #"{"version":1,"#, #"{ "version":1,"#),
            ("an extra member", #"{"version":1,"#, #"{"version":1,"note":"x","#),
            ("members out of order", #"{"version":1,"kind":"avenkin.office-report-manifest","#,
             #"{"kind":"avenkin.office-report-manifest","version":1,"#),
            ("a name that is a path", "job-JOB-1042.pdf", "../JOB-1042.pdf"),
            ("a hidden name", "job-JOB-1042.pdf", ".job-JOB-1042.pdf"),
            ("a media type not listed", "image/jpeg", "text/html"),
            ("a role not listed", #""role":"photo""#, #""role":"manual""#),
            ("an empty attachment", #""bytes":31,"#, #""bytes":0,"#),
            ("a transcript for the customer",
             #""name":"job-JOB-1042-transcript.pdf","requirement":"required","audience":"office""#,
             #""name":"job-JOB-1042-transcript.pdf","requirement":"required","audience":"customer""#),
            ("another version", #"{"version":1,"#, #"{"version":2,"#),
        ]
        for (name, old, new) in cases {
            XCTAssertTrue(good.contains(old), name)
            XCTAssertNil(OfficeReport.manifest(Data(good.replacingOccurrences(of: old, with: new).utf8)), name)
        }
        XCTAssertNil(OfficeReport.manifest(Data()))
        XCTAssertNil(OfficeReport.manifest(Data((good + " ").utf8)), "trailing data")
        // The same digest twice cannot be written.
        let attachments = try goldenAttachments()
        XCTAssertNil(OfficeReport.manifestBytes(attachments + [attachments[0]]))
        // A report with no evidence still names a manifest: the empty one.
        XCTAssertEqual(OfficeReport.manifestBytes([]),
                       Data(#"{"version":1,"kind":"avenkin.office-report-manifest","attachments":[]}"#.utf8))
        XCTAssertEqual(OfficeReport.manifest(try XCTUnwrap(OfficeReport.manifestBytes([]))), [])

        // The report and the manifest agree about the transcript.
        let report = try goldenReport()
        XCTAssertFalse(OfficeReport.transcriptAgrees(report, attachments: attachments.filter { $0.role != "transcript" }))
    }

    // MARK: - The receipts

    func testTheThreeGoldenReceiptsReadAsTheirOutcomes() throws {
        let expected: [(String, OfficeReport.Outcome, Int64, Int64)] = [
            ("pending", .evidencePending, 0, 3), ("record", .recordAccepted, 2, 1), ("full", .fullyAccepted, 3, 0)]
        for (stage, outcome, committed, outstanding) in expected {
            let read = try readReceipt(F.data("office-report-receipt-\(stage)-v1"))
            XCTAssertEqual(read.outcome, outcome)
            XCTAssertEqual(read.outcome.stage, stage)
            XCTAssertEqual(read.receipt.attachmentsCommitted, committed)
            XCTAssertEqual(read.receipt.attachmentsOutstanding, outstanding)
        }
        XCTAssertLessThan(OfficeReport.Outcome.evidencePending, .recordAccepted)
        XCTAssertLessThan(OfficeReport.Outcome.recordAccepted, .fullyAccepted)
    }

    func testAReceiptIsTheOfficesAndForExactlyTheReportPublished() throws {
        let full = try F.data("office-report-receipt-full-v1")
        let payload = try F.payload("office-report-receipt-full-v1")
        assertRefused(.badSignature, "signed by the phone application key") {
            try self.readReceipt(F.signed(payload, domain: OfficeReport.receiptDomain, by: F.phone()))
        }
        assertRefused(.badSignature, "signed by the administrator key") {
            try self.readReceipt(F.signed(payload, domain: OfficeReport.receiptDomain, by: F.administrator()))
        }
        assertRefused(.badSignature, "under the report's domain") {
            try self.readReceipt(F.signed(payload, domain: OfficeReport.reportDomain, by: F.office()))
        }
        func resigned(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try F.changed("office-report-receipt-full-v1", domain: OfficeReport.receiptDomain, by: F.office(), change)
        }
        let zeros = String(repeating: "0", count: 64)
        for (name, change) in [
            ("another report", { $0["reportID"] = zeros }),
            ("another report's bytes", { $0["reportSHA256"] = zeros }),
            ("another record", { $0["recordSHA256"] = zeros }),
            ("another manifest", { $0["manifestSHA256"] = zeros }),
            ("another enrolment", { $0["enrolmentID"] = "another-enrolment" }),
            ("another phone", { $0["phoneTransportID"] = Self.otherPhone }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            assertRefused(.wrongReport, name) { try self.readReceipt(resigned(change)) }
        }
        // The same report signed again is other bytes: a receipt for the first does not fit it.
        let again = try F.signed(F.payload("office-report-v1"), domain: OfficeReport.reportDomain, by: F.phone())
        XCTAssertNotEqual(again, try F.data("office-report-v1"))
        assertRefused(.wrongReport, "the same report under another signature") {
            try self.readReceipt(full, envelope: again)
        }
        for (name, change) in [
            ("fully accepted with something outstanding", { $0["attachmentsCommitted"] = 2; $0["attachmentsOutstanding"] = 1 }),
            ("pending with nothing outstanding", { $0["outcome"] = "evidencePending" }),
            ("counts that are not the manifest's", { $0["attachmentsCommitted"] = 2 }),
            ("record accepted with a required one out",
             { $0["outcome"] = "recordAccepted"; $0["attachmentsCommitted"] = 1; $0["attachmentsOutstanding"] = 2 }),
            ("an outcome v1 does not have", { $0["outcome"] = "refused" }),
            ("a negative count", { $0["attachmentsCommitted"] = 4; $0["attachmentsOutstanding"] = -1 }),
        ] as [(String, (inout [String: Any]) -> Void)] {
            assertRefused(.invalidFields, name) { try self.readReceipt(resigned(change)) }
        }
        assertRefused(.malformed, "an extra member") { try self.readReceipt(resigned { $0["reason"] = "x" }) }
        // Evidence pending needs a required attachment to be pending on.
        let optional = try goldenAttachments().map {
            OfficeReport.Attachment(sha256: $0.sha256, bytes: $0.bytes, role: "photo", mediaType: $0.mediaType,
                                    name: $0.name, requirement: "optional", audience: $0.audience)
        }
        assertRefused(.invalidFields, "evidence pending with nothing required") {
            try self.readReceipt(F.data("office-report-receipt-pending-v1"), attachments: optional)
        }
    }
}
