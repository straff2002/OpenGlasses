import Foundation

/// Whether "Record experience" is offered and usable right now, and if not, why (Plan IM P1).
///
/// One place, so the Job tab, Field Assist settings, the CarPlay Jobs list and the recorder itself
/// cannot disagree. Pure: every fact is an input. It fails closed.
///
/// - **Medical Compliance withholds it**, as it withholds `team_learning` (`Config.hipaaDisabledTools`):
///   a clinical site's "experience" is patient notes by another name. Not shown at all.
/// - **Field Assist off**: not shown — there is no vault for a recording to be about.
/// - **The `.teamLearnings` capability** is the gate, as it is for filing a candidate: a licence that
///   does not include team learnings is not shown the recorder; one that has lapsed or cannot be
///   checked is shown it, refused with a sentence.
///
/// Plan IP's organisation feature switch does not exist yet (its plan is drafted, nothing built), so
/// the capability is the only organisation-level gate; IP adds its switch here.
enum ExperienceRecordingAvailability {

    struct Facts: Equatable, Sendable {
        var fieldAssistActive: Bool
        var medicalComplianceMode: Bool
        var capability: FieldAssistCapabilityCheck
    }

    enum Verdict: Equatable, Sendable {
        /// Not shown anywhere.
        case notOffered
        /// Shown, and refused with this sentence.
        case unavailable(String)
        case available

        var isOffered: Bool { self != .notOffered }
        var isAvailable: Bool { self == .available }

        /// What the recorder says when asked to start and it cannot.
        var refusal: String? {
            switch self {
            case .available: return nil
            case .unavailable(let reason): return reason
            case .notOffered: return String(localized: "Recording experience isn't available on this phone.")
            }
        }
    }

    /// The tool whose Medical Compliance withholding this follows, so the two cannot drift apart.
    static let withheldAlongside = "team_learning"

    static func verdict(_ facts: Facts) -> Verdict {
        guard !facts.medicalComplianceMode else { return .notOffered }
        guard facts.fieldAssistActive else { return .notOffered }
        switch facts.capability {
        case .granted:
            return .available
        case .notIncluded:
            return .notOffered
        case .denied(.expired):
            return .unavailable(String(localized: "Your Field Assist access has lapsed. Enter a renewal code from your administrator to record experience again."))
        case .denied(.seatUnavailable(let hold)):
            return .unavailable(hold.message)
        case .denied(.unverifiableLicense):
            return .unavailable(String(localized: "Your Field Assist licence can't be checked right now, so nothing can be recorded. Try again when the phone is online."))
        case .denied(.noEvidence):
            return .unavailable(String(localized: "Recording experience needs the team or enterprise licence code your organisation issued."))
        }
    }

    /// The facts as the app holds them now.
    @MainActor
    static func current() -> Verdict {
        verdict(Facts(fieldAssistActive: Config.fieldAssistActive,
                      medicalComplianceMode: Config.hipaaMode
                          && Config.hipaaDisabledTools.contains(withheldAlongside),
                      capability: FieldAssistEntitlement.shared.check(.teamLearnings)))
    }
}
