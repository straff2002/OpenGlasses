import Foundation
import UIKit

/// The handover for an expert without the app: plain text and a PDF, rendered from the same
/// `ExpertHandover` the `.ogcase` carries (Plan KM P1), so the three can never disagree.
///
/// Nothing is added on the way: no rate (there is none to add), no model name, no prompt sizes, no
/// page image. The PDF draws the job's own photos — the blurred copies the package holds — and
/// names manual pages by title, page and section only.
enum ExpertHandoverRendering {

    static let title = "Job handover"

    /// What the expert reads first, in every rendering.
    static func lede(_ handover: ExpertHandover) -> String {
        "\(handover.organisation.confidentiality). Sent by the technician for advice on this job. "
            + "The conversation is the phone's speech-to-text and AI-generated replies, not checked by "
            + "anyone. Faces in the photos are blurred. Keep it for \(handover.retentionDays) days after "
            + "you finish, then delete it."
    }

    // MARK: - Text

    static func text(_ handover: ExpertHandover, timeZone: TimeZone = .current) -> String {
        let format = Format(timeZone: timeZone)
        var out: [String] = []
        let reference = handover.job.reference.map { "Job \($0)" } ?? "Job (no number)"
        out.append("\(title) — \(reference) — update \(handover.generation)")
        out.append("For \(handover.expert.name) · \(format.dateTime(handover.createdAt))")
        out.append("")
        out.append(lede(handover))
        if let question = handover.question {
            out += ["", "The question", question]
        }
        out += ["", "The job"]
        out += jobLines(handover)
        out += ["", "The work so far"]
        out += workLines(handover, format: format)
        out += ["", "Manuals referred to (by reference only)"]
        out += handover.manualReferences.isEmpty ? ["None."] : handover.manualReferences.map { "• " + referenceLine($0) }
        out += ["", "Photos"]
        out += photoLines(handover, format: format)
        out += ["", "The conversation"]
        if handover.conversation.included {
            for line in handover.conversation.lines {
                out.append("[\(format.time(line.at))] \(line.speaker): \(line.text)")
            }
        } else {
            out.append("Not included with this handover.")
        }
        out += ["", "Handover \(handover.handoverId), update \(handover.generation). A later update replaces this one."]
        return out.joined(separator: "\n") + "\n"
    }

    static func jobLines(_ handover: ExpertHandover) -> [String] {
        let job = handover.job
        var lines: [String] = []
        if let reference = job.reference { lines.append("Reference: \(reference)") }
        if !job.trades.isEmpty { lines.append("Trade: \(job.trades.joined(separator: ", "))") }
        if let site = job.site {
            if let address = site.address { lines.append("Site: \(address)") }
            else if let town = site.town { lines.append("Site: \(town)") }
        }
        if let fault = job.faultReport { lines.append("Fault reported (\(fault.source)): \(fault.text)") }
        if let unit = job.unit {
            if let model = unit.model { lines.append("Unit: \(model)" + (unit.matchedSection.map { " (manual section \($0))" } ?? "")) }
            for field in unit.identity { lines.append("\(field.name): \(field.value) (\(field.source))") }
        }
        return lines.isEmpty ? ["Nothing recorded yet."] : lines
    }

    static func workLines(_ handover: ExpertHandover, format: Format) -> [String] {
        let work = handover.work
        var lines: [String] = []
        for task in work.tasks {
            lines.append("• \(task.title) — \(statusWords(task.status))" + (task.note.map { ": \($0)" } ?? ""))
        }
        for run in work.procedures {
            let outcome = run.outcome.map { ", ended: \($0)" } ?? ", in progress"
            lines.append("• Procedure \(run.procedure): \(run.stepsDone) step\(run.stepsDone == 1 ? "" : "s") done\(outcome)")
        }
        if !work.readings.isEmpty {
            lines.append("Readings:")
            for reading in work.readings {
                let value = reading.unit.map { "\(reading.value) \($0)" } ?? reading.value
                lines.append("  \(reading.quantity): \(value) (\(reading.source), \(format.time(reading.at)))")
            }
        }
        if !work.deviations.isEmpty {
            lines.append("Done differently:")
            lines += work.deviations.map { "  \($0)" }
        }
        if !work.ruledOut.isEmpty {
            lines.append("Ruled out, as the technician said:")
            lines += work.ruledOut.map { "  \($0)" }
        }
        return lines.isEmpty ? ["Nothing recorded yet."] : lines
    }

