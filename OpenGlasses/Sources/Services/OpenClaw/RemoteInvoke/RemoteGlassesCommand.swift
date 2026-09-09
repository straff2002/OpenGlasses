import Foundation

/// A device action a gateway-side agent can ask the glasses to perform (Plan BH).
///
/// This is the canonical command surface for remote invoke — the second front door onto the same
/// device verbs the wake-word voice path drives. The parser maps many wire aliases onto these
/// cases; the policy decides per **class** (below); the executor maps each case onto the existing
/// services.
enum RemoteGlassesCommand: Equatable {
    case capturePhoto
    case startAudioRecording
    case stopAudioRecording
    case startVideo
    case stopVideo
    case startTranslation(source: String?, target: String?)
    case stopTranslation
    case startTranscription
    case stopTranscription
    case speak(text: String)
    case displayShow(text: String, icon: String?)
    case displayClear
    case deviceStatus
    case deviceCapabilities
    case addNote(text: String)
    case getTranscript
    case stopAll
}

/// Consent classes for remote commands (Plan BH). The user consents per class, not per verb:
/// - `observe` — read device/session state (status, capabilities).
/// - `output` — make the device present something (speak, HUD, save a note).
/// - `capture` — turn a sensor on — or read what one recorded (the transcript): photo, video,
///   audio, transcription, translation, transcript reads. The surveillance class; **off by
///   default** and additionally routed through `HighImpactToolPolicy`-style confirmation UX at
///   the executor. Reading back recorded conversation is the same wiretap exposure as recording
///   it, so it earns the same consent, the same announcement and the same tight rate budget.
/// - `halt` — stop commands (including `stopAll`). Not user-toggleable: a remote agent may
///   always *reduce* device activity while Agent Mode is on; it can never start capture through
///   this class. Still rate-limited and audited.
enum RemoteCommandClass: String, CaseIterable, Equatable {
    case observe
    case output
    case capture
    case halt
}

extension RemoteGlassesCommand {
    var commandClass: RemoteCommandClass {
        switch self {
        case .deviceStatus, .deviceCapabilities:
            return .observe
        case .speak, .displayShow, .displayClear, .addNote:
            return .output
        case .capturePhoto, .startAudioRecording, .startVideo, .startTranslation,
             .startTranscription, .getTranscript:
            return .capture
        case .stopAudioRecording, .stopVideo, .stopTranslation, .stopTranscription, .stopAll:
            return .halt
        }
    }

    /// Every canonical wire name — the command surface a node advertises at connect time
    /// (`OpenClawConnectParams.build(commands:)`, a flat list of names; neither socket passes it
    /// until the node role lands in Plan EH P3) so the agent knows the command surface
    /// without a round-trip. Tests assert each entry round-trips through the parser.
    static let allCanonicalActions: [String] = [
        "capture_photo",
        "start_audio_recording", "stop_audio_recording",
        "start_video", "stop_video",
        "start_translation", "stop_translation",
        "start_transcription", "stop_transcription",
        "speak",
        "display_show", "display_clear",
        "device_status", "device_capabilities",
        "add_note", "get_transcript",
        "stop_all",
    ]

    /// Canonical wire name, used in audit entries and replies.
    var canonicalAction: String {
        switch self {
        case .capturePhoto: return "capture_photo"
        case .startAudioRecording: return "start_audio_recording"
        case .stopAudioRecording: return "stop_audio_recording"
        case .startVideo: return "start_video"
        case .stopVideo: return "stop_video"
        case .startTranslation: return "start_translation"
        case .stopTranslation: return "stop_translation"
        case .startTranscription: return "start_transcription"
        case .stopTranscription: return "stop_transcription"
        case .speak: return "speak"
        case .displayShow: return "display_show"
        case .displayClear: return "display_clear"
        case .deviceStatus: return "device_status"
        case .deviceCapabilities: return "device_capabilities"
        case .addNote: return "add_note"
        case .getTranscript: return "get_transcript"
        case .stopAll: return "stop_all"
        }
    }
}
