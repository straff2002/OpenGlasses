import Foundation

/// Everything a tap's meaning depends on, as plain values (Plan GJ P0).
struct TempleContext: Equatable {
    enum Activity: Equatable {
        /// Nothing under way — the wake word (or nothing) is listening.
        case standby
        /// A Direct-mode conversation is listening for the wearer.
        case listening
        /// A reply is being worked out.
        case thinking
        /// A reply is being spoken.
        case speaking
        /// A Gemini Live or OpenAI Realtime session is running.
        case liveSession
        /// Another mode owns the loop (Assistive Mode) — taps stay out of its way.
        case busy
    }

    var activity: Activity
    var agentModeEnabled: Bool = false
    /// Agent Mode is on *and* a gateway is configured to answer.
    var agentAvailable: Bool = false
    /// The wake-word mic is muted.
    var micMuted: Bool = false
    /// The running live session is not sending the mic.
    var liveMicMuted: Bool = false
    var recording: Bool = false
    /// The glasses camera can take a still right now. Tap photos never fall back to the phone
    /// camera — from a pocket that would be a hidden shot of the inside of a pocket.
    var glassesCameraReady: Bool = false
    var digestEnabled: Bool = false
    var quickActionIDs: Set<String> = []
}

/// The concrete thing to do for a resolved tap.
enum TempleEffect: Equatable {
    case startListening
    /// Stop the reply being spoken and listen — the same barge-in as speaking over it.
    case interruptAndListen
    /// End the Direct-mode conversation, whatever stage it is at.
    case endConversation
    case endLiveSession
    /// Mute or unmute the wake-word mic.
    case setMicMuted(Bool)
    /// Mid Direct-mode conversation: end it and leave the mic muted.
    case muteAndEndConversation
    /// Stop or resume sending the mic in a live session, without ending it.
    case setLiveMicMuted(Bool)
    case photoDescribe
    case photoToCameraRoll
    case readDigest
    case toggleRecording(starting: Bool)
    /// Toggle music on whichever provider is playing, else the default one.
    case musicPlayPause
    case askAgent
    case quickAction(String)
}

enum TempleIgnoreReason: String, Equatable, CaseIterable {
    case unassigned
    case nothingToEnd
    case alreadyListening
    case busy
    case agentModeOff
    case agentNotConfigured
    case noGlassesCamera
    case digestOff
    case quickActionMissing

    /// A short spoken line for refusals the wearer can act on. The rest are a soft tone only — a
    /// stray tap while already listening does not need a sentence.
    var spokenLine: String? {
        switch self {
        case .unassigned, .nothingToEnd, .alreadyListening, .busy:
            return nil
        case .agentModeOff:
            return String(localized: "Agent Mode is off.")
        case .agentNotConfigured:
            return String(localized: "Your agent isn't set up.")
        case .noGlassesCamera:
            return String(localized: "The glasses camera isn't available.")
        case .digestOff:
            return String(localized: "The digest is off.")
        case .quickActionMissing:
            return String(localized: "That Quick Action no longer exists.")
        }
    }
}

enum TempleOutcome: Equatable {
    case run(TempleEffect)
    case ignored(TempleIgnoreReason)
}

/// Maps a tap to what it should do right now (Plan GJ P0). Pure.
enum TempleActionResolver {

    static func resolve(gesture: TempleGesture, map: TempleGestureMap,
                        context: TempleContext) -> TempleOutcome {
        resolve(action: map.action(for: gesture), context: context)
    }

