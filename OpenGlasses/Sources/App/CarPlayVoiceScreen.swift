import Foundation

/// The CarPlay voice screen, decided without CarPlay.
///
/// `CarPlaySceneDelegate` presents a `CPVoiceControlTemplate` while the driver talks to the
/// assistant. This type owns every decision about that screen — which of its three states it shows,
/// when it goes away, and what the Voice tab's rows do — so the template code is a thin adapter
/// that reads a `Conversation` snapshot off `AppState` and carries out the effect it is handed.
///
/// Three rules, each a defect the screen used to have:
///  - **It follows the conversation.** The state shown is the conversation's own — listening,
///    thinking, speaking — not "Listening…" from the first tap to the last.
///  - **It cannot wedge.** When the conversation ends by itself (the silence window, "goodbye",
///    One Question at a Time) the screen goes away with it, and a template the system took down is
///    forgotten; either way the next Start Listening starts something. It used to be reset only by
///    Stop Listening or a disconnect, so Start Listening could silently do nothing.
///  - **Stop and End are different things.** Stop cuts off the reply and keeps the conversation
///    listening (the temple tap's interrupt); End hangs the conversation up (the temple tap's hang
///    up). Both are the app's existing paths — this type only chooses between them.
struct CarPlayVoiceScreen: Equatable {

    /// The conversation as the car screen needs it, read off `AppState` on the main actor.
    struct Conversation: Equatable {
        var inConversation: Bool
        var isListening: Bool
        var isProcessing: Bool
        var isSpeaking: Bool

        /// Nothing is happening: no conversation open, nothing being heard, worked on or said.
        ///
        /// All four, not `inConversation` alone — push-to-talk closes the conversation before its
        /// reply arrives, and the reply is still the conversation as far as the driver can hear.
        var isOver: Bool { !inConversation && !isListening && !isProcessing && !isSpeaking }

        static let idle = Conversation(inConversation: false, isListening: false,
                                       isProcessing: false, isSpeaking: false)
    }

    /// The template's three states. The raw value is the `CPVoiceControlState` identifier.
    enum Phase: String, CaseIterable, Equatable {
        case listening
        case processing
        case speaking

        /// What a live conversation shows. Speaking first: the screen describes what the driver
        /// hears, and Stop acts on exactly that. A conversation between turns — open, nothing in
        /// flight yet — is listening, which is what it is about to do.
        init(_ conversation: Conversation) {
            if conversation.isSpeaking { self = .speaking }
            else if conversation.isProcessing { self = .processing }
            else { self = .listening }
        }

        /// The title the car shows for this state.
        var title: String {
            switch self {
            case .listening: return String(localized: "Listening…")
            case .processing: return String(localized: "Thinking…")
            case .speaking: return String(localized: "Speaking…")
            }
        }

        /// The SF Symbol drawn with it.
        var symbol: String {
            switch self {
            case .listening: return "ear.fill"
            case .processing: return "brain"
            case .speaking: return "speaker.wave.2.fill"
            }
        }
    }

    /// Where the screen is.
    enum Screen: Equatable {
        /// Not presented.
        case hidden
        /// Presented, and the conversation it asked for has not been seen to start yet — the gap
        /// between the tap and `AppState.handleWakeWordDetected` opening the conversation, which
        /// would otherwise read as a conversation that is already over.
        case starting
        /// Presented over a running conversation, showing `phase`.
        case showing(Phase)
    }

    private(set) var screen: Screen = .hidden

    /// Whether the voice template is up — what `CarPlaySceneDelegate.isVoiceActive` reports.
    var isPresented: Bool { screen != .hidden }

    // MARK: - Start

    enum StartEffect: Equatable {
        /// Present the template and open a conversation (the CarPlay audio set-up, then the wake
        /// word's own start).
        case presentAndStartConversation
        /// Present the template over the conversation that is already running — one the wake word
        /// opened in the car, or one whose screen the system took down. Starting a second
        /// conversation on top of it is not what Start Listening means.
        case presentOverRunningConversation(Phase)
        /// Already on screen.
        case nothing
    }

