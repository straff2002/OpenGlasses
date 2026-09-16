import Foundation

/// Plan FF P1/PR3 — whether opening the app should start the Blind Assistant, and what the wearer
/// is told when it does not.
///
/// The whole decision is here, as data, because the interesting part is not the starting: it is the
/// nine ways a start is *declined* and the fact that a wearer who cannot see the screen learns
/// which one happened only if the app says so. A silent non-start is indistinguishable from a
/// broken app.
///
/// Two design rules this encodes:
///
/// * **User intent, twice.** The setting is opt-in, and it is not on its own enough: Blind
///   Assistant must also be the selected live mode. A setting that quietly re-selected the preset
///   would take a choice away from a wearer who deliberately uses a different one, and the launch
///   path is exactly where a taken choice is hardest to notice. Settings offers the selection as a
///   button instead, next to the toggle.
/// * **A start without the camera is still a start.** Missing camera permission, or glasses that
///   never reported in, degrades the session to audio-only rather than cancelling it — but it is
///   never silent about it, because an assistant that cannot see must not be asked to look.
enum BlindAssistantLaunchPolicy {

    /// Which realtime backend the start would use. Only ever used for wording — the readiness
    /// itself arrives as a Bool, so the policy never has to know how a key is stored.
    enum Provider: String, Equatable, CaseIterable {
        case gemini
        case openAIRealtime

        var displayName: String {
            switch self {
            case .gemini: return "Gemini"
            case .openAIRealtime: return "OpenAI"
            }
        }
    }

    /// Everything the decision depends on, read at the moment it is made.
    ///
    /// `speechRecognitionGranted` is required even though the live session itself streams raw
    /// audio and never touches `SFSpeechRecognizer`: the wake word does, and the wake word is how
    /// a wearer reaches the app again without looking at it. Starting a session the wearer has no
    /// non-visual way back to is worse than declining and saying which permission is off.
    struct Inputs: Equatable {
        var settingEnabled: Bool
        var isPastOnboarding: Bool
        /// `Config.activeLiveAIModeId` — compared against the Blind Assistant preset.
        var selectedPresetID: String
        var provider: Provider
        var providerConfigured: Bool
        var microphoneGranted: Bool
        var speechRecognitionGranted: Bool
        var cameraGranted: Bool
        /// Glasses registration settled, or the wait timed out and they are not there. Either way
        /// the decision is made — a wearer is not left holding a phone that never answers.
        var glassesReady: Bool
        var silentMode: Bool
        var sessionAlreadyActive: Bool
        /// The wearer stopped a session with their own hands. See
        /// `LiveSessionActivator.stoppedByUserThisForeground` for why it outlives a foreground cycle.
        var stoppedByUserThisForeground: Bool

        init(settingEnabled: Bool = false,
             isPastOnboarding: Bool = true,
             selectedPresetID: String = BlindAssistanceContract.presetID,
             provider: Provider = .gemini,
             providerConfigured: Bool = true,
             microphoneGranted: Bool = true,
             speechRecognitionGranted: Bool = true,
             cameraGranted: Bool = true,
             glassesReady: Bool = true,
             silentMode: Bool = false,
             sessionAlreadyActive: Bool = false,
             stoppedByUserThisForeground: Bool = false) {
            self.settingEnabled = settingEnabled
            self.isPastOnboarding = isPastOnboarding
            self.selectedPresetID = selectedPresetID
            self.provider = provider
            self.providerConfigured = providerConfigured
            self.microphoneGranted = microphoneGranted
            self.speechRecognitionGranted = speechRecognitionGranted
            self.cameraGranted = cameraGranted
            self.glassesReady = glassesReady
            self.silentMode = silentMode
            self.sessionAlreadyActive = sessionAlreadyActive
            self.stoppedByUserThisForeground = stoppedByUserThisForeground
        }
    }

    /// Why a start did not happen. Named for the condition, not for the sentence.
    enum SkipReason: Equatable {
        case settingOff
        case setupNotFinished
        case differentAssistantSelected
        case sessionAlreadyRunning
        case stoppedByUser
        case silentMode
        case microphonePermissionOff
        case speechPermissionOff
        case providerNotConfigured(Provider)

        /// Always available: this is what Settings shows for "what happens when I open the app".
        var summary: String {
            switch self {
            case .settingOff:
                return "Starting on launch is off."
            case .setupNotFinished:
                return "Setup isn't finished yet."
            case .differentAssistantSelected:
                return "Blind Assistant isn't the selected live mode."
            case .sessionAlreadyRunning:
                return "A session is already running."
            case .stoppedByUser:
                return "You stopped the assistant, so it won't start again on its own."
            case .silentMode:
                return "Silent Mode is on, so nothing starts on its own."
            case .microphonePermissionOff:
                return "Microphone permission is off. Turn it on in iOS Settings, under OpenGlasses."
            case .speechPermissionOff:
                return "Speech recognition permission is off. Turn it on in iOS Settings, under OpenGlasses."
            case .providerNotConfigured(let provider):
                return "There's no \(provider.displayName) API key yet. Add one in OpenGlasses settings."
            }
        }

