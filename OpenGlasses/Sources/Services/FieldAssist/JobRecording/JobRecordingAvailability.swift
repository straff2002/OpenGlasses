import Foundation

/// Whether "Record this job" may be offered and used right now, and if not, why (Plan HE §1, §5).
///
/// Everything that stands in the way is decided here, in one place, so the button, the start and
/// the running recording cannot disagree. It fails closed: a fact that is not known to be in
/// favour counts against.
///
/// Three answers:
///
/// - **not offered** — the phone has no office to record for: the build carries no office
///   transport, Field Assist is not unlocked, or the phone is not currently paired with an office.
///   The option is not shown at all.
/// - **unavailable** — offered, and refused with a sentence that says why.
/// - **available**.
///
/// Pure: every fact is an input.
enum JobRecordingAvailability {

    struct Facts: Equatable, Sendable {
        /// The build links the office transport.
        var officeTransportInBuild: Bool
        var fieldAssistEntitled: Bool
        /// The pairing with the office verified again just now.
        var officeBindingCurrent: Bool

        var organizationForbidsRecording: Bool
        var organizationRequiresBlur: Bool
        /// Whether this version of the app can blur a recording before it is sent. It cannot yet.
        var blurPassAvailable = false

        var medicalComplianceMode: Bool
        /// The medical local-only rule refuses the route a recording takes to the office.
        var officeRouteRefused: Bool

        var jobIsOpen: Bool
        /// The open job already has a recording, sealed or waiting to be.
        var jobAlreadyRecorded: Bool
        /// Media held for recordings the office has not acknowledged, sealed or not.
        var unsyncedBytes: Int64
    }

    enum Reason: Equatable, CaseIterable, Sendable {
        case medicalComplianceMode
        case officeRouteRefused
        case forbiddenByOrganization
        /// The organisation requires faces blurred before a recording is sent, and that cannot be
        /// done yet — so nothing is recorded, rather than recorded and held or sent unblurred.
        case blurRequiredButNotPossible
        case noOpenJob
        case alreadyRecorded
        case unsyncedLimitReached

        /// The reason as a sentence for the technician.
        var explanation: String {
            switch self {
            case .medicalComplianceMode:
                return "Jobs can't be recorded while Medical Compliance is on."
            case .officeRouteRefused:
                return "Medical Local Only is on, so a recording could not be sent to the office. Jobs can't be recorded while it is on."
            case .forbiddenByOrganization:
                return "Your organisation doesn't allow jobs to be recorded."
            case .blurRequiredButNotPossible:
                return "Your organisation requires faces to be blurred before a recording goes to the office, and this version of the app can't do that yet. So this job can't be recorded."
            case .noOpenJob:
                return "There's no job open to record."
            case .alreadyRecorded:
                return "This job already has a recording."
            case .unsyncedLimitReached:
                return RetentionDecision.unsyncedLimitNote
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        /// No office to record for. The option is not shown.
        case notOffered
        case unavailable(Reason)
        case available

        var isAvailable: Bool { self == .available }
    }

    static func evaluate(_ facts: Facts, limits: RetentionDecision.Limits = .standard) -> Verdict {
        guard facts.officeTransportInBuild, facts.fieldAssistEntitled, facts.officeBindingCurrent else {
            return .notOffered
        }
        if let reason = reasons(facts, limits: limits).first { return .unavailable(reason) }
        return .available
    }

    /// Everything in the way of a phone that has an office, in the order it is named: what the
    /// person cannot change first, then what they can.
    static func reasons(_ facts: Facts, limits: RetentionDecision.Limits = .standard) -> [Reason] {
        var reasons: [Reason] = []
        if facts.medicalComplianceMode { reasons.append(.medicalComplianceMode) }
        if facts.officeRouteRefused { reasons.append(.officeRouteRefused) }
        if facts.organizationForbidsRecording { reasons.append(.forbiddenByOrganization) }
        if facts.organizationRequiresBlur, !facts.blurPassAvailable { reasons.append(.blurRequiredButNotPossible) }
        if !facts.jobIsOpen { reasons.append(.noOpenJob) }
        if facts.jobAlreadyRecorded { reasons.append(.alreadyRecorded) }
        if RetentionDecision.mayStartRecording(unsyncedBytes: facts.unsyncedBytes, limits: limits) != .allowed {
            reasons.append(.unsyncedLimitReached)
        }
        return reasons
    }

    /// Whether a recording that is already running must stop: something it may not run under has
    /// come into force since it started. The job closing and the size limit are the recorder's own
    /// to notice.
    static func mustStop(_ facts: Facts) -> Reason? {
        if facts.medicalComplianceMode { return .medicalComplianceMode }
        if facts.officeRouteRefused { return .officeRouteRefused }
        if facts.organizationForbidsRecording { return .forbiddenByOrganization }
        if facts.organizationRequiresBlur, !facts.blurPassAvailable { return .blurRequiredButNotPossible }
        return nil
    }
}
