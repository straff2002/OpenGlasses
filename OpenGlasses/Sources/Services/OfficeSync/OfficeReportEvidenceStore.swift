import Foundation

/// Keeps the exact bytes of the documents that go to the office with a job's record, until the
/// office has them (Contracts/office-reports.md §5, §11.7).
///
/// A report names each attachment by digest and size, and the documents are rendered when they
/// are sent — two renderings of one work order are not the same bytes. So the documents for one
/// queued operation are rendered once, stored under their digests, and those bytes are what is
/// named and what is published, however many times the operation is tried. They are removed when
/// the office has fully accepted the report, or a later one replaced it.
@MainActor
final class OfficeReportEvidenceStore {

    /// One rendered document.
    struct Document: Equatable, Sendable {
        let role: OfficeReport.Role
        let mediaType: String
        /// What to call it for a person. Never a path.
        let name: String
        let requirement: OfficeReport.Requirement
        let audience: OfficeReport.Audience
        let bytes: Data
    }

    struct Rendered: Sendable {
        var documents: [Document]
        var transcript: OfficeReport.Transcript
    }

    typealias Evidence = (evidence: [OfficeReportService.Evidence], transcript: OfficeReport.Transcript)

    private struct Index: Codable {
        var version = 1
        var transcript: OfficeReport.Transcript
        var attachments: [OfficeReport.Attachment]
    }

    enum Failure: Error, Equatable {
        /// The documents rendered cannot be listed in a manifest: two of one digest, a name
        /// outside the rules, a transcript that is not where the rendering says it is.
        case notListable
    }

    private let directory: URL
    private let render: @MainActor (QueuedOp) async throws -> Rendered

    init(directory: URL, render: @escaping @MainActor (QueuedOp) async throws -> Rendered) {
        self.directory = directory
        self.render = render
    }

    /// The evidence for one operation: what was stored for it, or, the first time, what is
    /// rendered now and stored.
    func evidence(for op: QueuedOp) async throws -> Evidence {
        guard OfficeManualAssignment.safeIdentifier(op.id) else { throw Failure.notListable }
        let folder = directory.appendingPathComponent(op.id, isDirectory: true)
        if let stored = read(folder) { return stored }

        let rendered = try await render(op)
        let attachments = rendered.documents.map {
            OfficeReport.Attachment(sha256: OfficeReport.digest($0.bytes), bytes: Int64($0.bytes.count),
                                    role: $0.role.rawValue, mediaType: $0.mediaType, name: $0.name,
                                    requirement: $0.requirement.rawValue, audience: $0.audience.rawValue)
        }
        // Listable, and the transcript where the rendering says it is, before anything is kept.
        guard OfficeReport.manifestBytes(attachments) != nil,
              attachments.contains(where: { $0.role == OfficeReport.Role.transcript.rawValue })
                == (rendered.transcript == .attached) else { throw Failure.notListable }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)
        for (document, attachment) in zip(rendered.documents, attachments) {
            try document.bytes.write(to: folder.appendingPathComponent(attachment.sha256),
                                     options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // The index last: a folder without one is rendered again.
        try JSONEncoder().encode(Index(transcript: rendered.transcript, attachments: attachments))
            .write(to: folder.appendingPathComponent(Self.indexName),
                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard let stored = read(folder) else { throw Failure.notListable }
        return stored
    }

    /// What is stored for a folder, or nil unless every document it lists is there in full.
    private func read(_ folder: URL) -> Evidence? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.indexName)),
              let index = try? JSONDecoder().decode(Index.self, from: data), index.version == 1 else { return nil }
        var evidence: [OfficeReportService.Evidence] = []
        for attachment in index.attachments {
            let file = folder.appendingPathComponent(attachment.sha256)
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size.map(Int64.init) == attachment.bytes else { return nil }
            evidence.append(.init(attachment: attachment, file: file))
        }
        return (evidence, index.transcript)
    }

    /// The office has everything these operations named, or a later report replaced them.
    func remove(operationIDs: Set<String>) {
        for id in operationIDs where OfficeManualAssignment.safeIdentifier(id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
        }
    }

    /// Everything, for a phone that is leaving its organisation.
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let indexName = "evidence.json"

    nonisolated static func defaultDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        return support.appendingPathComponent("AvenkinOffice", isDirectory: true)
            .appendingPathComponent("report-evidence", isDirectory: true)
    }
}

