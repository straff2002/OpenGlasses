import AVFoundation
import Foundation

/// The assistant-voice gate for captions (Plan MO §6, "Our own voice is not a caption").
///
/// Captions read the always-on listener's tap directly, so before this they heard everything the
/// mic heard, the assistant's own replies on the phone speaker included, and transcribed them as
/// if a person had said them. This gate gives every caption consumer the capture router's
/// decision (`AssistantAudioGate.decide`, from the one subscription to the assistant's speaking
/// state and the output route) with "Include Assistant Voice" treated as off: that setting is for
/// an audience following a stream, and a caption never wants the assistant.
///
/// The router computes the decision on the main actor and publishes it into the fan-out box under
/// its lock; this reads it from the audio thread, exactly as the recorder's gate does. A gated
/// buffer is a zero-filled buffer of the same format and length, never a drop, so a recogniser's
/// timeline is unchanged. Owned by `CaptureAudioRouter.captionGate`.
final class CaptionAudioGate: AssistantVoiceGating {
    private let fanout: CaptureAudioFanout

    init(fanout: CaptureAudioFanout) {
        self.fanout = fanout
    }

    /// Never: whatever the setting, captions are not to hold the assistant's voice.
    var assistantVoiceMayBeIncluded: Bool { false }

    /// Called from the audio thread.
    func gatedBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        fanout.captionGate(buffer)
    }
}