    static func photoLines(_ handover: ExpertHandover, format: Format) -> [String] {
        var lines = handover.photos.enumerated().map { index, photo in
            "\(index + 1). \(format.time(photo.capturedAt))" + (photo.caption.map { " — \($0)" } ?? "")
        }
        if lines.isEmpty { lines.append("None with this handover.") }
        return lines + leftOutLines(handover)
    }

    static func leftOutLines(_ handover: ExpertHandover) -> [String] {
        var lines: [String] = []
        let left = handover.photosLeftOut
        if left.couldNotBeBlurred > 0 {
            lines.append("\(left.couldNotBeBlurred) more couldn't be blurred, so they stayed on the technician's phone.")
        }
        if left.overSizeLimit > 0 {
            lines.append("\(left.overSizeLimit) older one\(left.overSizeLimit == 1 ? "" : "s") didn't fit and stayed on the technician's phone.")
        }
        return lines
    }

    static func referenceLine(_ reference: ExpertHandover.ManualReference) -> String {
        var parts = [reference.title]
        if let page = reference.page { parts.append("page \(page)") }
        if let section = reference.section { parts.append(section) }
        return parts.joined(separator: ", ")
    }

    static func statusWords(_ raw: String) -> String {
        switch raw {
        case "in_progress": return "in progress"
        default: return raw
        }
    }

    // MARK: - PDF

    /// Write the PDF. `photos` maps each `ExpertHandover.Photo.file` to its JPEG — the blurred
    /// copies the package carries, and nothing else.
    ///
    /// Stamped as holding AI-generated content, with **no model named**: which model answered is
    /// a troubleshooting detail, and those never go to an expert.
    @MainActor
    static func writePDF(_ handover: ExpertHandover, photos: [String: Data], to url: URL,
                         timeZone: TimeZone = .current) throws {
        let format = Format(timeZone: timeZone)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let stamp = PDFProvenanceStamp.aiGenerated(
            provenance: nil, title: title, composite: true,
            unrecordedSubject: "Job handover: the job's record, the technician's speech-to-text and AI-generated replies.")
        let rendererFormat = UIGraphicsPDFRendererFormat()
        rendererFormat.documentInfo = stamp.documentInfo
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: rendererFormat)
        let layout = PDFLayout(pageRect: pageRect, margin: 50)
        try renderer.writePDF(to: url) { context in
            stamp.apply(to: context.cgContext)
            layout.begin(context)
            let reference = handover.job.reference.map { "Job \($0)" } ?? "Job (no number)"
            layout.heading("\(title) — \(reference)")
            layout.body("For \(handover.expert.name) · update \(handover.generation) · \(format.dateTime(handover.createdAt))")
            layout.caption(lede(handover))
            if let question = handover.question {
                layout.section("The question")
                layout.body(question)
            }
            layout.section("The job")
            jobLines(handover).forEach(layout.body)
            layout.section("The work so far")
            workLines(handover, format: format).forEach(layout.body)
            layout.section("Manuals referred to (by reference only)")
            if handover.manualReferences.isEmpty { layout.body("None.") }
            handover.manualReferences.forEach { layout.body("• " + referenceLine($0)) }
            layout.section("Photos")
            for (index, photo) in handover.photos.enumerated() {
                if let data = photos[photo.file], let image = UIImage(data: data) {
                    layout.image(image)
                }
                layout.caption("\(index + 1). \(format.time(photo.capturedAt))" + (photo.caption.map { " — \($0)" } ?? ""))
            }
            if handover.photos.isEmpty { layout.body("None with this handover.") }
            leftOutLines(handover).forEach(layout.body)
            layout.section("The conversation")
            if handover.conversation.included {
                for line in handover.conversation.lines {
                    layout.body("[\(format.time(line.at))] \(line.speaker): \(line.text)")
                }
            } else {
                layout.body("Not included with this handover.")
            }
            layout.spacer(6)
            layout.caption("Handover \(handover.handoverId), update \(handover.generation). A later update replaces this one.")
        }
    }

    // MARK: - Dates

    struct Format {
        let timeZone: TimeZone

        func dateTime(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.timeZone = timeZone
            formatter.dateFormat = "d MMM yyyy, HH:mm"
            return formatter.string(from: date)
        }

        func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_GB")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }
}
