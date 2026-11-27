import Foundation

/// The organisation's ceiling on how long Medical Compliance keeps transcripts and recordings
/// (Plan NJ §7). Pure.
///
/// Plan CT decided that a profile may pin Medical Compliance on and never off, and that a ceiling
/// only ever subtracts. It said nothing about retention, so this takes the stricter reading: the
/// organisation's figure is the **longest** a phone keeps them. A phone set shorter keeps its own
/// shorter figure; a phone set to keep them until deleted by hand (0) is held to the figure. A
/// profile can never make a phone keep them longer than the person chose.
enum HIPAARetentionCeiling {

    /// Ten years: the longest figure a profile may give.
    nonisolated static let maximumDays = 3_650

    /// The days a profile's value names: digits only, 1 to `maximum`. Nil for anything else.
    nonisolated static func days(_ raw: String, maximum: Int = maximumDays) -> Int? {
        guard !raw.isEmpty, raw.count <= 5, raw.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
              let days = Int(raw), (1...maximum).contains(days) else { return nil }
        return days
    }

    /// The retention in force: the phone's own `stored` days (0 is "never purge"), held to the
    /// organisation's `ceiling` when there is one.
    nonisolated static func effective(stored: Int, ceiling: Int?) -> Int {
        let own = max(0, stored)
        guard let ceiling, ceiling > 0 else { return own }
        return own == 0 ? ceiling : min(own, ceiling)
    }
}

/// What an organisation's pin on Medical Compliance asks the phone to do (Plan NJ §7). Pure.
///
/// The pin is clamp-on-read, so the person's own switch is never overwritten. What turning the
/// mode on does (protecting files already saved, purging Spotlight, the audit entry) still has to
/// run once when a pin arrives on a phone whose own switch is off, and the mode's dependants have
/// to hear when the pin goes.
enum MedicalModePin {

    enum Action: Equatable, Sendable {
        case none
        /// The pin has arrived on a phone whose own switch is off: turn on what the mode turns on.
        case apply
        /// The pin has gone. `modeEnds` when the person's own switch is off, so the mode stops.
        case lift(modeEnds: Bool)
    }

    /// The flag that says the pin's turn-on has run, so it runs once per pin.
    static let appliedKey = "hipaaModeOrganisationPinApplied"

    nonisolated static func action(pinned: Bool, storedOn: Bool, applied: Bool) -> Action {
        switch (pinned, applied) {
        case (true, false): return storedOn ? .none : .apply
        case (false, true): return .lift(modeEnds: !storedOn)
        default: return .none
        }
    }
}
