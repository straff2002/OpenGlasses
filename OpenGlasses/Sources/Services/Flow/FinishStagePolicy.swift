import Foundation

/// What the end of a turn should do with the microphone and the conversation.
///
/// Issue 427 follow-up. The finish stage used to be an `if listeningEnabled` guard with a bare
/// `return`, which looked like "don't touch the mic" but actually meant "leave the conversation
/// open forever": `inConversation` stayed `true`, and `onWakeWordDetected`'s
/// `guard !inConversation && !isProcessing` then dropped every later wake word as
/// `alreadyProcessing` until the app was force-quit. Field trace (build 371):
/// `tts finished; wakeWord listenerSkippedDisabled` at 16:11:10, then `wakeWord detected;
/// app alreadyProcessing detail=wakeWord` at 16:11:49.
///
/// Turning the master toggle off must still *end* the conversation — it only forbids re-opening
/// the mic, and `returnToWakeWord()` already checks the toggle again before it does that.
enum FinishStagePolicy {

    enum Action: Equatable {
        /// Stay in the conversation and listen for a follow-up utterance.
        case resumeDictation
        /// Reset conversation state and hand back to `returnToWakeWord()`, which re-checks the
        /// master toggle (and silent mode, connection, mute) before touching the microphone.
        case endConversation
    }

    /// - Parameters:
    ///   - listeningEnabled: the user's master listening toggle.
    ///   - inConversation: whether a conversation is still open.
    static func action(listeningEnabled: Bool, inConversation: Bool) -> Action {
        // The toggle being off never means "do nothing" — that is the stranding bug. It means
        // close the conversation and leave the mic shut.
        guard listeningEnabled else { return .endConversation }
        return inConversation ? .resumeDictation : .endConversation
    }
}
