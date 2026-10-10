import Foundation

/// Plan HX P0 — what the wearer hears when the app stops using the glasses, and when it starts
/// again (pure).
///
/// # The gap this closes
///
/// The app played a rising pair when the glasses attached and nothing at all when they went. The
/// teardown stopped the wake word, the camera and speech and then said nothing, so a wearer with
/// the phone in a pocket carried on talking to glasses that were no longer part of the
/// conversation. VoiceOver was no help: `SessionAnnouncementPolicy` withheld its own line on the
/// strength of a disconnect tone that only ever played at the end of a turn.
///
/// # The rule
///
/// One cue, at the moment of a loss the wearer did not cause. Taking the glasses off, pressing
/// Disconnect and removing the glasses are things the wearer did and knows about; a tone for them
/// is noise, and noise is what teaches someone to stop listening for the cue that matters.
///
/// The session's own lifecycle (`AudibleLifecyclePolicy`) is a different subject with different
/// sounds to learn: that one is about a live session's connection to its service, heard under the
/// Blind Assistant preset. This one is about the glasses, and is heard by every wearer.
enum GlassesLinkCuePolicy {

    /// Why the app stopped using the glasses.
    enum Cause: Equatable {
        /// The link left `.connected` and nobody asked it to: out of range, switched off, flat,
        /// shut in the case.
        case linkLost
        /// The wearer's own doing: Disconnect (the pill, the dock tile, Siri, the watch, the deep
        /// link), or the glasses removed from this app altogether.
        case userDisconnected
        /// The app stood down by itself with the link still up (`GlassesSleepPolicy`: taken off
        /// past the grace, or silent past auto-sleep).
        case doffedStandDown
        /// The app is going away and is tearing its own observation down.
        case appTerminating
    }

    enum Cue: Equatable {
        /// The link-lost earcon (`lostEarcon`), then "Glasses disconnected" for VoiceOver.
        case lost
        /// "Glasses connected" for VoiceOver, after the connect tone every connection plays.
        case restored
        case none
    }

    // MARK: - Cause

    /// Why the glasses went out of use, read off the `GlassesUse` either side of the change.
    ///
    /// `GlassesUse` already keeps the two things that tell a request from an accident: the link
    /// (the SDK's) and the stand-down with its reason (the wearer's, or the app's own). `nil` when
    /// nothing was lost: the link was not up to begin with, or the glasses are still in use.
    ///
    /// Never `.appTerminating`: nothing in the app tears the glasses down on its way out today, so
    /// there is no change to read that from. The nearest thing, the connection service forgetting
    /// what it observed (`stopObserving()`), reads as glasses no longer added, which is silent too.
    static func cause(from before: GlassesUse, to after: GlassesUse) -> Cause? {
        guard before.link.isConnected else { return nil }
        if after.link.isConnected {
            // The link is still up, so only a new stand-down takes the glasses out of use.
            guard before.inUse else { return nil }
            switch after.standDownReason {
            case .user: return .userDisconnected
            case .automatic: return .doffedStandDown
            case nil: return nil
            }
        }
        // The link went. Glasses that are no longer added at all (registration gone and nothing
        // listed) were removed, which is done by hand in Meta AI; anything else is a pair that is
        // still this person's and has stopped answering.
        return after.link == .noGlassesAdded ? .userDisconnected : .linkLost
    }

    // MARK: - Decisions

    /// The cue for a loss.
    ///
    /// - Parameters:
    ///   - wasWorn: the last worn reading taken while the link was up
    ///     (`GlassesConnectionSnapshot.lastLiveWorn`). Only a known `false` is silent: glasses
    ///     that do not report it are treated as worn, because silence is the failure.
    ///   - standDownActive: the app was already stood down from the glasses when the link went.
    ///     They were not in use, so nothing the wearer was relying on has changed.
    static func onLoss(cause: Cause, wasWorn: Bool?, standDownActive: Bool) -> Cue {
        guard cause == .linkLost, wasWorn != false, !standDownActive else { return .none }
        return .lost
    }

    /// The cue for the glasses coming back into use. The connect tone is not this policy's to
    /// give or withhold: it plays for every connection, as it always has. The line is added only
    /// when the wearer was told the glasses had gone, so a first connection at launch, a resume
    /// after Disconnect and a pair lifted out of its case sound exactly as they did.
    static func onRestore(lostCueWasPlayed: Bool) -> Cue {
        lostCueWasPlayed ? .restored : .none
    }

    // MARK: - Wording

    static let disconnectedLine = "Glasses disconnected"
    static let connectedLine = "Glasses connected"

    /// What VoiceOver is told with a cue. One wording for the glasses' link, shared with
    /// `SessionAnnouncementPolicy`, so the line is the same whichever of the two says it.
    static func voiceOverLine(for cue: Cue) -> String? {
        switch cue {
        case .lost: return disconnectedLine
        case .restored: return connectedLine
        case .none: return nil
        }
    }

    // MARK: - The record between a loss and the next connection

    /// What became of the cue for the last loss. `onRestore` needs to know whether it was heard,
    /// and `SessionAnnouncementPolicy` needs to know whether the app took it on at all.
    struct Ledger: Equatable {
        enum LostCue: Equatable {
            /// The last loss was silent by policy, or there has not been one.
            case none
            /// Decided, not yet heard: waiting for the hardware release to settle and for the
            /// route to be free.
            case owed
            case played
        }

