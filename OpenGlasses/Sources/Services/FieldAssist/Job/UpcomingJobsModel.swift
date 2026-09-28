import Foundation

/// The Job tab's Upcoming section, decided without SwiftUI (Plan FO §7, P3c).
///
/// One glance per row: the number (or the site, when there is none), where and when, and — for a
/// job that arrived as a file — whether it was signed. The fault report is on the job's own page,
/// not on the list.
enum UpcomingJobsModel {

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String?
        /// "Signed by Smith Refrigeration", "Job file — not signed", or nil for a job the
        /// technician added themselves.
        let provenance: String?
        let isSigned: Bool

        /// The whole row as one VoiceOver sentence.
        var spoken: String {
            [title, detail, provenance].compactMap { $0 }.joined(separator: ", ")
        }
    }

    static func rows(_ jobs: [UpcomingJob]) -> [Row] {
        jobs.map { job in
            var detail: [String] = []
            if job.jobReference != nil, let headline = job.site.headline { detail.append(headline) }
            if let scheduled = job.scheduledFor {
                detail.append(scheduled.formatted(date: .abbreviated, time: .shortened))
            }
            return Row(id: job.id,
                       title: job.title,
                       detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
                       provenance: provenanceLine(job.provenance),
                       isSigned: job.provenance?.signature == .signed)
        }
    }

    static func provenanceLine(_ provenance: JobFileProvenance?) -> String? {
        guard let provenance else { return nil }
        switch provenance.signature {
        case .signed: return "Signed by \(provenance.signer ?? "your organisation")"
        case .unsigned, .unverifiable: return "Job file — not signed"
        }
    }

    /// Why Start is unavailable on a job ahead, or nil when it is available.
    static func startBlockedReason(jobOpen: Bool, vaultUnlocked: Bool, vaultName: String) -> String? {
        if jobOpen { return "Finish the job that's open before starting this one." }
        if !vaultUnlocked {
            return "\(vaultName) is locked. Unlock it under Settings → Field Assist before starting a job."
        }
        return nil
    }
}
