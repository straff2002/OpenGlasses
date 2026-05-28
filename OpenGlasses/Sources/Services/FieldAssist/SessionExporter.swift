import Foundation
import UIKit

/// Builds compliance export artifacts (consolidated JSON audit + PDF work order) for a Field Assist
/// session from its on-disk `session.json` + `log.jsonl`.
///
/// `@MainActor` because it resolves the vault display name via `VaultRegistry`.
@MainActor
enum SessionExporter {

    enum Format: String, CaseIterable {
        case json
        case pdf
    }

    enum ExportError: LocalizedError {
        case sessionNotFound(URL)
        case metadataUnreadable

        var errorDescription: String? {
            switch self {
            case .sessionNotFound(let url): return "No session found at \(url.lastPathComponent)."
            case .metadataUnreadable: return "Session metadata could not be read."
            }
        }
    }

    /// Produce the requested export artifacts in the session directory; returns their URLs.
    @discardableResult
    static func export(sessionDir: URL, formats: Set<Format> = [.json, .pdf]) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            throw ExportError.sessionNotFound(sessionDir)
        }
        guard let document = buildExport(sessionDir: sessionDir) else {
            throw ExportError.metadataUnreadable
        }
        var urls: [URL] = []
        if formats.contains(.json) { urls.append(try writeJSON(document, to: sessionDir)) }
        if formats.contains(.pdf) { urls.append(try writePDF(document, to: sessionDir)) }
        return urls
    }

    // MARK: - Reconstruction

    /// Reconstruct the consolidated export from the session metadata + append-only event log.
    static func buildExport(sessionDir: URL) -> SessionExport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metaData = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
              let session = try? decoder.decode(FieldSession.self, from: metaData) else {
            return nil
        }
        let events = readEvents(sessionDir.appendingPathComponent("log.jsonl"), decoder: decoder)

        var transcript: [SessionExport.TranscriptEntry] = []
        var photos: [SessionExport.PhotoRef] = []
        var citations: [SessionExport.Citation] = []
        var escalations: [SessionExport.EscalationEntry] = []

        // Per-procedure aggregation: distinct steps visited + final outcome.
        var procStepIds: [String: Set<String>] = [:]
        var procOrder: [String] = []
        var procOutcome: [String: String] = [:]

        for event in events {
            switch event.kind {
            case .userMessage:
                if let text = event.text {
                    transcript.append(.init(timestamp: event.timestamp, role: "technician", text: text))
                }
            case .assistantMessage:
                if let text = event.text {
                    transcript.append(.init(timestamp: event.timestamp, role: "assistant", text: text))
                }
                if let sources = event.payload?["citations"]?.value as? [Any] {
                    for source in sources.compactMap({ $0 as? String }) {
                        citations.append(.init(timestamp: event.timestamp, source: source, claim: event.text))
                    }
                }
            case .citation:
                if let source = event.payload?["source"]?.value as? String {
                    citations.append(.init(timestamp: event.timestamp, source: source,
                                           claim: event.payload?["claim"]?.value as? String ?? event.text))
                }
            case .photoAttached:
                if let path = event.payload?["path"]?.value as? String {
                    photos.append(.init(timestamp: event.timestamp, path: path,
                                        caption: (event.payload?["caption"]?.value as? String) ?? event.text))
                }
            case .escalationRequested:
                escalations.append(.init(timestamp: event.timestamp, reason: event.text ?? "Escalation requested"))
            case .procedureStarted:
                if let id = event.payload?["procedure_id"]?.value as? String {
                    if procStepIds[id] == nil { procStepIds[id] = []; procOrder.append(id) }
                }
            case .procedureStep:
                if let id = event.payload?["procedure_id"]?.value as? String,
                   let stepId = event.payload?["step_id"]?.value as? String {
                    procStepIds[id, default: []].insert(stepId)
                    if procOrder.contains(id) == false { procOrder.append(id) }
                }
            case .procedureCompleted:
                if let id = event.payload?["procedure_id"]?.value as? String {
                    procOutcome[id] = event.payload?["outcome"]?.value as? String
                }
            default:
                break
            }
        }

        let proceduresRun: [SessionExport.ProcedureRun] = procOrder.map { id in
            .init(procedureId: id, stepsCompleted: procStepIds[id]?.count ?? 0, outcome: procOutcome[id])
        }

        return SessionExport(
            sessionId: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            vault: session.vaultId,
            vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId,
            assetId: session.assetId,
            mode: session.mode.rawValue,
            outcome: session.outcome.rawValue,
            billableMinutes: Int((session.billableSeconds / 60.0).rounded()),
            location: session.startLocation.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            transcript: transcript,
            photos: photos,
            proceduresRun: proceduresRun,
            citations: citations,
            escalations: escalations
        )
    }

    private static func readEvents(_ url: URL, decoder: JSONDecoder) -> [SessionLogger.Event] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionLogger.Event.self, from: data)
        }
    }

    // MARK: - JSON

    static func writeJSON(_ document: SessionExport, to dir: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = dir.appendingPathComponent("audit_export.json")
        try encoder.encode(document).write(to: url, options: .atomic)
        return url
    }

    // MARK: - PDF

    static func writePDF(_ document: SessionExport, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("work_order.pdf")
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let layout = PDFLayout(pageRect: pageRect, margin: 50)

        try renderer.writePDF(to: url) { context in
            layout.begin(context)
            layout.heading("Field Assist Session Record")
            layout.body("\(document.vaultName)  •  Session \(document.sessionId.prefix(8))")
            layout.spacer(6)

            layout.section("Summary")
            for line in summaryLines(document) { layout.body(line) }

            if !document.proceduresRun.isEmpty {
                layout.section("Procedures")
                for run in document.proceduresRun {
                    let outcome = run.outcome ?? "in progress"
                    layout.body("• \(run.procedureId) — \(run.stepsCompleted) step(s), outcome: \(outcome)")
                }
            }

            if !document.escalations.isEmpty {
                layout.section("Escalations")
                for esc in document.escalations {
                    layout.body("• [\(Self.time(esc.timestamp))] \(esc.reason)")
                }
            }

            if !document.photos.isEmpty {
                layout.section("Photos")
                for photo in document.photos {
                    layout.body("• \(photo.path)\(photo.caption.map { " — \($0)" } ?? "")")
                }
            }

            if !document.citations.isEmpty {
                layout.section("Sources Cited")
                let uniqueSources = Set(document.citations.map { $0.source }).sorted()
                for source in uniqueSources { layout.body("• \(source)") }
            }

            if !document.transcript.isEmpty {
                layout.section("Transcript")
                for entry in document.transcript {
                    let who = entry.role == "technician" ? "Technician" : "Assistant"
                    layout.body("[\(Self.time(entry.timestamp))] \(who): \(entry.text)")
                }
            }
        }
        return url
    }

    private static func summaryLines(_ d: SessionExport) -> [String] {
        var lines = [
            "Asset: \(d.assetId ?? "—")",
            "Mode: \(d.mode)",
            "Outcome: \(d.outcome)",
            "Started: \(dateTime(d.startedAt))",
            "Ended: \(d.endedAt.map(dateTime) ?? "—")",
            "Billable time: \(d.billableMinutes) min"
        ]
        if let loc = d.location {
            lines.append("Location: \(String(format: "%.5f", loc.latitude)), \(String(format: "%.5f", loc.longitude))")
        }
        return lines
    }

    private static func dateTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: date)
    }

    private static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium
        return f.string(from: date)
    }
}