    static func resolve(action: TempleAction, context: TempleContext) -> TempleOutcome {
        let activity = context.activity
        switch action {
        case .nothing:
            return .ignored(.unassigned)

        case .startTalking:
            switch activity {
            case .standby: return .run(.startListening)
            case .speaking: return .run(.interruptAndListen)
            case .listening, .liveSession: return .ignored(.alreadyListening)
            case .thinking, .busy: return .ignored(.busy)
            }

        case .hangUp:
            switch activity {
            case .standby: return .ignored(.nothingToEnd)
            case .listening, .thinking, .speaking: return .run(.endConversation)
            case .liveSession: return .run(.endLiveSession)
            case .busy: return .ignored(.busy)
            }

        case .mute:
            switch activity {
            case .standby: return .run(.setMicMuted(!context.micMuted))
            case .listening, .thinking, .speaking: return .run(.muteAndEndConversation)
            case .liveSession: return .run(.setLiveMicMuted(!context.liveMicMuted))
            case .busy: return .ignored(.busy)
            }

        case .photoDescribe:
            guard activity == .standby else { return .ignored(.busy) }
            guard context.glassesCameraReady else { return .ignored(.noGlassesCamera) }
            return .run(.photoDescribe)

        case .photoToCameraRoll:
            guard activity != .busy else { return .ignored(.busy) }
            guard context.glassesCameraReady else { return .ignored(.noGlassesCamera) }
            return .run(.photoToCameraRoll)

        case .readDigest:
            guard activity == .standby else { return .ignored(.busy) }
            guard context.digestEnabled else { return .ignored(.digestOff) }
            return .run(.readDigest)

        case .toggleRecording:
            guard activity != .busy else { return .ignored(.busy) }
            // Stopping never needs the camera; starting records from the glasses or not at all.
            if !context.recording && !context.glassesCameraReady { return .ignored(.noGlassesCamera) }
            return .run(.toggleRecording(starting: !context.recording))

        case .musicPlayPause:
            // Only between conversations: mid-turn the tap would fight the reply for the audio.
            guard activity == .standby else { return .ignored(.busy) }
            return .run(.musicPlayPause)

        case .askAgent:
            guard context.agentModeEnabled else { return .ignored(.agentModeOff) }
            guard context.agentAvailable else { return .ignored(.agentNotConfigured) }
            guard activity == .standby else { return .ignored(.busy) }
            return .run(.askAgent)

        case .quickAction(let id):
            guard context.quickActionIDs.contains(id) else { return .ignored(.quickActionMissing) }
            guard activity == .standby else { return .ignored(.busy) }
            return .run(.quickAction(id))
        }
    }
}

/// The sound that confirms a tap, so a pocketed phone still tells the wearer what happened.
enum TempleEarcon: Equatable, CaseIterable {
    /// The action plays its own cue (the listening tone, the end-of-conversation tone).
    case ownCue
    case accepted
    case refused
    case muted
    case unmuted
    case ended
    case recordingStarted
    case recordingStopped

    /// Tones as (frequency Hz, duration s), played in sequence. Empty only for `.ownCue`.
    var tones: [(frequency: Double, duration: Double)] {
        switch self {
        case .ownCue: return []
        case .accepted: return [(880, 0.08)]
        case .refused: return [(330, 0.12)]
        case .muted: return [(660, 0.08), (440, 0.10)]
        case .unmuted: return [(440, 0.08), (660, 0.10)]
        case .ended: return [(660, 0.08), (494, 0.08), (330, 0.12)]
        case .recordingStarted: return [(990, 0.08), (990, 0.08)]
        case .recordingStopped: return [(494, 0.08), (494, 0.08)]
        }
    }

    static func `for`(_ outcome: TempleOutcome) -> TempleEarcon {
        switch outcome {
        case .ignored:
            return .refused
        case .run(let effect):
            switch effect {
            // Starting a conversation plays the listening tone; ending one plays the
            // end-of-conversation tone. A second sound on top would blur both.
            case .startListening, .askAgent, .endConversation: return .ownCue
            case .interruptAndListen, .photoDescribe, .photoToCameraRoll, .readDigest, .quickAction,
                 .musicPlayPause:
                return .accepted
            case .endLiveSession: return .ended
            case .setMicMuted(let muted), .setLiveMicMuted(let muted): return muted ? .muted : .unmuted
            case .muteAndEndConversation: return .muted
            case .toggleRecording(let starting): return starting ? .recordingStarted : .recordingStopped
            }
        }
    }
}
