import Foundation

/// A non-voice, hands-free way to fire the assistant — an **alternative trigger** for users who can't
/// or won't use the wake word (Additional Capabilities #5, an Accessibility-tier input method). Each
/// trigger routes to the same entry point as the wake word.
///
/// All triggers are **opt-in / off by default**: the volume-button trigger runs against Apple's HIG
/// and has historically drawn rejections, so nothing here is on unless the user enables it.
///
/// Note: a glasses double-tap / touchpad trigger is deliberately absent — the DAT SDK exposes no
/// gesture/touchpad stream (firmware owns focus/select), so triggers must be phone-side.
enum AlternativeTrigger: String, CaseIterable, Identifiable, Codable {
    /// A deliberate phone shake (CoreMotion).
    case shake
    /// A detected acoustic cue — cough / clap / whistle (SoundAnalysis).
    case acoustic
    /// A hardware volume-button press (`AVAudioSession.outputVolume` KVO). Off by default; App-Store risk.
    case volume

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shake: return "Shake"
        case .acoustic: return "Cough / Clap"
        case .volume: return "Volume Button"
        }
    }

    var systemImage: String {
        switch self {
        case .shake: return "iphone.gen3.radiowaves.left.and.right"
        case .acoustic: return "waveform.badge.mic"
        case .volume: return "speaker.wave.2"
        }
    }

    var detail: String {
        switch self {
        case .shake: return "Shake the phone to start the assistant."
        case .acoustic: return "A cough, clap, or whistle starts the assistant. Uses the microphone continuously while enabled."
        case .volume: return "A volume-button press starts the assistant. Off by default — may conflict with normal volume control."
        }
    }

    /// All triggers are opt-in. (Volume especially: hijacking the volume button is an App-Store risk,
    /// so it's never on without an explicit, informed choice.)
    var defaultEnabled: Bool { false }
}
