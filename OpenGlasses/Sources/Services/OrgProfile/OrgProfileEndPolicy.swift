import Foundation

// The organisation's signed term has ended. Access enforcement lives in OrgProfileManager:
// it locks content and closes managed jobs even when one was left open. This policy supplies
// the notice and removal instructions, without removing the profile or changing its erasure window.
// It reads policyExpiry rather than a missed renewal alone. Clock high-water prevents winding
// the clock backwards from hiding an end that the phone has already observed.

enum OrgProfileEndPolicy {

    /// Everything the decision reads, captured once per draw.
    struct Input: Equatable, Sendable {
        var organizationName: String
        /// The organisation's signed term (`ConfigProfile.policyExpiry`). Nil: no end, no notice.
        var policyExpiry: Date?
        var now: Date
        /// The latest time the app has seen, or nil before the lease has been evaluated.
        var clockHighWater: Date?
        /// Whether a job is still being closed. It cannot defer the end notice.
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

        let name = input.organizationName
        let ended = String(localized: "\(name)'s profile ended on \(expiry.formatted(date: .abbreviated, time: .omitted)).")
        let recordsOwed = input.owedReports > 0 || input.owedSessions > 0
        let removable = input.source.isLocallyRemovable

        let settingsText: String
        let pageText: String
        if removable {
            let owed = recordsOwed
                ? String(localized: " Send \(name) its records first: Remove Profile offers that before anything is removed.")
                : ""
            settingsText = String(localized: "\(ended) To remove it, go to Settings › Organisation › \(name) and choose Remove Profile under Leave \(name).\(owed)")
            pageText = String(localized: "\(ended) To remove it, choose Remove Profile under Leave \(name) at the bottom of this page.\(owed)")
        } else {
            // An MDM put it there and would put it back: no Leave instruction.
            let mdm = String(localized: "\(ended) Your organisation's device management removes it from this phone.")
            settingsText = mdm
            pageText = mdm
        }
        return .ended(Notice(endedOn: expiry,
                             recordsOwed: recordsOwed,
                             removableHere: removable,
                             settingsText: settingsText,
                             settingsHint: String(localized: "Opens \(name)'s page."),
                             pageText: pageText,
                             pageHint: String(localized: "Shows Leave \(name) at the bottom of this page."),
                             systemImage: "calendar"))
    }
}
