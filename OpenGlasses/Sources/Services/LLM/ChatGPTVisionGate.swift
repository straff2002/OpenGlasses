import Foundation

/// Vision honesty for the ChatGPT (Codex/Responses) subscription provider.
///
/// `LLMProvider.chatgpt` authenticates against the ChatGPT Codex backend and discovers the
/// account's model catalog dynamically. Whether this app's direct Responses integration accepts
/// image input (`input_image`) end-to-end was never actually confirmed on device —
/// docs/plans/BW-chatgpt-subscription-provider.md's P4 checklist still has "One image turn
/// (photo question) — confirms `input_image` acceptance on codex models" unchecked, and every
/// previously bundled catalog was entirely coding variants. Sending a photo down this path
/// anyway, behind a system prompt that insists "You CAN see it — never
/// deny vision", produces either an odd denial or (worse) a hallucinated description of a
/// scene the model never saw.
///
/// This mirrors the on-device Vision honesty gate in `LLMService.sendMessage`: when we don't
/// know a model can see, we say so plainly instead of asserting it can. Pure and state-free so
/// the routing decision is unit-testable without touching the network, `.shared` services, or
/// Config.
enum ChatGPTVisionGate {
    enum Decision: Equatable {
        /// Proceed normally — either there's no image this turn, or the provider isn't ChatGPT.
        case sendWithImage
        /// Refuse the image turn: speak `message` instead of building a vision-insisting system
        /// prompt or sending any image bytes to the backend.
        case declineVision(message: String)
    }

    /// Spoken/shown when a photo turn reaches the ChatGPT subscription provider. Matches the
    /// app's existing not-configured/can't-see copy: plain, spoken-friendly, names the real
    /// alternatives rather than just failing.
    static let declineMessage =
        "This ChatGPT sign-in can't see photos — add an OpenAI API key, switch to Gemini, or use the on-device model instead."

    /// Decide whether a turn's image should reach the ChatGPT provider. Only ever declines for
    /// `.chatgpt` with an image attached; every other provider, and every ChatGPT turn without
    /// an image, is a no-op so nothing else changes.
    static func decide(provider: LLMProvider, hasImage: Bool) -> Decision {
        guard provider == .chatgpt, hasImage else { return .sendWithImage }
        return .declineVision(message: declineMessage)
    }
}
