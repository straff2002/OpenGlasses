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
        case notEntitled

        var errorDescription: String? {
            switch self {
            case .sessionNotFound(let url): return "No session found at \(url.lastPathComponent)."
            case .metadataUnreadable: return "Session metadata could not be read."
            case .notEntitled: return "Field Assist isn't unlocked on this device."
            }
        }
    }

    /// Produce the requested export artifacts in protected staging; returns a lease per artifact.
    ///
    /// Entitlement is enforced here rather than only at the settings screen: the export tool and the
    /// session service both reach this directly. Once entitlement is revoked no new artifact is
    /// produced.
    ///
    /// The artifacts used to be written into the session directory, unprotected and included in
    /// backups, and left there indefinitely. They are *derived*: the durable record is the
    /// session's own `session.json` + `log.jsonl`, and `buildExport` rebuilds an identical
    /// document from them at any time. So the shareable copy now lives on a lease — protected and
    /// backup-excluded before its first byte, removed whole on a write or attribute failure,
    /// released when the share ends or the app backgrounds, and swept after its TTL — and nothing
    /// the engineer owns is lost by that, because re-exporting reproduces it.
    @discardableResult
    static func export(sessionDir: URL,
                       formats: Set<Format> = [.json, .pdf],
                       coordinator: StagedExportCoordinator? = nil,
                       provenance: AIProvenance? = nil,
                       sessionOverride: FieldSession? = nil,
                       clipPlan: ClipDeliveryPlan = .undecided) throws -> [StagedExportLease] {
        let coordinator = coordinator ?? .fieldSession
        // Audited export is a team capability; the session log itself stays on the device at any tier.
        guard FieldAssistEntitlement.shared.isGranted(atLeast: .team) else {
            throw ExportError.notEntitled
        }
        guard FileManager.default.fileExists(atPath: sessionDir.path) else {
            throw ExportError.sessionNotFound(sessionDir)
        }
        guard let document = buildExport(sessionDir: sessionDir, provenance: provenance,
                                         sessionOverride: sessionOverride,
                                         clipPlan: clipPlan) else {
            throw ExportError.metadataUnreadable
        }
        var leases: [StagedExportLease] = []
        do {
            if formats.contains(.json) {
                leases.append(try coordinator.makeLease(
                    fileExtension: "json", displayName: "audit_export.json",
                    fallbackName: "audit_export.json") { try writeJSON(document, to: $0) })
            }
            if formats.contains(.pdf) {
                // The evidence the technician chose is drawn from the session's own `photos/`
                // directory — the filtered copies, downscaled here and nowhere else.
                let photos = sessionDir.appendingPathComponent("photos", isDirectory: true)
                leases.append(try coordinator.makeLease(
                    fileExtension: "pdf", displayName: "work_order.pdf",
                    fallbackName: "work_order.pdf") {
                        try writePDF(document, to: $0, photosDirectory: photos,
                                     clipPlan: clipPlan)
                    })
            }
        } catch {
            // Partial failure leaves no half-made export set: the artifact that did succeed is
            // released before the error surfaces.
            leases.forEach { coordinator.release($0) }
            throw error
        }
        PrivacyLog.transfer(.fieldSessionExport, .exported, count: leases.count)
        return leases
    }

    // MARK: - Reconstruction

    /// Reconstruct the consolidated export from the session metadata + append-only event log.
    static func buildExport(sessionDir: URL, provenance: AIProvenance? = nil,
                            sessionOverride: FieldSession? = nil,
                            clipPlan: ClipDeliveryPlan = .undecided) -> SessionExport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session: FieldSession
        if let sessionOverride, sessionOverride.id == sessionDir.lastPathComponent {
            session = sessionOverride
        } else {
            guard let metaData = try? Data(contentsOf: sessionDir.appendingPathComponent("session.json")),
                  let decoded = try? decoder.decode(FieldSession.self, from: metaData) else {
                return nil
            }
            session = decoded
        }
        let events = readEvents(sessionDir.appendingPathComponent("log.jsonl"), decoder: decoder)
        // What the technician did about the answers' citations. Collected first because a citation
        // is opened after the answer that carried it was written (Plan EK P3).
        let checks = CitationChecks(events: events)

        var transcript: [SessionExport.TranscriptEntry] = []
        var photos: [SessionExport.PhotoRef] = []
        var captures: [SessionExport.CaptureRun] = []
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
                // Every source this answer named: the ones the caller passed, plus the `Source:`
                // lines in the answer itself, which is where a manual citation actually lives.
                var named = (event.payload?["citations"]?.value as? [Any])?.compactMap { $0 as? String } ?? []
                named += CitationLineParser.parse(event.text ?? "").map(\.label)
                var seen = Set<String>()
                for source in named where seen.insert(source).inserted {
                    citations.append(checks.citation(timestamp: event.timestamp, source: source, claim: event.text))
                }
            case .citation:
                if let source = event.payload?["source"]?.value as? String {
                    citations.append(checks.citation(
                        timestamp: event.timestamp, source: source,
                        claim: event.payload?["claim"]?.value as? String ?? event.text))
                }
            case .photoAttached:
                if let path = event.payload?["path"]?.value as? String {
                    photos.append(.init(timestamp: event.timestamp, path: path,
                                        caption: (event.payload?["caption"]?.value as? String) ?? event.text))
                }
            case .evidenceSelected:
                // The decision itself is session state, read below. The event is there so the
                // append-only log says when it was made, not so the export re-derives it.
                break
            case .escalationRequested:
                escalations.append(.init(timestamp: event.timestamp, reason: event.text ?? "Escalation requested"))
            case .captureRecordSaved:
                if let flowId = event.payload?["flow_id"]?.value as? String {
                    let fields = (event.payload?["fields"]?.value as? [Any] ?? []).compactMap { raw -> SessionExport.CaptureRun.Field? in
                        guard let dict = raw as? [String: Any], let field = dict["field"] as? String else { return nil }
                        return .init(field: field,
                                     value: dict["value"] as? String ?? "",
                                     method: dict["method"] as? String ?? "")
                    }
                    captures.append(.init(timestamp: event.timestamp, flowId: flowId,
                                          assetId: event.payload?["asset_id"]?.value as? String,
                                          fields: fields))
                }
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

        // What the technician chose at close (Plan FO P2a). Applied to the reconstructed list
        // rather than replacing it: every photo the job took stays in the audit JSON, and what the
        // selection adds is whether each one travelled and how it was marked.
        if let selection = session.evidenceSelection, selection.reviewed {
            photos = photos.map { photo in
                let entry = selection.entry(for: photo.path)
                return .init(timestamp: photo.timestamp, path: photo.path,
                             caption: entry?.caption ?? photo.caption,
                             included: entry?.included ?? false,
                             role: entry?.role?.rawValue)
            }
        }

        return SessionExport(
            sessionId: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            vault: session.vaultId,
            vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId,
            assetId: session.assetId,
            equipment: session.equipment.map(SessionExport.Equipment.init),
            mode: session.mode.rawValue,
            outcome: session.outcome.rawValue,
            billableSeconds: session.billableSeconds,
            billableMinutes: Int((session.billableSeconds / 60.0).rounded()),
            billingBasis: session.billingBasis,
            minutesPerBillingUnit: session.minutesPerBillingUnit,
            billableUnits: session.billingBasis == .units
                ? FieldAssistBillingBasis.units(for: session.billableSeconds,
                                                minutesPerUnit: session.minutesPerBillingUnit)
                : nil,
            location: session.startLocation.map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            transcript: transcript,
            photos: photos,
            clips: clipRefs(session: session, plan: clipPlan),
            proceduresRun: proceduresRun,
            captures: captures,
            citations: citations,
            escalations: escalations,
            // Assembled from the session itself, not from the log: the tasks, parts and identity
            // fields are session state, so the exported record and the read-back the technician
            // confirmed are the same object rendered twice.
            workRecord: WorkRecord(
                session: session,
                vaultName: VaultRegistry.shared.manifest(id: session.vaultId)?.name ?? session.vaultId),
            // The record contains machine-written turns, so it says which machine wrote them. The
            // digest identifies the instruction version; the instructions themselves — and the
            // manual pages the answers cited — stay out of the export.
            provenance: provenance ?? AIProvenance.forActiveModel(
                promptSources: [FieldAssistProvenance.promptIdentity])
        )
    }

    /// The job's clips for the machine-readable record (Plan FO P2b).
    ///
    /// Built from the session's own catalogue rather than from the log, for the same reason the
    /// work record is: the catalogue is what the review edited and what the selection refers to,
    /// so a reconstruction from events could disagree with the decision the technician made.
    static func clipRefs(session: FieldSession, plan: ClipDeliveryPlan) -> [SessionExport.ClipRef] {
        let selection = session.evidenceSelection
        let reviewed = selection?.reviewed == true
        return session.media.filter { $0.kind == .clip }.map { clip in
            let entry = reviewed ? selection?.entry(for: clip.id) : nil
            let included = reviewed ? (entry?.included ?? false) : nil
            // "Attached" is only a fact once a channel has been chosen. An export taken for the
            // archive says nothing rather than guessing, which is what `nil` is for.
            let attached: Bool? = plan.isEmpty ? nil : plan.isAttached(clip.id)
            return SessionExport.ClipRef(
                timestamp: clip.capturedAt, path: clip.id,
                caption: entry?.caption ?? clip.caption,
                durationSeconds: clip.durationSeconds, bytes: clip.byteCount,
                included: included, role: entry?.role?.rawValue,
                attached: attached, notAttachedReason: plan.reason(for: clip.id),
                cutShort: clip.cutShort)
        }
    }

    private static func readEvents(_ url: URL, decoder: JSONDecoder) -> [SessionLogger.Event] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionLogger.Event.self, from: data)
        }
    }

    // MARK: - JSON

    /// Write the consolidated audit JSON at exactly `url`. The caller owns the location — which is
    /// a protected session directory on every production path.
    static func writeJSON(_ document: SessionExport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    // MARK: - PDF

    /// Render the work order at exactly `url`. As with `writeJSON`, the caller owns the location.
    ///
    /// - Parameter photosDirectory: the session's `photos/` directory, when the evidence the
    ///   technician selected should be drawn into the document. Absent — or with no selection
    ///   made — the photo section is the text bullet list the work order has always printed.
    static func writePDF(_ document: SessionExport, to url: URL,
                         photosDirectory: URL? = nil,
                         clipPlan: ClipDeliveryPlan = .undecided) throws {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = document.provenance?.pdfDocumentInfo ?? [
            kCGPDFContextCreator as String: "OpenGlasses — contains AI-generated content",
            kCGPDFContextSubject as String: "Field session record with AI-generated assistant turns. Model not recorded.",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        let layout = PDFLayout(pageRect: pageRect, margin: 50)

        try renderer.writePDF(to: url) { context in
            layout.begin(context)
            layout.heading("Field Assist Session Record")
            layout.body("\(document.vaultName)  •  Session \(document.sessionId.prefix(8))")
            layout.spacer(6)

            layout.section("Summary")
            for line in summaryLines(document) { layout.body(line) }

            if let record = document.workRecord {
                layout.section("Work Record")
                for line in record.summaryLines { layout.body(line) }
            }

            if !document.proceduresRun.isEmpty {
                layout.section("Procedures")
                for run in document.proceduresRun {
                    let outcome = run.outcome ?? "in progress"
                    layout.body("• \(humanReadable(run.procedureId)) — \(run.stepsCompleted) step(s), outcome: \(humanReadable(outcome))")
                }
            }

            if !document.captures.isEmpty {
                layout.section("Captured Records")
                for capture in document.captures {
                    let asset = capture.assetId.map { " (\($0))" } ?? ""
                    layout.body("• \(humanReadable(capture.flowId))\(asset) — \(capture.fields.count) field(s)")
                    for field in capture.fields {
                        layout.body("    \(humanReadable(field.field)): \(field.value) [\(humanReadable(field.method))]")
                    }
                }
            }

            if !document.escalations.isEmpty {
                layout.section("Escalations")
                for esc in document.escalations {
                    layout.body("• [\(Self.time(esc.timestamp))] \(esc.reason)")
                }
            }

            // The evidence the technician chose at close, drawn inline under its task (Plan FO
            // P2a).
            //
            // Which of the three shapes this takes turns on **whether the review happened**, not
            // on whether anything was selected. A job that never reached the step — skipped, or a
            // record written before any of this existed — gets the bullet list it has always got,
            // unchanged. A job that *was* reviewed gets what was chosen and nothing else: a
            // technician who deliberately left every picture out has not asked for a list of them.
            let reviewed = document.workRecord?.evidenceSelection?.reviewed == true
            let plan = document.workRecord?.evidencePlan ?? EvidenceRenderPlan(groups: [])
            if reviewed {
                if let photosDirectory, !plan.isEmpty {
                    drawEvidence(plan, from: photosDirectory, layout: layout, clipPlan: clipPlan)
                } else if !plan.isEmpty {
                    // Rendered without the files to hand — the audit JSON's own copy of the
                    // record, say. Name what was chosen rather than printing nothing at all.
                    layout.section(plan.clipCount == 0 ? "Photos" : "Photos and clips")
                    for entry in plan.groups.flatMap(\.entries) {
                        layout.body(entry.item.kind == .clip
                                    ? "• " + Self.clipLine(entry, plan: clipPlan)
                                    : "• \(entry.captionLine)")
                    }
                } else if !document.photos.isEmpty {
                    layout.section("Photos")
                    layout.body("No photos were sent with this report.")
                }
            } else if !document.photos.isEmpty {
                layout.section("Photos")
                for photo in document.photos {
                    layout.body("• \(photo.path)\(photo.caption.map { " — \($0)" } ?? "")")
                }
            }

            if !document.citations.isEmpty {
                layout.section("Sources Cited")
                for line in citationLines(document) { layout.body("• \(line)") }
            }

            if !document.transcript.isEmpty {
                layout.section("Transcript")
                for entry in document.transcript {
                    let who = entry.role == "technician" ? "Technician" : "Assistant"
                    layout.body("[\(Self.time(entry.timestamp))] \(who): \(entry.text)")
                }
            }

            layout.section("Provenance")
            layout.body(document.provenance?.footerLine
                ?? "Assistant turns in this record were AI-generated. The model was not recorded.")
        }
    }

    // MARK: - Evidence

    /// Draw the selected evidence: a section, a heading per task, a role heading where the
    /// technician marked one, and each picture with its caption and time underneath.
    ///
    /// The caption, the time and both headings are drawn as **real text**, not baked into the
    /// image — which is as close to an accessible PDF as this layout gets, and is what lets a
    /// reader who cannot see the photograph still find out what it was of and when it was taken.
    private static func drawEvidence(_ plan: EvidenceRenderPlan, from directory: URL,
                                     layout: PDFLayout,
                                     clipPlan: ClipDeliveryPlan = .undecided) {
        // One budget for the whole document, decided from the number of *pictures* actually going
        // out — so a thirty-photo job gets smaller copies rather than an unsendable file. Clips
        // are not drawn and do not enter it.
        let photoCount = plan.photoCount
        let clipCount = plan.clipCount
        let budget = EvidenceImageBudget.standard.plan(photoCount: photoCount)
        layout.section(clipCount == 0 ? "Photos" : "Photos and clips")
        layout.body(Self.evidenceLead(photos: photoCount, clips: clipCount))
        for group in plan.groups {
            layout.subheading(group.title)
            var lastRole: EvidenceSelection.Role??
            for entry in group.entries {
                // Fault before Fix before unmarked, headed once per run rather than once per
                // picture. `lastRole` is doubly optional on purpose: "no role printed yet" and
                // "the unmarked run has started" are different states.
                if lastRole == nil || lastRole! != entry.role {
                    if let role = entry.role { layout.roleHeading(role.heading) }
                    lastRole = .some(entry.role)
                }
                // A clip cannot be drawn into a PDF, so the record **names** it: what it shows,
                // when it was taken, how long it runs, and how it travelled. That last part is why
                // this line exists at all — a customer holding a work order that mentions a clip
                // can ask for the clip; one holding a report that silently omitted it cannot.
                if entry.item.kind == .clip {
                    layout.caption(Self.clipLine(entry, plan: clipPlan))
                    continue
                }
                guard let image = EvidenceImageRenderer.load(entry.item.id, from: directory) else {
                    // The file is gone. Say so rather than leaving a caption floating under
                    // nothing — a record that quietly lost a photograph is worse than one that
                    // admits it.
                    layout.body("• \(entry.captionLine) — picture not found on the device")
                    continue
                }
                layout.image(EvidenceImageRenderer.downscaled(image, plan: budget))
                layout.caption(entry.captionLine)
            }
        }
    }

    /// "3 pictures and one clip selected by the technician." — the sentence under the heading.
    static func evidenceLead(photos: Int, clips: Int) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) picture\(photos == 1 ? "" : "s")") }
        if clips > 0 { parts.append("\(clips) clip\(clips == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return "Nothing was selected by the technician." }
        return parts.joined(separator: " and ") + " selected by the technician."
    }

    /// The line a clip gets instead of a picture: caption, time, length, and how it travelled.
    static func clipLine(_ entry: EvidenceRenderPlan.Entry, plan: ClipDeliveryPlan) -> String {
        var parts: [String] = ["Clip"]
        if let caption = entry.caption, !caption.isEmpty { parts.append(caption) }
        parts.append(entry.item.timeLabel)
        if let length = entry.item.durationLabel { parts.append(length) }
        if entry.item.cutShort { parts.append("cut short") }
        parts.append(plan.travelNote(for: entry.item.id))
        return parts.joined(separator: " · ")
    }

    /// One line per distinct source: what was cited, and whether anybody looked at the page it
    /// names. Plain words rather than the log's raw kinds — a work order is read by a customer.
    static func citationLines(_ d: SessionExport) -> [String] {
        var lines: [String] = []
        var seen = Set<String>()
        for citation in d.citations where seen.insert(citation.source).inserted {
            guard citation.opened else {
                lines.append("\(citation.source) — not opened")
                continue
            }
            let how = citation.origin == "voice" ? "opened by voice" : "opened"
            guard let against = citation.verifiedAgainst, !against.isEmpty else {
                lines.append("\(citation.source) — \(how)")
                continue
            }
            lines.append("\(citation.source) — \(how), read in \(readableSources(against))")
        }
        return lines
    }

    /// "manufacturer_pdf, extracted_text" → "the manufacturer's document, then the extracted text".
    static func readableSources(_ raw: String) -> String {
        let names = raw.split(separator: ",").map { part -> String in
            switch ManualPageRoute(rawValue: part.trimmingCharacters(in: .whitespaces)) {
            case .manufacturerPDF: return "the manufacturer's document"
            case .extractedText: return "the extracted text"
            case .externalURL: return "the manufacturer's published manual"
            case nil: return part.trimmingCharacters(in: .whitespaces)
            }
        }
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + ", then " + names[names.count - 1]
            : (names.first ?? raw)
    }

    /// The summary block, in the order the work order prints it. The machine comes first when the
    /// session knew it: a reviewer reading a refrigerant log or a warranty claim asks what unit
    /// before anything else, and a session that never identified one prints no line at all.
    static func summaryLines(_ d: SessionExport) -> [String] {
        var lines: [String] = []
        if let equipment = d.equipment { lines.append(equipment.sentence) }
        let duration = d.billableSeconds.map { WorkRecord.durationPhrase(seconds: $0) }
            ?? WorkRecord.minutesPhrase(minutes: d.billableMinutes)
        lines += [
            "Asset: \(d.assetId ?? "Not recorded")",
            "Support: \(supportDescription(d.mode))",
            "Status: \(humanReadable(d.outcome))",
            "Started: \(dateTime(d.startedAt))",
            "Ended: \(d.endedAt.map(dateTime) ?? "Session still active")",
            "Time on job: \(duration)"
        ]
        if d.billingBasis == .units,
           let billableUnits = d.billableUnits,
           let minutesPerUnit = d.minutesPerBillingUnit {
            lines.append("Billable units: \(WorkRecord.unitPhrase(billableUnits)) "
                         + "(\(minutesPerUnit) minute\(minutesPerUnit == 1 ? "" : "s") per unit; partial units round up)")
        }
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

    private static func humanReadable(_ raw: String) -> String {
        WorkRecord.prettyLabel(raw)
    }

    private static func supportDescription(_ raw: String) -> String {
        switch FieldSession.Mode(rawValue: raw) {
        case .aiOnly: return FieldSession.Mode.aiOnly.customerDescription
        case .humanAssisted: return FieldSession.Mode.humanAssisted.customerDescription
        case nil: return humanReadable(raw)
        }
    }
}

// MARK: - PDF layout helper

/// Minimal top-down text layout with automatic pagination for `UIGraphicsPDFRenderer`.
///
/// Text only until Plan FO P2a, which added `image(_:)` — the work order could name a photograph
/// but not show one, so the recipient of a fault report got a file path.
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

    /// A task's name above the pictures recorded against it.
    func subheading(_ text: String) {
        spacer(4)
        draw(text, font: .boldSystemFont(ofSize: 11), color: .black, spacingAfter: 3)
    }

    /// "The fault" / "The fix". Only printed for a run the technician actually marked.
    func roleHeading(_ text: String) {
        spacer(2)
        draw(text, font: .italicSystemFont(ofSize: 10.5), color: .darkGray, spacingAfter: 2)
    }

    /// The line under a picture — what it shows and when it was taken. Real text, so it can be
    /// read, searched and extracted.
    func caption(_ text: String) {
        draw(text, font: .systemFont(ofSize: 9), color: .darkGray, spacingAfter: 8)
    }

    /// Draw one evidence picture, aspect-fitted into the column and paginated like everything
    /// else. The image handed in is already the downscaled copy — drawing small does not embed
    /// small, so the resizing happens before this is called, not here.
    func image(_ image: UIImage, maxHeight: CGFloat = 300) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let fit = min(contentWidth / size.width, maxHeight / size.height, 1)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        // A picture is never split across a page break: if it does not fit in what is left, the
        // page ends here and it starts the next one whole.
        if cursorY + drawn.height > pageBottom { newPage() }
        image.draw(in: CGRect(x: margin, y: cursorY, width: drawn.width, height: drawn.height))
        cursorY += drawn.height + 3
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


// MARK: - Citation follow-through

/// What the session's `citation_opened` / `page_verified` events say about each cited source
/// (Plan EK P3). Keyed by the document and page a citation names, so a chip tapped under one answer
/// marks that answer's citation and not a different answer's mention of the same manual's page 4.
struct CitationChecks {

    private var origins: [String: String] = [:]
    private var verifications: [String: [String]] = [:]

    init(events: [SessionLogger.Event]) {
        for event in events {
            guard let document = event.payload?["document"]?.value as? String else { continue }
            let page = event.payload?["page"]?.value as? Int ?? 0
            let key = Self.key(title: document, page: page)
            switch event.kind {
            case .citationOpened:
                if origins[key] == nil {
                    origins[key] = event.payload?["origin"]?.value as? String ?? "chip"
                }
            case .pageVerified:
                let source = event.payload?["source"]?.value as? String ?? ManualPageRoute.extractedText.rawValue
                if verifications[key]?.contains(source) != true {
                    verifications[key, default: []].append(source)
                }
            default:
                continue
            }
        }
    }

    /// Build the export's citation for one source line, carrying whatever the log knows about it.
    func citation(timestamp: Date, source: String, claim: String?) -> SessionExport.Citation {
        let parsed = CitationLineParser.citations(inBody: source).first
        let key = Self.key(title: parsed?.title ?? source, page: parsed?.page ?? 0)
        let verified = verifications[key]
        return SessionExport.Citation(
            timestamp: timestamp, source: source, claim: claim,
            opened: origins[key] != nil || verified != nil,
            origin: origins[key],
            verifiedAgainst: verified?.joined(separator: ", "))
    }

    static func key(title: String, page: Int) -> String {
        "\(title.trimmingCharacters(in: .whitespaces).lowercased())#\(page)"
    }
}
