import Foundation

/// What the Enrolled Faces screen says (Plan HP P2 item 8), worked out without SwiftUI so every line
/// of it is tested headless.
///
/// The screen exists because face recognition names people who never installed the app and are
/// not told: the wearer needs one place that says so, shows who is enrolled, and forgets them —
/// one at a time or all at once. The near-tie message in `FaceRecognitionService` sends the wearer
/// here by name (`screenPath`).
enum EnrolledFacesPresentation {

    /// One enrolled person, as the list shows them.
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        /// "Last seen 2 days ago".
        let lastSeen: String
        /// What VoiceOver reads for the row: the name and when they were last seen, as one sentence.
        let accessibilityLabel: String
    }

    /// The opt-in copy under the switch. Says the three things the wearer must weigh: what it does,
    /// that the person is not told, and whose responsibility its use is.
    static var optInFooter: String {
        String(localized: "Names people you've enrolled when they're in front of your glasses. The person isn't told. You're responsible for using this lawfully where you are.")
    }

    /// Said under the switch on an EEA storefront before face recognition stops being available
    /// there (Plan HS P1 item 1; `MarketAvailability.showsFaceRecognitionAdvanceNotice` decides when).
    static var regionAdvanceNotice: String {
        String(localized: "In EU and EEA App Store regions, face recognition will stop being available on 2 December 2027.")
    }

    /// Where this screen is, as the near-tie message and any other spoken pointer names it.
    static var screenPath: String {
        String(localized: "Settings, Devices & Privacy, Glasses, Enrolled Faces")
    }

    /// The list when nobody is enrolled.
    static var emptyList: String {
        String(localized: "Nobody is enrolled. To enrol someone, look at them and say \"remember this person as\" and their name. You'll be asked to approve it first.")
    }

    /// The rows, alphabetical by name the way the wearer's language sorts, so a name is where they
    /// expect it rather than where the order of enrolment left it.
    static func rows(for faces: [FaceRecognitionService.KnownFace], now: Date = Date(),
                     locale: Locale = .current) -> [Row] {
        faces
            .sorted { lhs, rhs in
                let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive],
                                             range: nil, locale: locale)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
            .map { face in
                let seen = lastSeenText(face.lastSeen, now: now, locale: locale)
                return Row(id: face.id, name: face.name, lastSeen: seen,
                           accessibilityLabel: "\(face.name), \(seen)")
            }
    }

    /// "Last seen 2 days ago". A face is "seen" when it is enrolled and each time it is recognised.
    /// Under a minute — including a record stamped a moment after `now`, or a clock that moved
    /// backwards — is "just now"; the formatter would say "in 0 seconds".
    static func lastSeenText(_ lastSeen: Date, now: Date = Date(), locale: Locale = .current) -> String {
        guard now.timeIntervalSince(lastSeen) >= 60 else { return String(localized: "Last seen just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastSeen, relativeTo: now)
        return String(localized: "Last seen \(relative)")
    }

    /// The question before "Forget everyone" runs. It names how many people go, and that nothing of
    /// them is kept.
    static func forgetEveryoneQuestion(count: Int) -> String {
        count == 1
            ? String(localized: "Forget the one person enrolled? Their face print is deleted from this phone.")
            : String(localized: "Forget all \(count) people enrolled? Their face prints are deleted from this phone.")
    }

    /// The status beside the row that links here from the Glasses screen.
    static func linkStatus(enabled: Bool, enrolled: Int) -> String {
        guard enabled else { return String(localized: "Off") }
        return enrolled == 1 ? String(localized: "On, 1 person") : String(localized: "On, \(enrolled) people")
    }
}
