import Foundation

/// The two cloud recognisers dictation can be sent to (Plan JM P2).
enum CloudDictationProvider: String, CaseIterable, Equatable, Sendable {
    case deepgram
    case openAI

    var engine: ASREngine {
        switch self {
        case .deepgram: return .deepgram
        case .openAI: return .openAI
        }
    }

    var preference: ASREnginePreference {
        switch self {
        case .deepgram: return .deepgram
        case .openAI: return .openAI
        }
    }

    /// The counted route the question's audio leaves on.
    var route: NetworkRoute {
        switch self {
        case .deepgram: return .deepgramDictation
        case .openAI: return .openAIDictation
        }
    }

    var vendorName: String {
        switch self {
        case .deepgram: return "Deepgram"
        case .openAI: return "OpenAI"
        }
    }

    init?(engine: ASREngine) {
        switch engine {
        case .deepgram: self = .deepgram
        case .openAI: self = .openAI
        case .onDevice, .appleSpeech: return nil
        }
    }
}

/// Whether the question's audio may go to a cloud recogniser **right now** (Plan JM P2).
///
/// Every cloud dictation path asks this — at the start of the turn, on every captured buffer the
/// streaming engine would send, and before the whole-utterance upload is built — so a HIPAA flip,
/// a revoked choice or an organisation's pin mid-utterance stops audio leaving the phone at once,
/// not at the next turn. The same invariant `DeepgramSTTService.sendAudio` holds for captions.
///
/// The inputs are closures so the decision can be driven headlessly (no Keychain, no
/// `UserDefaults`), and so a test can flip one between two buffers. `live` reads the real values.
struct CloudDictationGate {
    /// The recogniser the wearer chose.
    var preference: () -> ASREnginePreference
    /// The wearer's own opt-in (`Config.cloudDictationEnabled`), already clamped by any
    /// organisation ceiling.
    var optedIn: () -> Bool
    /// Whether the provider's key is saved.
    var keyPresent: (CloudDictationProvider) -> Bool
    /// HIPAA mode: cloud dictation is refused outright, local-only or not.
    var hipaa: () -> Bool
    /// An organisation profile has pinned cloud dictation off.
    var orgPinnedOff: () -> Bool
    /// The medical egress guard for the provider's route (local-only mode).
    var medicalAllows: (NetworkRoute) -> Bool = { MedicalEgressGuard.allows($0) }

    /// The pure rule. Every condition must hold; any one failing keeps the audio on the phone.
    static func decide(provider: CloudDictationProvider, preference: ASREnginePreference, optedIn: Bool,
                       keyPresent: Bool, hipaa: Bool, orgPinnedOff: Bool, medicalAllows: Bool) -> Bool {
        guard !hipaa, !orgPinnedOff, optedIn, medicalAllows else { return false }
        guard preference == provider.preference else { return false }
        return keyPresent
    }

    func isConfigured(provider: CloudDictationProvider) -> Bool {
        Self.decide(provider: provider, preference: preference(), optedIn: optedIn(),
                    keyPresent: keyPresent(provider), hipaa: hipaa(), orgPinnedOff: orgPinnedOff(),
                    medicalAllows: medicalAllows(provider.route))
    }

    /// The live gate over `Config`, the Keychain, the organisation profile and the medical guard.
    static var live: CloudDictationGate {
        CloudDictationGate(
        preference: { Config.asrEnginePreference },
        optedIn: { Config.cloudDictationEnabled },
        keyPresent: { provider in
            switch provider {
            case .deepgram: return !Config.deepgramAPIKey.isEmpty
            case .openAI: return !Config.dictationOpenAIKey.isEmpty
            }
        },
        hipaa: { Config.hipaaMode },
        orgPinnedOff: { PolicyEnvelope.isLocked(.cloudDictationEnabled) }
        )
    }
}

extension Config {
    /// The wearer chose a cloud recogniser for dictation (Plan JM P2). Off by default. The
    /// Recognizer picker writes it alongside `asrEnginePreference` — on for a cloud choice, off for
    /// any other — so the switch is the choice itself, and an organisation profile can pin it off
    /// (`SettingKey.cloudDictationEnabled`), never on. The ceiling clamps on read and leaves the
    /// wearer's own value alone, as `interpreterEnabled` does.
    static var cloudDictationEnabled: Bool {
        get {
            PolicyEnvelope.bool(.cloudDictationEnabled,
                                stored: UserDefaults.standard.object(forKey: "cloudDictationEnabled") as? Bool ?? false)
        }
        set {
            guard !PolicyEnvelope.isLocked(.cloudDictationEnabled) else { return }
            UserDefaults.standard.set(newValue, forKey: "cloudDictationEnabled")
        }
    }

    /// The OpenAI key dictation uses: the same one the OpenAI voice uses — a saved OpenAI model on
    /// OpenAI's own address, else the legacy key. Never a ChatGPT sign-in, which cannot transcribe.
    static var dictationOpenAIKey: String {
        CloudVoiceCredentials.openAIKey(savedModels: savedModels, legacyKey: openAIAPIKey)
    }
}
