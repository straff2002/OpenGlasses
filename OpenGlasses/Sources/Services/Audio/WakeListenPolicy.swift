import AVFoundation

/// Where the idle wake-word listener waits (Plan GU §1). `Config.micRoute` stays the
/// **conversation** mic — where the request is heard and, during a conversation, where replies
/// play; this is only where the app waits for the wake phrase.
enum WakeListenMic: String, CaseIterable, Identifiable, Sendable {
    /// The phone's own mic. Bluetooth media stays on A2DP (full quality) while the app waits.
    case iPhone
    /// Whatever the Microphone setting says — the glasses' (or a headset's) hands-free mic held
    /// open while idle, as the app always did before.
    case sameAsMicrophone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iPhone: return "iPhone"
        case .sameAsMicrophone: return "Same as Microphone"
        }
    }
}

/// What the idle listener should hold: nothing, someone else's session, CarPlay's, the phone mic,
/// or a Bluetooth mic. A value, so every row of the plan's table is a test.
struct IdleAudioPlan: Equatable {
    enum Listen: Equatable {
        /// No session held: listening off, push-to-talk, muted, or stood down.
        case off
        /// A realtime session or an expert call owns the lease. Not ours to touch.
        case notOurs
        /// The car owns the route: `.voiceChat` + hands-free, as before.
        case carPlay
        /// The phone's own mic, Bluetooth output on A2DP.
        case phone
        /// A Bluetooth hands-free mic held open while idle.
        case bluetooth(MicRoute)
    }

    let listen: Listen
    /// The speech gate is wanted for this plan (`Config.wakeSpeechGateEnabled`, never for
    /// `.off`/`.notOurs`/CarPlay).
    let speechGate: Bool
    /// The stricter gate thresholds (`PowerPosture.prefersStrictWakeGate`).
    let strictGate: Bool

    /// Whether this plan opens a session of its own at all.
    var holdsSession: Bool {
        switch listen {
        case .off, .notOurs: return false
        case .carPlay, .phone, .bluetooth: return true
        }
    }

    /// The session category options this plan asks for. `.off`/`.notOurs` answer with the
    /// phone shape, which is what an explicit turn with no idle listener starts from.
    var categoryOptions: AVAudioSession.CategoryOptions {
        switch listen {
        case .carPlay:
            return [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker]
        case .bluetooth(let route):
            return MicRoutePolicy.categoryOptions(for: route, mixWithOthers: true)
        case .phone, .off, .notOurs:
            return MicRoutePolicy.idleCategoryOptions(for: .phone)
        }
    }

    var mode: AVAudioSession.Mode {
        listen == .carPlay ? .voiceChat : .default
    }

    /// The route whose port `setPreferredInput` should target: the built-in mic (`.phone`) for a
    /// phone-mic plan, the Bluetooth route for a hold, nothing for CarPlay (the car decides).
    var preferredInput: MicRoute? {
        switch listen {
        case .bluetooth(let route): return route
        case .carPlay: return nil
        case .phone, .off, .notOurs: return .phone
        }
    }

    /// Whether sustained silence on the idle mic still means "the glasses are in their case".
    /// Only when the idle mic *is* the glasses': silence on the phone's mic means a quiet room.
    var silenceMeansGlassesIdle: Bool {
        listen == .bluetooth(.glasses)
    }

    /// Whether the idle listener holds the glasses' own hands-free mic — the only thing an
    /// automatic stand-down exists to release (`GlassesSleepPolicy`).
    var holdsGlassesMic: Bool {
        listen == .bluetooth(.glasses)
    }
}

/// Plan GU §1 — decides where the idle listener waits. Pure: settings and observations in, a plan
/// out; `WakeWordService` applies it.
enum WakeListenPolicy {

    /// Shared-tap consumers that want the wearer's own voice rather than the room: glasses
    /// recording and broadcast (through the capture router), live captions, the teleprompter.
    /// While one runs with a Bluetooth conversation mic the idle listener keeps that mic, as it
    /// always did, so the recording does not quietly switch to the phone in a pocket. Memory
    /// rewind and meeting recording are deliberately absent — they capture the room, and the
    /// phone's mic is at least as good for that.
    static let wearerAudioConsumerIDs: Set<String> = [
        "capture_audio_router", "ambient_captions", "teleprompter",
    ]

    struct Inputs: Equatable {
        /// The master listening toggle.
        var listeningEnabled: Bool
        /// Push-to-talk: no always-on listener.
        var silentMode: Bool
        var micMuted: Bool = false
        /// False only while stood down from the glasses (`GlassesUse.voiceInputAvailable`).
        var voiceInputAvailable: Bool = true
        var carPlayMode: Bool = false
        /// A realtime session or an expert call holds the session lease.
        var foreignOwner: Bool = false
        /// A consumer in `wearerAudioConsumerIDs` is feeding off the shared tap.
        var wearerAudioConsumerActive: Bool = false
        var wakeListenMic: WakeListenMic = .iPhone
        /// The conversation mic (`Config.micRoute`).
        var micRoute: MicRoute
        var posture: PowerPosture = .normal
        /// `Config.wakeSpeechGateEnabled`.
        var speechGateEnabled: Bool = false
    }

    static func decide(_ inputs: Inputs) -> IdleAudioPlan {
        let listen = listenTarget(inputs)
        let gated: Bool
        switch listen {
        case .phone, .bluetooth: gated = inputs.speechGateEnabled
        case .off, .notOurs, .carPlay: gated = false
        }
        return IdleAudioPlan(listen: listen, speechGate: gated,
                             strictGate: gated && inputs.posture.prefersStrictWakeGate)
    }

    private static func listenTarget(_ inputs: Inputs) -> IdleAudioPlan.Listen {
        // 1. Nobody wants an idle listener: no session held at all, so media never leaves A2DP.
        if !inputs.listeningEnabled || inputs.silentMode || inputs.micMuted || !inputs.voiceInputAvailable {
            return .off
        }
        // 2. Someone else's session. Not ours to reconfigure.
        if inputs.foreignOwner { return .notOurs }
        // 3. The car owns the route.
        if inputs.carPlayMode { return .carPlay }
        // 4. A consumer that wants the wearer's own voice, with a Bluetooth conversation mic: keep
        //    holding it — released when the consumer stops. Outranks the power override: a
        //    recording should not change microphone because the battery dipped.
        if inputs.wearerAudioConsumerActive, inputs.micRoute != .phone {
            return .bluetooth(inputs.micRoute)
        }
        // 5. The wearer chose to wait on the conversation mic.
        if inputs.wakeListenMic == .sameAsMicrophone, inputs.micRoute != .phone {
            // Power reserve overrides a *glasses* idle choice to the phone — the glasses' radio is
            // the thing worth saving. A headset is not the glasses.
            if inputs.micRoute == .glasses, inputs.posture.prefersPhoneWakeMic { return .phone }
            return .bluetooth(inputs.micRoute)
        }
        // 6. Default: wait on the phone, media stays in full quality.
        return .phone
    }
}
