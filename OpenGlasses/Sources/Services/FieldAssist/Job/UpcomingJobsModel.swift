import Foundation

/// Jobs ahead, decided without SwiftUI (Plan FO §7, P3c). The rows themselves are the Jobs list's
/// Scheduled section since Plan HC (`JobListComposer`); what is left here is the provenance line a
/// row and the job's page share, and why Start is unavailable.
enum UpcomingJobsModel {

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
