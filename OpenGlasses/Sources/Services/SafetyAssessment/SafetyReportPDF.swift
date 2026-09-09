import UIKit

/// Renders a HECA `SafetyReport` to a one-page, work-order-style PDF for export/audit
/// (docs/plans/safety-assessment.md). Advisory only — verify on site; not a certified inspection.
enum SafetyReportPDF {

    /// Render the report to PDF data (US Letter, single page).
    static func data(for report: SafetyReport) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 50
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let df = DateFormatter()
        df.dateStyle = .long
        df.timeStyle = .short

        return renderer.pdfData { ctx in
            ctx.beginPage()

            let title = "Safety Assessment — High-Energy Control Assessment"
            title.draw(at: CGPoint(x: margin, y: margin), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black])

            let scoreLine: String
            if let score = report.score {
                let direct = report.present.filter { $0.controlStatus == .direct }.count
                scoreLine = "HECA score: \(Int((score * 100).rounded()))%  (\(direct)/\(report.present.count) present hazards directly controlled)"
            } else {
                scoreLine = "No high-energy hazards detected."
            }
            let meta = "\(df.string(from: report.createdAt))\n\(scoreLine)"
            meta.draw(at: CGPoint(x: margin, y: margin + 22), withAttributes: [
                .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray])

            let separatorY = margin + 64
            ctx.cgContext.setStrokeColor(UIColor.lightGray.cgColor)
            ctx.cgContext.move(to: CGPoint(x: margin, y: separatorY))
            ctx.cgContext.addLine(to: CGPoint(x: pageRect.width - margin, y: separatorY))
            ctx.cgContext.strokePath()

            let body = NSAttributedString(string: bodyText(report), attributes: [
                .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.black])
            body.draw(in: CGRect(x: margin, y: separatorY + 12,
                                 width: pageRect.width - margin * 2,
                                 height: pageRect.height - separatorY - margin - 12))
        }
    }

    /// Stage the PDF into a protected export session and return its lease.
    ///
    /// The report names a worksite, its hazards and what is or is not controlled there, so it goes
    /// through the same staging every other export now does: protected and backup-excluded before
    /// the first byte, removed whole if the write or an attribute fails, and released when the
    /// share ends, the app backgrounds or the TTL passes. The previous behaviour — an
    /// `HECA-<id>.pdf` left in the shared temporary directory under its own report id — is what
    /// this replaces.
    @MainActor
    static func makeLease(for report: SafetyReport,
                          coordinator: StagedExportCoordinator? = nil) throws -> StagedExportLease {
        let lease = try (coordinator ?? .safetyReport).makeLease(data: data(for: report),
                                              fileExtension: "pdf",
                                              displayName: "HECA-\(report.id).pdf",
                                              fallbackName: "safety-report.pdf")
        PrivacyLog.transfer(.safetyExport, .exported, count: report.present.count)
        return lease
    }

    // MARK: - Body

    private static func bodyText(_ report: SafetyReport) -> String {
        var lines: [String] = []
        if !report.summary.isEmpty { lines.append(report.summary); lines.append("") }

        if report.present.isEmpty {
            lines.append("No high-energy hazards present in the scene.")
        } else {
            lines.append("PRESENT HAZARDS")
            for f in report.present {
                let tag = f.controlStatus.rawValue.uppercased()
                let control = f.controlStatus == .direct ? f.directControl
                    : (f.controlStatus == .indirect ? f.indirectControl : "no control")
                var line = "[\(tag)] \(f.hazard.displayName) — \(control.isEmpty ? "—" : control)"
                if !f.comments.isEmpty { line += " (\(f.comments))" }
                lines.append(line)
            }
        }

        let notPresent = report.findings.filter { !$0.isPresent }.map { $0.hazard.displayName }
        if !notPresent.isEmpty {
            lines.append("")
            lines.append("NOT PRESENT: " + notPresent.joined(separator: ", "))
        }

        lines.append("")
        lines.append("Advisory only — verify on site. Not a certified safety inspection.")
        return lines.joined(separator: "\n")
    }
}