        private(set) var lostCue: LostCue = .none

        /// The glasses went out of use. Decides the cue and remembers it. A change that is not a
        /// loss (`cause(from:to:)` is nil) leaves the record alone.
        @discardableResult
        mutating func noteLoss(from before: GlassesUse, to after: GlassesUse, wasWorn: Bool?) -> Cue {
            guard let cause = GlassesLinkCuePolicy.cause(from: before, to: after) else { return .none }
            let cue = GlassesLinkCuePolicy.onLoss(cause: cause, wasWorn: wasWorn,
                                                  standDownActive: before.stoodDown)
            lostCue = cue == .lost ? .owed : .none
            return cue
        }

        /// The owed cue was played. Returns `false`, and changes nothing, when there was none
        /// owed any more: the glasses came back first.
        @discardableResult
        mutating func noteLostCuePlayed() -> Bool {
            guard lostCue == .owed else { return false }
            lostCue = .played
            return true
        }

        /// The glasses are in use again. A cue still owed is dropped with the record: "glasses
        /// disconnected" after they have reconnected is a false statement, not a late one.
        mutating func noteRestore() -> Cue {
            defer { lostCue = .none }
            return GlassesLinkCuePolicy.onRestore(lostCueWasPlayed: lostCue == .played)
        }

        /// Whether the app took the last loss's cue on itself, heard yet or not. While it has,
        /// VoiceOver's own line for that loss is withheld: the cue carries the line.
        var appOwnsLossCue: Bool { lostCue != .none }
    }

    // MARK: - The sound

    /// One note of an earcon: when it starts, its pitch and how long it sounds.
    struct Note: Equatable, Sendable {
        let start: TimeInterval
        let frequency: Double
        let duration: TimeInterval
        var end: TimeInterval { start + duration }
    }

    /// The link-lost earcon: D5, B♭4, then G4 held. A slow fall through a minor triad, played by
    /// `TextToSpeechService.playLinkLostTone()`.
    ///
    /// It was the end-of-conversation pair until 2026-10-10, and mid-conversation a dropped link
    /// then sounded like the conversation ending. It has to be told by ear from everything else
    /// the app plays, usually from a phone in a pocket (the glasses are what went):
    /// - the end-of-conversation pair (`playDisconnectTone`, 440 → 330 Hz, also the Blind
    ///   Assistant's "connection dropped") is two notes and over in a quarter of a second. This
    ///   is three, each longer than either of that pair's, and lasts more than twice as long. It
    ///   starts a fourth above that pair, so the first note already differs.
    /// - the connect pair, the session-restored triad and the unmute pair rise. This only falls.
    /// - the listening tones (880 Hz, 440 Hz) and the held and rejected blips are single notes.
    /// - the failure double and the recording doubles repeat one pitch. No pitch repeats here.
    /// - the temple-tap "ended" earcon (660, 494, 330 Hz) is the other three-note fall. It is
    ///   staccato, an octave wide and done in a third of a second, in answer to the wearer's own
    ///   tap. This is a fifth wide, nearly twice as long, and ends on a held note.
    /// The lowest note is 392 Hz, above the lowest the other cues use and well inside what a
    /// phone's speaker carries: a last note that went unheard would leave a falling pair.
    static let lostEarcon: [Note] = [
        Note(start: 0.00, frequency: 587, duration: 0.16),
        Note(start: 0.19, frequency: 466, duration: 0.16),
        Note(start: 0.38, frequency: 392, duration: 0.24),
    ]

    /// How long the link-lost earcon lasts.
    static var lostEarconSeconds: TimeInterval { lostEarcon.map(\.end).max() ?? 0 }

    /// How long after the earcon starts the VoiceOver line waits, so that it follows the earcon
    /// rather than starting under it.
    static var lostLineDelaySeconds: TimeInterval { lostEarconSeconds + 0.1 }

    // MARK: - Delivery

    /// How long after the hardware release the cue waits before it sounds. The release stops
    /// speech, and stopping speech hands the audio session back a moment later; a tone started
    /// under that hand-back is cut off by it (`TurnAudioRelease.toneSettleSeconds` exists for the
    /// same reason at the end of a turn).
    static let settleSeconds: TimeInterval = 0.5

    /// How often an owed cue looks at the route again.
    static let pollSeconds: TimeInterval = 0.25

    enum Delivery: Equatable {
        case play
        /// Speech has the route. Look again shortly.
        case wait
        /// The glasses came back before the cue was heard.
        case drop
    }

    /// Whether an owed cue goes now. Never on top of the assistant's voice or of an announcement
    /// VoiceOver is still reading; and, like every other failure notice, never held back for ever
    /// by a long answer either (`AudibleLifecyclePolicy.maxQueuedWait`, the same bound and the
    /// same route reading the session's own loss notice uses).
    static func delivery(stillOwed: Bool, route: AudibleLifecyclePolicy.SpeechRoute,
                         waited: TimeInterval) -> Delivery {
        guard stillOwed else { return .drop }
        if route.isBusy && waited < AudibleLifecyclePolicy.maxQueuedWait { return .wait }
        return .play
    }
}
