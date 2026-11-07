import Foundation

/// The CarPlay voice screen, decided without CarPlay.
///
/// `CarPlaySceneDelegate` presents a `CPVoiceControlTemplate` over the tab bar (the SDK only
/// presents it modally — it cannot be the root). This type owns every decision about that screen —
/// which state it shows, which buttons each state carries, when it goes away, when the audio
/// session is given back, how deep the car screen gets, and what the Voice tab's rows do — so the
/// template code is a thin adapter that reads a `Conversation` snapshot off `AppState` and carries
/// out the effect it is handed.
///
/// The rules, each from CarPlay's voice-based conversational category or a defect the screen had:
///  - **Voice first.** With template buttons (iOS 26.4+) the car opens on the voice screen in a
///    *ready* state with one button, Talk. Ready touches nothing: no microphone, no listening, no
///    speech until the driver taps. Without buttons there would be no way to talk or to leave, so
///    the car opens on the tab bar as it always did and the screen appears on Start Listening.
///  - **It follows the conversation.** The state shown is the conversation's own — listening,
///    thinking, speaking — not "Listening…" from the first tap to the last.
///  - **It cannot wedge.** When the conversation ends by itself (the silence window, "goodbye",
///    One Question at a Time) the screen goes back to ready (or away, without buttons); a template
///    the system took down is forgotten. Either way the next Talk or Start Listening starts
///    something.
///  - **Stop and End are different things.** Stop cuts off the reply and keeps the conversation
///    listening (the temple tap's interrupt); End hangs the conversation up (the temple tap's hang
///    up). Both are the app's existing paths — this type only chooses between them.
///  - **Audio only while voice is in use.** Every end — by itself, End, or the car going — owes a
///    release of the audio session, settled once the app's own end path has finished (its re-arm
///    included), so the release is the last word.
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

    /// The template's states. The raw value is the `CPVoiceControlState` identifier.
    enum VoiceState: String, CaseIterable, Equatable {
        /// Waiting for the driver. Nothing is open.
        case ready
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
            case .ready: return String(localized: "Tap to talk")
            case .listening: return String(localized: "Listening…")
            case .processing: return String(localized: "Thinking…")
            case .speaking: return String(localized: "Speaking…")
            }
        }

        /// The SF Symbol drawn with it.
        var symbol: String {
            switch self {
            case .ready: return "mic.circle"
            case .listening: return "ear.fill"
            case .processing: return "brain"
            case .speaking: return "speaker.wave.2.fill"
            }
        }

        /// The action buttons this state carries, leading to trailing — never more than
        /// `CarPlayVoiceScreen.maximumButtons`.
        var buttons: [Button] {
            switch self {
            case .ready: return [.talk]
            case .listening, .processing: return [.end]
            case .speaking: return [.stop, .end]
            }
        }
    }

    /// An action button on the voice template.
    enum Button: String, CaseIterable, Equatable {
        /// Start a conversation.
        case talk
        /// Stop the assistant talking; the conversation carries on listening.
        case stop
        /// Hang the conversation up; the audio session is released after it.
        case end

        var title: String {
            switch self {
            case .talk: return String(localized: "Talk")
            case .stop: return String(localized: "Stop")
            case .end: return String(localized: "End")
            }
        }

        var symbol: String {
            switch self {
            case .talk: return "mic.fill"
            case .stop: return "stop.fill"
            case .end: return "phone.down.fill"
            }
        }
    }

    /// The most action buttons the voice template shows (`CPVoiceControlState.maximumActionButtonCount`
    /// on iOS 26.4).
    static let maximumButtons = 2

    /// The states the template is built with, the one it opens on first. Without buttons there is
    /// no ready state — nothing on it could be tapped.
    static func states(hasButtons: Bool) -> [VoiceState] {
        hasButtons ? VoiceState.allCases : [.listening, .processing, .speaking]
    }

    /// Where the screen is.
    enum Screen: Equatable {
        /// Not presented: the tab bar is showing.
        case hidden
        /// Presented, idle, offering Talk. Only with buttons.
        case ready
        /// Presented, and the conversation it asked for has not been seen to start yet — the gap
        /// between the tap and `AppState.handleWakeWordDetected` opening the conversation, which
        /// would otherwise read as a conversation that is already over.
        case starting
        /// Presented over a running conversation, showing this state.
        case showing(VoiceState)
    }

    /// Whether the template carries buttons (iOS 26.4+).
    let hasButtons: Bool
    private(set) var screen: Screen = .hidden
    /// An end happened and the audio session has not been given back yet.
    private(set) var releaseOwed = false

    init(hasButtons: Bool) {
        self.hasButtons = hasButtons
    }

    /// Whether the voice template is up — what `CarPlaySceneDelegate.isVoiceActive` reports.
    var isPresented: Bool { screen != .hidden }

    /// The state the template is showing, or nil when it is not up.
    var shownState: VoiceState? {
        switch screen {
        case .hidden: return nil
        case .ready: return .ready
        case .starting: return .listening
        case .showing(let state): return state
        }
    }

    /// Where an ended conversation leaves the screen: ready with buttons, gone without.
    private var restingScreen: Screen { hasButtons ? .ready : .hidden }

    // MARK: - Connect

    /// The car connected. With buttons, present the ready screen — voice is the first thing the
    /// driver sees. Returns whether to present. Opens nothing.
    mutating func connected() -> Bool {
        guard hasButtons, screen == .hidden else { return false }
        screen = .ready
        return true
    }

    // MARK: - Start (Talk, Start Listening, a tab row that talks)

    enum StartEffect: Equatable {
        /// Present the template on listening and open a conversation (the CarPlay audio set-up,
        /// then the wake word's own start).
        case presentAndStartConversation
        /// The template is already up on ready: switch it to listening and open a conversation.
        case startConversation
        /// Present the template over the conversation that is already running — one the wake word
        /// opened in the car, or one whose screen the system took down. Starting a second
        /// conversation on top of it is not what Start Listening means.
        case presentOverRunningConversation(VoiceState)
        /// The ready screen is up over a conversation that has started; show it.
        case show(VoiceState)
        /// Already talking.
        case nothing
    }

    mutating func start(_ conversation: Conversation) -> StartEffect {
        switch screen {
        case .starting, .showing:
            return .nothing
        case .ready:
            if conversation.isOver {
                screen = .starting
                return .startConversation
            }
            let state = VoiceState(conversation)
            screen = .showing(state)
            return .show(state)
        case .hidden:
            if conversation.isOver {
                screen = .starting
                return .presentAndStartConversation
            }
            let state = VoiceState(conversation)
            screen = .showing(state)
            return .presentOverRunningConversation(state)
        }
    }

    // MARK: - Following the conversation

    enum UpdateEffect: Equatable {
        case none
        /// Switch the template to this state.
        case show(VoiceState)
        /// The conversation ended: back to ready (with buttons). A release is now owed.
        case showReady
        /// The conversation ended: take the template down (without buttons). A release is now owed.
        case dismiss
    }

    /// The conversation changed. While starting, a conversation that reads as over is the one that
    /// has not begun yet, and is waited for; once it has been seen running, over means over. The
    /// ready screen follows a conversation it did not start (the wake word, a brief on connect).
    mutating func observe(_ conversation: Conversation) -> UpdateEffect {
        switch screen {
        case .hidden:
            return .none
        case .ready:
            guard !conversation.isOver else { return .none }
            let state = VoiceState(conversation)
            screen = .showing(state)
            return .show(state)
        case .starting:
            guard !conversation.isOver else { return .none }
            let state = VoiceState(conversation)
            screen = .showing(state)
            // The template is on listening already; say so only when that is not what it is.
            return state == .listening ? .none : .show(state)
        case .showing(let shown):
            if conversation.isOver { return ended() }
            let state = VoiceState(conversation)
            guard state != shown else { return .none }
            screen = .showing(state)
            return .show(state)
        }
    }

    /// The start finished: the app's conversation start has returned. If it never opened a
    /// conversation (muted, voice input unavailable) or the conversation is already over, the screen
    /// rests — a template stuck on "Listening…" over nothing is the wedge this type exists to stop.
    mutating func startFinished(_ conversation: Conversation) -> UpdateEffect {
        guard screen == .starting else { return observe(conversation) }
        if conversation.isOver { return ended() }
        return observe(conversation)
    }

    private mutating func ended() -> UpdateEffect {
        screen = restingScreen
        releaseOwed = true
        return hasButtons ? .showReady : .dismiss
    }

    /// The system took the template down, or the driver went to the tabs (it was not this type's
    /// `.dismiss`). Forget it, so the next Start Listening presents again. The conversation, if one
    /// is running, carries on and can still be stopped or ended from the Voice tab.
    mutating func templateDisappeared() {
        screen = .hidden
    }

    // MARK: - The audio session

    enum ReleaseEffect: Equatable {
        /// Give the audio session back, after moving the screen as `screen` says.
        case release(screen: UpdateEffect)
        case none
    }

    /// The app's end path (`returnToWakeWord`) has finished — the re-arm it may do is done, so a
    /// release now is the last word.
    ///
    /// Owed after any end this type saw; also whenever the screen is up over nothing, since an end
    /// it missed (the phone's own Stop) leaves CarPlay's session held just the same.
    mutating func appFinishedEnding(_ conversation: Conversation) -> ReleaseEffect {
        guard conversation.isOver else { return .none }
        switch screen {
        case .showing:
            // An end the observation has not delivered yet.
            let effect = ended()
            releaseOwed = false
            return .release(screen: effect)
        case .ready:
            releaseOwed = false
            return .release(screen: .none)
        case .hidden:
            guard releaseOwed else { return .none }
            releaseOwed = false
            return .release(screen: .none)
        case .starting:
            // A conversation is being opened right now; its own end will settle it.
            return .none
        }
    }

    /// The fallback for an end with no end path behind it (listening switched off on the phone):
    /// release if one is still owed and nothing has started since.
    mutating func releaseFallbackDue(_ conversation: Conversation) -> Bool {
        guard releaseOwed, conversation.isOver, screen != .starting else { return false }
        releaseOwed = false
        return true
    }

    // MARK: - Stop and End

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
        /// Hang the conversation up through `AppState.hangUpConversation`; the release follows when
        /// its end path finishes (`appFinishedEnding`).
        var hangUp: Bool
        /// What the template does: back to ready, away, or nothing.
        var screen: UpdateEffect
        /// Put the audio back on the phone's own rules (`WakeWordService.carPlayMode` off) before
        /// anything else, so the end path hands the session back and re-arms the listener as it
        /// does on the phone. Only when the car has gone.
        var restorePhoneAudio = false

        static let nothing = EndEffect(hangUp: false, screen: .none)
    }

    /// End — the End button or row. Hangs up a conversation that is running whether or not its
    /// screen is up, so a conversation whose template the system took down can still be ended from
    /// the car. With nothing running there is nothing to end.
    mutating func end(_ conversation: Conversation) -> EndEffect {
        switch screen {
        case .starting, .showing:
            return EndEffect(hangUp: true, screen: ended())
        case .ready, .hidden:
            guard !conversation.isOver else { return .nothing }
            releaseOwed = true
            return EndEffect(hangUp: true, screen: .none)
        }
    }

    /// The car went away. CarPlay's audio mode always ends with it — it used to outlive the car,
    /// leaving the phone's later conversations skipping their own hand-back. A conversation the car
    /// screen was showing ends too; its end path, now on the phone's rules, gives the audio back,
    /// so no CarPlay release is owed. One the wake word opened with no screen up carries on on the
    /// phone, as it did before.
    mutating func carDisconnected() -> EndEffect {
        defer { screen = .hidden }
        releaseOwed = false
        switch screen {
        case .starting, .showing:
            return EndEffect(hangUp: true, screen: .none, restorePhoneAudio: true)
        case .ready, .hidden:
            return EndEffect(hangUp: false, screen: .none, restorePhoneAudio: true)
        }
    }

    // MARK: - Template depth

    /// CarPlay's limit for this category, root included.
    static let maximumDepth = 3

    /// How deep the car screen is: the tab bar, the tab's own list, each template pushed on it, and
    /// the voice template when it is presented over them.
    static func depth(pushed: Int, voicePresented: Bool) -> Int {
        2 + pushed + (voicePresented ? 1 : 0)
    }

    /// Whether presenting the voice template over `pushed` templates would go past the limit, so the
    /// stack is popped to the tab first. Today only the job-ahead page is ever pushed, and nothing
    /// on it presents; this keeps it true if that changes.
    static func mustPopToRootBeforePresenting(pushed: Int) -> Bool {
        depth(pushed: pushed, voicePresented: true) > maximumDepth
    }
}