    mutating func start(_ conversation: Conversation) -> StartEffect {
        guard screen == .hidden else { return .nothing }
        if conversation.isOver {
            screen = .starting
            return .presentAndStartConversation
        }
        let phase = Phase(conversation)
        screen = .showing(phase)
        return .presentOverRunningConversation(phase)
    }

    // MARK: - Following the conversation

    enum UpdateEffect: Equatable {
        case none
        /// Switch the template to this state.
        case show(Phase)
        /// The conversation ended by itself: take the template down. The app's own end path has
        /// already handed the audio back, so nothing else is torn down.
        case dismiss
    }

    /// The conversation changed. While starting, a conversation that reads as over is the one that
    /// has not begun yet, and is waited for; once it has been seen running, over means over.
    mutating func observe(_ conversation: Conversation) -> UpdateEffect {
        switch screen {
        case .hidden:
            return .none
        case .starting:
            guard !conversation.isOver else { return .none }
            let phase = Phase(conversation)
            screen = .showing(phase)
            // The template opens on listening; say so only when that is not what it is.
            return phase == .listening ? .none : .show(phase)
        case .showing(let shown):
            if conversation.isOver {
                screen = .hidden
                return .dismiss
            }
            let phase = Phase(conversation)
            guard phase != shown else { return .none }
            screen = .showing(phase)
            return .show(phase)
        }
    }

    /// The start finished: the app's conversation start has returned. If it never opened a
    /// conversation (muted, voice input unavailable) or the conversation is already over, the screen
    /// goes — a template stuck on "Listening…" over nothing is the wedge this type exists to stop.
    mutating func startFinished(_ conversation: Conversation) -> UpdateEffect {
        guard screen == .starting else { return observe(conversation) }
        if conversation.isOver {
            screen = .hidden
            return .dismiss
        }
        return observe(conversation)
    }

    /// The system took the template down (it was not this type's `.dismiss`). Forget it, so the
    /// next Start Listening presents again. The conversation, if one is running, carries on and
    /// can still be stopped or ended from the Voice tab.
    mutating func templateDisappeared() {
        screen = .hidden
    }

    // MARK: - The Voice tab's rows

    enum StopEffect: Equatable {
        /// Cut off the reply and listen for the next thing said — `AppState.interruptSpeechAndListen`.
        case interruptAndListen
        /// Silence what is being read out (a job brief, a queue read-back) — nothing to listen for.
        case stopSpeaking
        /// Nothing is being said. While the model is still working Stop leaves it to finish, as the
        /// temple tap does; End is the way to abandon the turn.
        case nothing
    }

    /// What Stop does now. It never ends the conversation.
    func stop(_ conversation: Conversation) -> StopEffect {
        guard conversation.isSpeaking else { return .nothing }
        return conversation.inConversation ? .interruptAndListen : .stopSpeaking
    }

    struct EndEffect: Equatable {
        /// Hang the conversation up through `AppState.hangUpConversation`.
        var hangUp: Bool
        /// Take the template down and give back the audio session the car screen set up — what
        /// Stop Listening always did. Only when the screen was up: a conversation the wake word
        /// opened is hung up, but the listener it came from is left as the app's own end path
        /// leaves it.
        var dismiss: Bool

        static let nothing = EndEffect(hangUp: false, dismiss: false)
    }

    /// The End row. Hangs up a conversation that is running whether or not its screen is up, so a
    /// conversation whose template the system took down can still be ended from the car.
    mutating func end(_ conversation: Conversation) -> EndEffect {
        let presented = isPresented
        screen = .hidden
        return EndEffect(hangUp: presented || !conversation.isOver, dismiss: presented)
    }

    /// The car went away. Only the conversation the car screen was showing ends with it — one the
    /// wake word opened without the screen carries on on the phone, as it did before.
    mutating func carDisconnected() -> EndEffect {
        let presented = isPresented
        screen = .hidden
        return EndEffect(hangUp: presented, dismiss: presented)
    }
}
