import Foundation

/// Whether a recorded job may be sent to the office right now, and if not, why (Plan HE §4).
///
/// A recording is large and never urgent, so it waits for the right moment: no medical privacy
/// mode, no organisation rule it does not meet, a current profile, licence and pairing, Wi-Fi
/// (mobile data only when the person allows it and the organisation does not forbid it), power or
/// a well-charged battery, an office that can be reached, and nothing smaller waiting — job
/// reports and receipts always go first.
///
/// Pure: everything it weighs is an input. When several things are in the way it names the first
/// in the order above, which is the order a person would have to put them right.
enum SyncEligibility {

    enum Network: Equatable, Sendable {
        case none, wifi, cellular
    }

    struct Conditions: Equatable, Sendable {
        var network: Network
        /// The person's own choice to let recordings use mobile data. Off unless they turn it on.
        var cellularAllowedByUser = false
        var cellularForbiddenByOrganization = false

        var isCharging: Bool
        /// 0…1, or nil when the phone does not say.
        var batteryLevel: Double?
        /// The phone is saving power or running hot and has asked for large transfers to wait.
        var powerDefersBulkTransfer = false

        var profileIsCurrent: Bool
        var leaseIsCurrent: Bool
        var bindingIsCurrent: Bool

        var medicalModeOn = false
        /// The organisation requires faces blurred before a recording is sent, and what is
        /// waiting has not been blurred. A sealed recording cannot be blurred afterwards — its
        /// manifest is signed — so one sealed before the rule applied stays held for as long as
        /// the rule does.
        var blurRequiredAndNotDone = false
        /// The office is in reach by any route: on its own network, straight across the internet,
        /// or through a relay. A recording waits for Wi-Fi, not for the office's own network, so
        /// one made on a Friday can go from the technician's home.
        var officeIsReachable: Bool
        /// Job reports or receipts are still waiting to go.
        var smallerItemsWaiting = false
    }

    /// With the phone off power, the battery must be above this.
    static let batteryFloor = 0.5

    enum Reason: Equatable, CaseIterable, Sendable {
        case medicalMode
        /// Unblurred, where the organisation requires blur. It is kept and not sent, and the only
        /// thing a technician can do about it is delete it.
        case blurRequired
        case profileNotCurrent
        case leaseNotCurrent
        case bindingNotCurrent
        case noNetwork
        /// On mobile data, which the person has not allowed for recordings.
        case waitingForWiFi
        case cellularForbiddenByOrganization
        case waitingForPower
        case savingPower
        case officeNotReachable
        case smallerItemsFirst

        /// The reason as a sentence for the technician.
        var explanation: String {
            switch self {
            case .medicalMode:
                return "Recordings are not sent while a medical privacy mode is on."
            case .blurRequired:
                return "Your organisation requires faces to be blurred before a recording is sent. "
                    + "This one was made ready for the office without that, and can't be blurred now. "
                    + "It stays on this phone and isn't sent. You can delete it."
            case .profileNotCurrent:
                return "This phone's organisation settings are out of date, so the recording can't be sent yet."
            case .leaseNotCurrent:
                return "This phone's licence needs renewing before the recording can be sent."
            case .bindingNotCurrent:
                return "This phone isn't currently paired with your office, so the recording can't be sent."
            case .noNetwork:
                return "Waiting for Wi-Fi."
            case .waitingForWiFi:
                return "Waiting for Wi-Fi. Recordings aren't sent over mobile data unless you allow it."
            case .cellularForbiddenByOrganization:
                return "Waiting for Wi-Fi. Your organisation doesn't allow recordings to be sent over mobile data."
            case .waitingForPower:
                return "Waiting for power. Plug the phone in to send the recording."
            case .savingPower:
                return "The phone is saving power. Plug it in to send the recording."
            case .officeNotReachable:
                return "The office can't be reached from here. The recording will be sent when it can."
            case .smallerItemsFirst:
                return "Job reports are being sent first."
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case eligible
        case notEligible(Reason)

        var isEligible: Bool { self == .eligible }
    }

    static func evaluate(_ conditions: Conditions) -> Verdict {
        reasons(conditions).first.map(Verdict.notEligible) ?? .eligible
    }

    /// Everything in the way, most pressing first. Empty when the recording may go.
    static func reasons(_ c: Conditions) -> [Reason] {
        var reasons: [Reason] = []
        if c.medicalModeOn { reasons.append(.medicalMode) }
        if c.blurRequiredAndNotDone { reasons.append(.blurRequired) }
        if !c.profileIsCurrent { reasons.append(.profileNotCurrent) }
        if !c.leaseIsCurrent { reasons.append(.leaseNotCurrent) }
        if !c.bindingIsCurrent { reasons.append(.bindingNotCurrent) }
        switch c.network {
        case .wifi:
            break
        case .none:
            reasons.append(.noNetwork)
        case .cellular:
            // The organisation's rule is the one a person cannot change, so it is the one named.
            if c.cellularForbiddenByOrganization {
                reasons.append(.cellularForbiddenByOrganization)
            } else if !c.cellularAllowedByUser {
                reasons.append(.waitingForWiFi)
            }
        }
        if !c.isCharging {
            if c.powerDefersBulkTransfer {
                reasons.append(.savingPower)
            } else if (c.batteryLevel ?? 0) <= batteryFloor {
                // A battery the phone will not report is not taken to be full.
                reasons.append(.waitingForPower)
            }
        }
        if !c.officeIsReachable { reasons.append(.officeNotReachable) }
        if c.smallerItemsWaiting { reasons.append(.smallerItemsFirst) }
        return reasons
    }
}