        /// The clause after "Not starting the assistant: ", or `nil` for a reason the wearer does
        /// not hear.
        ///
        /// Four are deliberately silent. Three of them describe a state the wearer put the app in
        /// seconds ago — the setting is off, they stopped the session, a session is already
        /// running — and announcing those turns every launch into a lecture. The fourth is Silent
        /// Mode, where speaking the reason would contradict the setting being reported.
        ///
        /// Written per case rather than derived from `summary`: "Blind Assistant" is a name, and a
        /// rule that lowercases the first word of a sentence gets that wrong.
        private var spokenClause: String? {
            switch self {
            case .settingOff, .sessionAlreadyRunning, .stoppedByUser, .silentMode:
                return nil
            case .setupNotFinished:
                return "setup isn't finished yet."
            case .differentAssistantSelected:
                return "Blind Assistant isn't the selected live mode."
            case .microphonePermissionOff:
                return "microphone permission is off. Turn it on in iOS Settings, under OpenGlasses."
            case .speechPermissionOff:
                return "speech recognition permission is off. Turn it on in iOS Settings, under OpenGlasses."
            case .providerNotConfigured(let provider):
                return "there's no \(provider.displayName) API key yet. Add one in OpenGlasses settings."
            }
        }

        /// Whether the wearer hears this one.
        var isSpoken: Bool { spokenClause != nil }

        /// The spoken line, or `nil` when this reason is one of the silent ones.
        var spokenReason: String? {
            spokenClause.map { "Not starting the assistant: \($0)" }
        }
    }

    /// What is missing when a start is audio-only.
    enum AudioOnlyReason: Equatable {
        case cameraPermissionOff
        case noGlasses
    }

    struct Start: Equatable {
        /// The session starts, but nothing will be able to look at anything.
        var audioOnly: AudioOnlyReason?

        /// Said before the session starts, so the wearer knows what they are getting. `nil` for a
        /// full start — that one is announced by the session-usable cue, and two voices saying the
        /// same thing is the failure the audible lifecycle exists to avoid.
        var cue: String? {
            switch audioOnly {
            case .none:
                return nil
            case .cameraPermissionOff:
                return "Starting the assistant. Camera access is off, so it can hear you but not see."
            case .noGlasses:
                return "Starting the assistant without the glasses. It can hear you, but there's no camera."
            }
        }
    }

    enum Decision: Equatable {
        case start(Start)
        case skip(SkipReason)

        /// What this decision says out loud, or `nil` when it says nothing.
        var announcement: String? {
            switch self {
            case .start(let start): return start.cue
            case .skip(let reason): return reason.spokenReason
            }
        }

        /// What Settings shows. Unlike `announcement`, never `nil` — a settings screen that goes
        /// blank is the same dead end as a launch that goes quiet.
        var summary: String {
            switch self {
            case .start(let start):
                return start.cue ?? "The assistant will start when you open the app."
            case .skip(let reason):
                return reason.summary
            }
        }
    }

    /// The order is the answer: the first unmet condition is the one reported, and they are
    /// ordered from "the wearer already knows" to "something needs fixing elsewhere", so the
    /// sentence a wearer actually hears is the most actionable one that applies.
    static func decide(_ inputs: Inputs) -> Decision {
        guard inputs.settingEnabled else { return .skip(.settingOff) }
        guard inputs.isPastOnboarding else { return .skip(.setupNotFinished) }
        guard inputs.selectedPresetID == BlindAssistanceContract.presetID else {
            return .skip(.differentAssistantSelected)
        }
        guard !inputs.sessionAlreadyActive else { return .skip(.sessionAlreadyRunning) }
        guard !inputs.stoppedByUserThisForeground else { return .skip(.stoppedByUser) }
        guard !inputs.silentMode else { return .skip(.silentMode) }
        guard inputs.microphoneGranted else { return .skip(.microphonePermissionOff) }
        guard inputs.speechRecognitionGranted else { return .skip(.speechPermissionOff) }
        guard inputs.providerConfigured else { return .skip(.providerNotConfigured(inputs.provider)) }

        // Camera first: it is the one the wearer can fix, and a phone whose camera permission is
        // off would otherwise be reported as a glasses problem.
        if !inputs.cameraGranted { return .start(Start(audioOnly: .cameraPermissionOff)) }
        if !inputs.glassesReady { return .start(Start(audioOnly: .noGlasses)) }
        return .start(Start(audioOnly: nil))
    }
}
