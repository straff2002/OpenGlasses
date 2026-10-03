import Foundation

// Plan CT — when the organisation's signed term has ended (2026-10-04). **A notice, and only that.**
//
// A profile's `policyExpiry` is the term the organisation signed. Once it has passed, the lease
// reports lapsed: the rules stay in force, the content locks, a job already open runs to its end
// (Plan CT PR 4). The profile itself is never removed automatically, and nothing here changes that.
// What this adds is the sentence the person was missing: the profile has ended, and where to remove
// it — Settings › Organisation › ⟨org⟩, Remove Profile under "Leave ⟨org⟩" (Plan HA C4).
//
// Why a notice and not an action: removal starts a departure that erases the firm's records after
// `undeliveredEraseDays` whether or not they were delivered, so doing it for the person — or even
// nudging hard — risks records the firm is owed. The product owner approved exactly this step.
// Inactive-then-removed with a grace period, an office-pushed signed removal, and office renewal
// come later (Plan CT, *The organisation's term has ended*).
//
// The rule reads `policyExpiry` only — never a lease lapse on its own. An office-commissioned phone
// has no profile address to renew from, so its lease always lapses `leaseDays` after enrolment;
// acting on that would tell every pilot phone its organisation had ended.
//
// The clock: the latest time the app has seen (`OrgEnrolmentRecord.clockHighWater`) stands in for a
// clock wound back behind it, so moving the clock backwards cannot hide the notice. A clock moved
// forwards shows it early, which is harmless for a notice.
//
// Pure: every input is a value, so the whole rule is tested headless (`OrgProfileEndPolicyTests`).

enum OrgProfileEndPolicy {

    /// Everything the decision reads, captured once per draw.
    struct Input: Equatable, Sendable {
        var organizationName: String
        /// The organisation's signed term (`ConfigProfile.policyExpiry`). Nil: no end, no notice.
        var policyExpiry: Date?
        var now: Date
        /// The latest time the app has seen, or nil before the lease has been evaluated.
        var clockHighWater: Date?
        /// A Field Assist job is open — the same job the lease's mid-job grace waits on.
        var jobOpen: Bool
        /// Reports still waiting to be sent, as the leaving screen counts them.
        var owedReports: Int
        /// Job records from the managed period, as the leaving screen lists them.
        var owedSessions: Int
        /// Where the profile came from: an MDM's (`managedConfig`) cannot be removed on the phone.
        var source: ProfileSource
    }

    enum Outcome: Equatable, Sendable {
        /// No `policyExpiry`, or it has not been reached: nothing to say.
        case inForce
        /// The term has ended, but a job is open. Quiet until the job closes, as the lock is.
        case endedDuringJob(endedOn: Date)
        /// The term has ended: show the notice.
        case ended(Notice)

        var notice: Notice? {
            if case .ended(let notice) = self { return notice }
            return nil
        }
    }

    /// Everything the views draw, so they decide nothing.
    struct Notice: Equatable, Sendable {
        let endedOn: Date
        /// Reports or job records are still the firm's: the notice says to send them first.
        let recordsOwed: Bool
        /// The profile can be removed on this phone (not an MDM's).
        let removableHere: Bool
        /// In the Organisation section of the Settings hub. Opens the organisation's page.
        let settingsText: String
        let settingsHint: String
        /// At the top of the organisation's page. Shows "Leave ⟨org⟩" at the bottom of it.
        let pageText: String
        let pageHint: String
        let systemImage: String
    }

    static func decide(_ input: Input) -> Outcome {
        guard let expiry = input.policyExpiry else { return .inForce }
        // A clock wound back behind a time already seen is not allowed to un-end the term.
        let now = max(input.now, input.clockHighWater ?? input.now)
        guard now >= expiry else { return .inForce }
        if input.jobOpen { return .endedDuringJob(endedOn: expiry) }

        let name = input.organizationName
        let ended = "\(name)'s profile ended on \(expiry.formatted(date: .abbreviated, time: .omitted))."
        let recordsOwed = input.owedReports > 0 || input.owedSessions > 0
        let removable = input.source.isLocallyRemovable

        let settingsText: String
        let pageText: String
        if removable {
            let owed = recordsOwed
                ? " Send \(name) its records first: Remove Profile offers that before anything is removed."
                : ""
            settingsText = "\(ended) To remove it, go to Settings › Organisation › \(name) and choose Remove Profile under Leave \(name).\(owed)"
            pageText = "\(ended) To remove it, choose Remove Profile under Leave \(name) at the bottom of this page.\(owed)"
        } else {
            // An MDM put it there and would put it back: no Leave instruction.
            let mdm = "\(ended) Your organisation's device management removes it from this phone."
            settingsText = mdm
            pageText = mdm
        }
        return .ended(Notice(endedOn: expiry,
                             recordsOwed: recordsOwed,
                             removableHere: removable,
                             settingsText: settingsText,
                             settingsHint: "Opens \(name)'s page.",
                             pageText: pageText,
                             pageHint: "Shows Leave \(name) at the bottom of this page.",
                             systemImage: "calendar"))
    }
}