// MARK: - PDF layout helper

/// Minimal top-down text layout with automatic pagination for `UIGraphicsPDFRenderer`.
private final class PDFLayout {
    private let pageRect: CGRect
    private let margin: CGFloat
    private var context: UIGraphicsPDFRendererContext!
    private var cursorY: CGFloat = 0

    private var contentWidth: CGFloat { pageRect.width - margin * 2 }
    private var pageBottom: CGFloat { pageRect.height - margin }

    init(pageRect: CGRect, margin: CGFloat) {
        self.pageRect = pageRect
        self.margin = margin
    }

    func begin(_ context: UIGraphicsPDFRendererContext) {
        self.context = context
        newPage()
    }

    func heading(_ text: String) {
        draw(text, font: .boldSystemFont(ofSize: 18), color: .black, spacingAfter: 8)
    }

    func section(_ text: String) {
        spacer(6)
        draw(text, font: .boldSystemFont(ofSize: 13), color: .black, spacingAfter: 4)
    }

    func body(_ text: String) {
        draw(text, font: .systemFont(ofSize: 10.5), color: .black, spacingAfter: 3)
    }

    func spacer(_ height: CGFloat) {
        cursorY += height
    }

    private func draw(_ text: String, font: UIFont, color: UIColor, spacingAfter: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs, context: nil
        )
        if cursorY + bounding.height > pageBottom { newPage() }
        (text as NSString).draw(
            in: CGRect(x: margin, y: cursorY, width: contentWidth, height: bounding.height),
            withAttributes: attrs
        )
        cursorY += bounding.height + spacingAfter
    }

    private func newPage() {
        context.beginPage()
        cursorY = margin
    }
}
