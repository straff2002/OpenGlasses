import Foundation

/// The three ways a live-hints session listens (Plan MO §2).
enum HintMode: String, CaseIterable, Codable, Sendable {
    /// A hint when someone who isn't the wearer asks a question.
    case conversation
    /// Key points on a cadence (P1); a question the speaker asks the room is still hinted.
    case lecture
    /// A fact card when one of the wearer's keywords is said, by anyone. No model.
    case keyword
}
