import Foundation

/// Jobs ahead, decided without SwiftUI (Plan FO §7, P3c). The rows themselves are the Jobs list's
/// Scheduled section since Plan HC (`JobListComposer`); what is left here is the provenance line a
/// row and the job's page share, and why Start is unavailable.
enum UpcomingJobsModel {

    static func provenanceLine(_ provenance: JobFileProvenance?) -> String? {
        guard let provenance else { return nil }
        if provenance.connector == "workiz" { return "Workiz" }
        switch provenance.signature {
        case .signed: return String(localized: "Signed by \(provenance.signer ?? String(localized: "your organisation"))")
        case .unsigned, .unverifiable: return String(localized: "Job file — not signed")
        }
    }

    /// Why Start is unavailable on a job ahead, or nil when it is available.
    static func startBlockedReason(jobOpen: Bool, vaultUnlocked: Bool, vaultName: String) -> String? {
        if jobOpen { return String(localized: "Finish the job that's open before starting this one.") }
        if !vaultUnlocked {
            return String(localized: "\(vaultName) is locked. Unlock it under Settings → Field Assist before starting a job.")
        }
        return nil
    }
}
