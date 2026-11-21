import Foundation

/// Where a cancelled turn was cancelled from. Logged on `responseCancelled` as its `detail`, so a
/// support report says which control stopped a question (a tester's report of 2026-11-21 had one
/// cancelled 13 s in, and nothing recorded whether the phone or the lens sent the Stop).
enum TurnCancelSource: String, CaseIterable {
    /// The phone's Cancel / Stop speaking button.
    case phoneButton
    /// The lens's Thinking card, Cancel pressed twice.
    case lens
    /// A temple tap set to end the conversation.
    case templeTap
    /// The car screen's end button.
    case carPlay
}

/// Whether a cancel says "Cancelled". Pure.
///
/// A question dropped before its answer is said aloud, so a stray press can never pass for the app
/// ignoring the wearer: the tone that follows every cancel is the same one that ends any
/// conversation, and told them nothing. Stopping a reply that is already being spoken stays quiet
/// (the wearer asked for quiet), and a temple tap or the car's end button carry their own cue.
enum TurnCancelCue {
    static func speaksCancelled(source: TurnCancelSource, wasProcessing: Bool) -> Bool {
        guard wasProcessing else { return false }
        switch source {
        case .phoneButton, .lens: return true
        case .templeTap, .carPlay: return false
        }
    }
}
