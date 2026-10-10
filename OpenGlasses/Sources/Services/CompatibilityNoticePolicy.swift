import Foundation

/// Plan HX P1 — when the wearer is told that the glasses, or the app, need updating (pure).
///
/// # The gap this closes
///
/// The glasses report whether they and this build can work together on the device-state listener
/// the app already holds, and nothing read it. An update requirement was only ever discovered by
/// a camera session failing, so a wearer who never opened the camera heard nothing, and one who
/// did heard it as the reason a photo failed rather than as something to do about their glasses.
///
/// # The rule
///
/// One sentence per requirement, once per process, at the first moment the glasses are connected
/// and say so. Compatible glasses, and glasses that have not said, say nothing. The sentence is
/// `DATCompatibilityMessage`'s, the same one the camera path uses, and the record is shared with
/// that path, so a build the glasses refuse is not announced twice in two voices.
enum CompatibilityNoticePolicy {

    /// What a compatibility reading asks of the wearer, or nil when it asks nothing.
    ///
    /// - Parameter compatibility: `GlassesConnectionService.compatibility`, which is nil whenever
    ///   the link is not up. Glasses that are away announce nothing.
    static func notice(for compatibility: GlassesCompatibility?) -> String? {
        compatibility.flatMap { DATCompatibilityMessage.message(for: $0) }
    }

    /// What the screen shows for a reading. Not the spoken rule below: the sentence is said once
    /// per process, and the notice is on screen for exactly as long as it is true.
    enum Standing: Equatable {
        /// The connected glasses are asking for this now. Show it, in place of whatever an earlier
        /// reading showed.
        case stands(String)
        /// They are compatible, have not said, or are not connected. Take the notice back.
        case withdrawn
    }

    /// Whether the update notice stands on screen, from the reading alone.
    ///
    /// Decided at every change of the reading, so a notice the wearer dismissed comes back when
    /// the glasses next connect still asking, and one about glasses that have been updated, or
    /// have gone, does not outlive the requirement. It is posted under its own notice source
    /// (`AppNotice.Source.glassesUpdate`), which nothing else clears.
    static func standing(for compatibility: GlassesCompatibility?) -> Standing {
        notice(for: compatibility).map(Standing.stands) ?? .withdrawn
    }

    enum Decision: Equatable {
        /// Say the notice when the route is free.
        case announce(String)
        case nothing
    }

    // MARK: - The record for the process

    /// Which sentences have been said since launch, and which one is waiting to be.
    ///
    /// A value with no way back from `said` except a sentence that was never played: the process
    /// is the unit, because the wearer who has been told once to update does not need telling at
    /// every reconnection, and a relaunch is the natural moment to be reminded.
    struct Ledger: Equatable {
        /// Decided, not yet heard: waiting for the connection to settle and the route to be free.
        private(set) var owed: String?
        private(set) var said: Set<String> = []

        /// A new compatibility reading. Decides whether to announce and remembers it.
        ///
        /// A reading that asks nothing (compatible, not said, or the link gone) drops a sentence
        /// still owed: it has stopped being true, or there is nobody connected to say it about.
        /// It was never heard, so the next connection that needs it says it.
        mutating func note(_ compatibility: GlassesCompatibility?) -> Decision {
            guard let message = CompatibilityNoticePolicy.notice(for: compatibility) else {
                owed = nil
                return .nothing
            }
            guard !said.contains(message) else {
                owed = nil
                return .nothing
            }
            guard owed != message else { return .nothing }
            owed = message
            return .announce(message)
        }

        func isOwed(_ message: String) -> Bool { owed == message }

        /// The owed sentence is about to be spoken. Returns `false`, and changes nothing, when it
        /// is no longer owed: the link went, or the requirement lifted, while it waited.
        @discardableResult
        mutating func noteSaid(_ message: String) -> Bool {
            guard owed == message else { return false }
            owed = nil
            said.insert(message)
            return true
        }

        /// The sentence was sent to the speaker and nothing was played. It is forgotten, so the
        /// next connection that needs it says it: "once" counts what the wearer could have heard.
        mutating func noteNotHeard(_ message: String) {
            said.remove(message)
        }

        /// Another speaker wants to say `message` now (the camera's own compatibility notice,
        /// which shares its wording for a build that is too old). `true`, and recorded as said,
        /// unless this record already has it said or waiting.
        mutating func claim(_ message: String) -> Bool {
            guard owed != message, !said.contains(message) else { return false }
            said.insert(message)
            return true
        }
    }

    // MARK: - Delivery

    /// How long after the reading the sentence waits before it looks at the route. A requirement
    /// is usually read in the first moment of a connection, and the connection has its own
    /// sounds first: the connect tone, then the audio hand-off to the glasses two and a half
    /// seconds in, which stands aside for anything already speaking. A sentence started under
    /// that would leave the wake word on the wrong microphone.
    static let settleSeconds: TimeInterval = 4

    /// Whether an owed sentence is said now.
    ///
    /// The lost-link cue's rule (`GlassesLinkCuePolicy.delivery`) and its route reading, without
    /// its bound. That cue is a tone that must not be buried by a long answer; this is a sentence,
    /// and saying it over the assistant would cut the answer off. Nothing spoils by waiting: the
    /// notice is already on screen, and the wait ends when the route is free or the sentence
    /// stops being owed.
    static func delivery(stillOwed: Bool,
                         route: AudibleLifecyclePolicy.SpeechRoute) -> GlassesLinkCuePolicy.Delivery {
        GlassesLinkCuePolicy.delivery(stillOwed: stillOwed, route: route, waited: 0)
    }

    /// Whether a spoken attempt counts as the wearer having been told. Cut short still counts:
    /// they heard it begin, and whoever cut it had the ear. Withheld or broken does not.
    static func wasHeard(_ outcome: SpeechDeliveryOutcome) -> Bool {
        switch outcome {
        case .completed, .interrupted: return true
        case .suppressed, .failed: return false
        }
    }
}