/// Which documents go to the office with a job's record, decided without rendering anything.
///
/// The work order and the audit export always go. The transcript goes as its own document under
/// the organisation's rule for its own office — unless that rule is *never*, when the report says
/// it was omitted — and a job with nothing said has none. Everything in these folders goes to the
/// office and only to the office; `audience` says what the office may pass on to a customer.
enum OfficeReportDocuments {

    struct Seams {
        /// Whether the job's session is still on this phone.
        var sessionExists: @MainActor (String) -> Bool
        /// Whether this phone may make the job's documents at all (the audited-export capability).
        var mayExport: @MainActor () -> Bool
        /// Whether the organisation keeps transcripts on the phone (`never`).
        var transcriptStaysOnPhone: @MainActor () -> Bool
        /// Whether anything was said on the job.
        var hasTranscript: @MainActor (String) -> Bool
        /// The work order and the audit export, rendered now.
        var report: @MainActor (String) throws -> (workOrder: Data, auditExport: Data)
        /// The transcript document, rendered now.
        var transcript: @MainActor (String) throws -> Data
    }

    static let workOrderName = "work-order.pdf"
    static let auditExportName = "audit-export.json"
    static let transcriptName = "transcript.pdf"

    @MainActor
    static func render(sessionID: String, seams: Seams) throws -> OfficeReportEvidenceStore.Rendered {
        // A job that is no longer on this phone, or a phone that cannot make its documents, still
        // sends the record: with no documents, and no claim about a transcript it cannot see.
        guard seams.sessionExists(sessionID), seams.mayExport() else {
            return .init(documents: [], transcript: .none)
        }
        let report = try seams.report(sessionID)
        var documents: [OfficeReportEvidenceStore.Document] = [
            .init(role: .workOrder, mediaType: "application/pdf", name: workOrderName,
                  requirement: .required, audience: .customer, bytes: report.workOrder),
            // The audit export carries the transcript when the rule allows it: the office's only.
            .init(role: .auditExport, mediaType: "application/json", name: auditExportName,
                  requirement: .required, audience: .office, bytes: report.auditExport),
        ]
        guard seams.hasTranscript(sessionID) else { return .init(documents: documents, transcript: .none) }
        guard !seams.transcriptStaysOnPhone() else { return .init(documents: documents, transcript: .omitted) }
        documents.append(.init(role: .transcript, mediaType: "application/pdf", name: transcriptName,
                               requirement: .required, audience: .office, bytes: try seams.transcript(sessionID)))
        return .init(documents: documents, transcript: .attached)
    }
}

extension OfficeReportDocuments.Seams {
    /// The app's own export, as a report to the organisation's office has always been made.
    @MainActor
    static func app(sessions: FieldSessionService = .shared) -> Self {
        func directory(_ id: String) -> URL { sessions.sessionDirectory(sessionId: id) }
        func bytes(of lease: StagedExportLease) throws -> Data {
            defer { StagedExportCoordinator.fieldSession.release(lease) }
            return try Data(contentsOf: lease.fileURL)
        }
        return Self(
            sessionExists: { FileManager.default.fileExists(atPath: directory($0).path) },
            mayExport: { FieldAssistEntitlement.shared.has(.auditedExport) },
            transcriptStaysOnPhone: {
                ReportTranscriptPolicy.Context.current().organisation.internalRule == .never
            },
            hasTranscript: { !JobTranscriptExport.logLines(from: SessionLogger.readEvents(at: directory($0))).isEmpty },
            report: { id in
                // The office's own audience: the audit export keeps the transcript unless the
                // organisation says never.
                let leases = try SessionExporter.export(
                    sessionDir: directory(id), formats: [.json, .pdf],
                    transcript: ReportTranscriptPolicy.archive(context: .current()))
                var workOrder: Data?
                var auditExport: Data?
                for lease in leases {
                    let data = try bytes(of: lease)
                    if lease.displayName.hasSuffix(".pdf") { workOrder = data } else { auditExport = data }
                }
                guard let workOrder, let auditExport else { throw SessionExporter.ExportError.metadataUnreadable }
                return (workOrder, auditExport)
            },
            transcript: { id in
                guard let record = sessions.workRecord(sessionId: id) else {
                    throw SessionExporter.ExportError.metadataUnreadable
                }
                return try bytes(of: SessionExporter.exportTranscriptPDF(sessionDir: directory(id), record: record))
            })
    }
}
